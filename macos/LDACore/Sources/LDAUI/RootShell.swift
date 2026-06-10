//
//  RootShell.swift
//  LDAUI
//
//  The top-level mode switcher. Two modes: "Anonymize" (the existing AppShell
//  review window) and "Fill" (the new FillShell). Both child views are kept
//  alive at all times in a ZStack so switching modes does not tear down in-
//  progress work; only the active shell is visible (opacity 1) and interactive
//  (allowsHitTesting true). The inactive shell is hidden and hit-test blocked.
//
//  Mode selection lives in a segmented Picker placed in the toolbar at the
//  center. The Picker matches the Counsel chrome: no extra decoration, just
//  the two labels.
//
//  AppModeStore is a tiny ObservableObject that owns the active mode. It is
//  created in LDAApp and passed into RootShell so that the app-level CommandMenu
//  entries can read the current mode and dispatch keyboard shortcuts to the right
//  child model. This is the "mode-aware commands" approach: Cmd+J/Cmd+Shift+J
//  are shared shortcuts; the command reads the active mode and routes to either
//  ReviewModel.selectNextGroup / selectPreviousGroup (Anonymize) or
//  FillModel.selectNextBlank / selectPreviousBlank (Fill).
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import SwiftUI
import LDACore

// MARK: - AppMode

/// The two top-level application modes.
public enum AppMode: String, Hashable, CaseIterable {
    case anonymize = "Anonymize"
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

/// The top-level window content. Receives both child models and the shared
/// AppModeStore from the caller (LDAApp) as ObservedObjects. Both models live
/// for the window's lifetime; switching modes toggles visibility/interactivity
/// on the ZStack layers without destroying either child session.
public struct RootShell: View {

    // MARK: - Child models

    /// The review model driving the Anonymize shell.
    @ObservedObject private var reviewModel: ReviewModel

    /// The fill model driving the Fill shell.
    @ObservedObject private var fillModel: FillModel

    // MARK: - Mode state (shared with LDAApp for command routing)

    @ObservedObject private var modeStore: AppModeStore

    // MARK: - Init

    public init(reviewModel: ReviewModel, fillModel: FillModel, modeStore: AppModeStore) {
        self.reviewModel = reviewModel
        self.fillModel = fillModel
        self.modeStore = modeStore
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            // Anonymize layer
            AppShell(model: reviewModel)
                .opacity(modeStore.activeMode == .anonymize ? 1 : 0)
                .allowsHitTesting(modeStore.activeMode == .anonymize)

            // Fill layer
            FillShell(model: fillModel)
                .opacity(modeStore.activeMode == .fill ? 1 : 0)
                .allowsHitTesting(modeStore.activeMode == .fill)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $modeStore.activeMode) {
                    ForEach(AppMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .help("Switch between Anonymize and Fill modes")
            }
        }
    }
}
