//
//  RootShell.swift
//  LDAUI
//
//  The top-level mode switcher. Three modes mirror the product's actual
//  round trip:
//    Anonymize     bring documents in, spot PII, review, copy or export
//    De-anonymize  bring the work back: paste an AI reply, or restore a
//                  redacted file via its mapping
//    Fill          fill a form draft from a stored client profile
//
//  All child views are kept alive at all times in a ZStack so switching modes
//  does not tear down in-progress work; only the active shell is visible
//  (opacity 1) and interactive. Each shell receives isActive and contributes
//  its toolbar ONLY while active: SwiftUI merges toolbar items from every
//  live layer, so without the guard the Anonymize buttons would clutter the
//  other modes' toolbars (and vice versa).
//
//  Window-level chrome owned here, not by any one shell:
//  - The mode picker (toolbar principal).
//  - The persistent On-device privacy indicator (trust applies to every mode).
//  - The paste-and-restore sheet: it can be triggered from the De-anonymize
//    shell, the Edit menu, or the menu-bar companion, regardless of mode.
//
//  AppModeStore is a tiny ObservableObject that owns the active mode. It is
//  created in LDAApp and passed into RootShell so that the app-level
//  CommandMenu entries can read the current mode and dispatch keyboard
//  shortcuts to the right child model (Cmd+J / Cmd+Shift+J / Cmd+Return).
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import SwiftUI
import LDACore

// MARK: - AppMode

/// The top-level application modes, in workflow order.
public enum AppMode: String, Hashable, CaseIterable {
    case anonymize = "Anonymize"
    case deanonymize = "De-anonymize"
    case fill = "Fill"
}

// MARK: - AppModeStore

/// A minimal ObservableObject that owns the active application mode. Hoisted
/// to the LDAApp level so CommandMenu entries can observe it without accessing
/// RootShell's @State directly.
public final class AppModeStore: ObservableObject {
    @Published public var activeMode: AppMode = .anonymize

    public init() {}
}

// MARK: - RootShell

/// The top-level window content. Receives the child models and the shared
/// AppModeStore from the caller (LDAApp) as ObservedObjects. All models live
/// for the window's lifetime; switching modes toggles visibility and
/// interactivity on the ZStack layers without destroying any child session.
public struct RootShell: View {

    // MARK: - Child models

    /// The session model driving the Anonymize and De-anonymize shells (the
    /// document tray plus the per-document review models).
    @ObservedObject private var session: SessionModel

    /// The fill model driving the Fill shell.
    @ObservedObject private var fillModel: FillModel

    // MARK: - Mode state (shared with LDAApp for command routing)

    @ObservedObject private var modeStore: AppModeStore

    /// True while the paste-and-restore sheet is presented. Window-level so
    /// every mode (and the menu-bar companion) can summon it.
    @State private var isPasteRestorePresented = false

    // MARK: - Init

    public init(session: SessionModel, fillModel: FillModel, modeStore: AppModeStore) {
        self.session = session
        self.fillModel = fillModel
        self.modeStore = modeStore
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            // Anonymize layer.
            // .disabled(true) on the inactive layer resigns any first responder
            // inside it, preventing keyboard events from bleeding through to the
            // hidden subtree. .allowsHitTesting would block pointer input but
            // leave text fields able to receive keyboard events.
            AppShell(session: session, isActive: modeStore.activeMode == .anonymize)
                .opacity(modeStore.activeMode == .anonymize ? 1 : 0)
                .disabled(modeStore.activeMode != .anonymize)

            // De-anonymize layer.
            DeanonymizeShell(
                session: session,
                isActive: modeStore.activeMode == .deanonymize,
                onPasteFromAI: { isPasteRestorePresented = true }
            )
            .opacity(modeStore.activeMode == .deanonymize ? 1 : 0)
            .disabled(modeStore.activeMode != .deanonymize)

            // Fill layer.
            FillShell(model: fillModel, isActive: modeStore.activeMode == .fill)
                .opacity(modeStore.activeMode == .fill ? 1 : 0)
                .disabled(modeStore.activeMode != .fill)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $modeStore.activeMode) {
                    ForEach(AppMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
                .help("Anonymize documents, de-anonymize results, or fill a form from a profile")
            }
            // The On-device privacy indicator lives in the Anonymize status
            // banner (labeled, always visible) and in the De-anonymize copy,
            // NOT here: an icon-only toolbar item reads as a mystery lock and
            // competes for toolbar width on narrow windows.
        }
        .sheet(isPresented: $isPasteRestorePresented) {
            PasteRestoreSheet(session: session, isPresented: $isPasteRestorePresented)
        }
        .onChange(of: session.pasteRestoreRequestToken) { _, _ in
            isPasteRestorePresented = true
        }
    }
}
