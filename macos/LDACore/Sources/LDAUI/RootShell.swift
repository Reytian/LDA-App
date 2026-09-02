//
//  RootShell.swift
//  LDAUI
//
//  The top-level mode switcher. Four modes mirror the product's actual
//  round trip and the local matter workspace:
//    Matters       resume work and review value-free activity records
//    Anonymize     bring documents in, spot PII, review, export or save
//    Restore       bring the work back: restore the file the AI returned, or
//                  a redacted file you saved, with its mapping
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
    case matters = "Matters"
    case anonymize = "Anonymize"
    case deanonymize = "Restore"
    case fill = "Fill"

    public var localizedKey: LocalizedStringKey {
        LocalizedStringKey(rawValue)
    }
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

    /// The session model driving the Anonymize and Restore shells (the
    /// document tray plus the per-document review models).
    @ObservedObject private var session: SessionModel

    /// The fill model driving the Fill shell.
    @ObservedObject private var fillModel: FillModel

    // MARK: - Mode state (shared with LDAApp for command routing)

    @ObservedObject private var modeStore: AppModeStore

    // MARK: - Init

    public init(session: SessionModel, fillModel: FillModel, modeStore: AppModeStore) {
        self.session = session
        self.fillModel = fillModel
        self.modeStore = modeStore
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            // Matters layer.
            MatterWorkspaceView(
                session: session,
                isActive: modeStore.activeMode == .matters,
                onOpenDestination: { destination in
                    modeStore.activeMode = destination.appMode
                }
            )
            .opacity(modeStore.activeMode == .matters ? 1 : 0)
            .disabled(modeStore.activeMode != .matters)

            // Anonymize layer.
            // .disabled(true) on the inactive layer resigns any first responder
            // inside it, preventing keyboard events from bleeding through to the
            // hidden subtree. .allowsHitTesting would block pointer input but
            // leave text fields able to receive keyboard events.
            AppShell(
                session: session,
                isActive: modeStore.activeMode == .anonymize,
                onOpenRestore: { modeStore.activeMode = .deanonymize },
                onOpenMatters: { modeStore.activeMode = .matters }
            )
                .opacity(modeStore.activeMode == .anonymize ? 1 : 0)
                .disabled(modeStore.activeMode != .anonymize)

            // Restore layer.
            DeanonymizeShell(
                session: session,
                isActive: modeStore.activeMode == .deanonymize
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
                        Text(mode.localizedKey).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 430)
                .help("Review matters, anonymize documents, restore protected values, or fill a form")
            }
            // The On-device privacy indicator lives in the Anonymize status
            // banner (labeled, always visible) and in the Restore copy,
            // NOT here: an icon-only toolbar item reads as a mystery lock and
            // competes for toolbar width on narrow windows.
        }
    }
}
