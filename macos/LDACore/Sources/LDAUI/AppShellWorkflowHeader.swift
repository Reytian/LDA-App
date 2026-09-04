//
//  AppShellWorkflowHeader.swift
//  LDAUI
//
//  The guided workflow row at the top of the review window: Add, Scan,
//  Review, Share, with the reached steps drawn in the ink accent. Kept out of
//  AppShell because that file already carries the shell.
//
//  Narrow windows hide the row entirely rather than compressing it, so it
//  cannot slide under the compact toolbar during live resize. That decision
//  lives in WindowLayoutPolicy, next to the window state that drives it.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import SwiftUI
import LDACore

/// One row of workflow steps, with the current step emphasised.
struct AppShellWorkflowHeader: View {

    @ObservedObject var session: SessionModel

    /// Whether this document reached the Share step. Tracked by the shell
    /// independently from whether the completion card is still visible.
    let hasSharedOutput: Bool

    /// The active document's review model, read fresh on every access.
    private var model: ReviewModel { session.activeModel }

    var body: some View {
        let current = AnonymizeWorkflowPresentation.currentStep(
            status: model.status,
            hasDocument: !model.documentText.isEmpty,
            hasSharedOutput: hasSharedOutput
        )

        return HStack(spacing: 0) {
            ForEach(Array(AnonymizeWorkflowStep.allCases.enumerated()), id: \.element) { index, step in
                workflowStep(step, current: current)

                if index < AnonymizeWorkflowStep.allCases.count - 1 {
                    Rectangle()
                        .fill(step.rawValue < current.rawValue
                            ? CounselTheme.inkAccent.opacity(0.55)
                            : CounselTheme.hairline)
                        .frame(height: 1)
                        .frame(maxWidth: 72)
                        .padding(.horizontal, 8)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(CounselTheme.appSurface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CounselTheme.hairline).frame(height: 1)
        }
        .accessibilityElement(children: .ignore)
        .l10nAccessibilityLabel(
            "Anonymize workflow, current step %@",
            L10n.string(current.title)
        )
    }

    private func workflowStep(
        _ step: AnonymizeWorkflowStep,
        current: AnonymizeWorkflowStep
    ) -> some View {
        let completed = step.rawValue < current.rawValue
        let active = step == current

        return HStack(spacing: 6) {
            Image(systemName: completed ? "checkmark.circle.fill" : step.systemImage)
                .font(.system(size: 13, weight: active ? .semibold : .regular))
                .foregroundStyle(active || completed
                    ? CounselTheme.inkAccent
                    : CounselTheme.textSecondary)
            L10n.text(step.title)
                .font(.caption.weight(active ? .semibold : .regular))
                .foregroundStyle(active
                    ? CounselTheme.textPrimary
                    : CounselTheme.textSecondary)
        }
        .fixedSize()
    }
}
