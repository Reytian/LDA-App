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

// MARK: - RootShell

/// The top-level window content. Receives both child models from the caller
/// (LDAApp) as ObservedObjects. Both models live for the window's lifetime;
/// switching modes toggles visibility/interactivity on the ZStack layers
/// without destroying either child session.
public struct RootShell: View {

    // MARK: - Child models

    /// The review model driving the Anonymize shell.
    @ObservedObject private var reviewModel: ReviewModel

    /// The fill model driving the Fill shell.
    @ObservedObject private var fillModel: FillModel

    // MARK: - Mode state

    @State private var activeMode: AppMode = .anonymize

    // MARK: - Init

    public init(reviewModel: ReviewModel, fillModel: FillModel) {
        self.reviewModel = reviewModel
        self.fillModel = fillModel
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            // Anonymize layer
            AppShell(model: reviewModel)
                .opacity(activeMode == .anonymize ? 1 : 0)
                .allowsHitTesting(activeMode == .anonymize)

            // Fill layer
            FillShell(model: fillModel)
                .opacity(activeMode == .fill ? 1 : 0)
                .allowsHitTesting(activeMode == .fill)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $activeMode) {
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
