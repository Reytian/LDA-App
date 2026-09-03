//
//  HandoffCompletionCard.swift
//  LDAUI
//
//  The recovery card the review shell shows after an Export for AI or a Save
//  Redacted handoff: what was written, what the user still has to check, and
//  the exact next action. Kept out of AppShell because that file already
//  carries the shell, and this card is self contained: one completion value
//  in, three buttons out.
//
//  Informational lines and warnings are deliberately different colors. A
//  boxed seal candidate is the feature working; an unboxed value is something
//  the exported image may still show.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import AppKit
import SwiftUI
import LDACore

// MARK: - Completion value

/// The most recent successful export or save handoff.
enum HandoffCompletion: Equatable {
    case exportedForAI(SessionModel.ExportForAIResult)
    case exported(result: ExportResult, protection: String)

    /// The files the Reveal in Finder button selects.
    var revealedFiles: [URL] {
        switch self {
        case .exportedForAI(let result):
            return [result.markdownURL, result.mappingURL]
        case .exported(let result, _):
            return [result.redactedURL, result.mappingURL]
                + (result.redactedImageURL.map { [$0] } ?? [])
        }
    }
}

// MARK: - Card

/// One finished handoff, shown above the document pane.
struct HandoffCompletionCard: View {

    let completion: HandoffCompletion

    /// Switches the window to Restore.
    let onOpenRestore: () -> Void

    /// Hides the card. Whether the document reached the Share step is tracked
    /// separately, so dismissing this does not rewind the workflow row.
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(CounselTheme.inkAccent)

            switch completion {
            case .exportedForAI(let result):
                VStack(alignment: .leading, spacing: 3) {
                    Text("Redacted file saved")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(CounselTheme.textPrimary)
                    Text(verbatim: AnonymizeWorkflowPresentation.exportCompletionDetail(
                        documentCount: result.documentCount,
                        skippedCount: result.skippedCount,
                        fileName: result.markdownURL.lastPathComponent
                    ))
                        .font(CounselTheme.Typography.supporting)
                        .foregroundStyle(result.skippedCount > 0
                            ? CounselTheme.danger
                            : CounselTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // The cross-document sweep runs at scan time, so a
                    // document scanned before its partners were added can
                    // still carry their names. Saying which ones is the whole
                    // point: the user cannot see it from the exported file.
                    if let advice = AnonymizeWorkflowPresentation.rescanAdvice(for: result.rescanWarnings) {
                        Text(verbatim: advice)
                            .font(CounselTheme.Typography.supporting)
                            .foregroundStyle(CounselTheme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // A seam the session pass could not repair. Unlike every
                    // other warning on this card, the user cannot verify it
                    // by reading the exported file: the file is correct and
                    // the damage only appears once the AI's reply is restored.
                    // So the engine's own line is shown verbatim under the
                    // advice, naming the document and the swap.
                    if let seamAdvice = AnonymizeWorkflowPresentation
                        .unresolvedSeamAdvice(issueCount: result.seamIssues.count) {
                        Text(verbatim: seamAdvice)
                            .font(CounselTheme.Typography.supporting.weight(.semibold))
                            .foregroundStyle(CounselTheme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(Array(result.seamIssues.enumerated()), id: \.offset) { _, issue in
                            Text(verbatim: AnonymizeWorkflowPresentation
                                .unresolvedSeamDescription(for: issue))
                                .font(CounselTheme.Typography.supporting)
                                .foregroundStyle(CounselTheme.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

            case .exported(let result, let protection):
                exportedCompletionDetails(result: result, protection: protection)
            }

            Spacer(minLength: 12)

            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(completion.revealedFiles)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()

            Button("Go to Restore") {
                onOpenRestore()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(CounselTheme.inkAccentFill)
            .fixedSize()

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
            .accessibilityLabel("Dismiss completion")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(CounselTheme.raised)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CounselTheme.hairline).frame(height: 1)
        }
    }

    /// What one finished export wrote, and what the user still has to check.
    /// Informational lines and warnings are deliberately different colors: a
    /// boxed candidate is the feature working, an unboxed value is something
    /// the exported image may still show.
    @ViewBuilder
    private func exportedCompletionDetails(
        result: ExportResult,
        protection: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Redacted document saved")
                .font(.callout.weight(.semibold))
                .foregroundStyle(CounselTheme.textPrimary)
            completionFileLine(
                String(
                    format: L10n.string("Document: %@"),
                    result.redactedURL.lastPathComponent as NSString
                ),
                help: result.redactedURL.lastPathComponent
            )
            completionFileLine(
                String(
                    format: L10n.string("Encrypted mapping: %@  \u{00B7}  %@"),
                    result.mappingURL.lastPathComponent as NSString,
                    protection as NSString
                ),
                help: "\(result.mappingURL.lastPathComponent), \(protection)"
            )
            if let imageURL = result.redactedImageURL {
                completionFileLine(
                    String(
                        format: L10n.string(
                            "Redacted image: %@  \u{00B7}  boxes are permanent, not restorable"
                        ),
                        imageURL.lastPathComponent as NSString
                    ),
                    help: imageURL.lastPathComponent
                )
            }
            if let candidates = ImageExportPresentation
                .sealCandidateDetail(count: result.sealCandidateCount) {
                completionNote(candidates, color: CounselTheme.textSecondary)
            }
            if let unboxed = ImageExportPresentation
                .unboxedWarning(count: result.unboxedTokenCount) {
                completionNote(unboxed, color: CounselTheme.danger)
            }
            if let warning = AnonymizeWorkflowPresentation.embeddedMediaWarning(
                count: result.embeddedMediaCount
            ) {
                completionNote(warning, color: CounselTheme.danger)
            }
        }
    }

    /// One written-file line: single line, middle-truncated, full name on hover.
    private func completionFileLine(_ text: String, help: String) -> some View {
        Text(verbatim: text)
            .font(.caption)
            .foregroundStyle(CounselTheme.textSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(help)
    }

    /// One wrapping note under the written-file lines.
    private func completionNote(_ text: String, color: Color) -> some View {
        Text(verbatim: text)
            .font(CounselTheme.Typography.supporting)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
