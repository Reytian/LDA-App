//
//  ExportForAIFlow.swift
//  LDAUI
//
//  The Export for AI flow: choose the destination, THEN build and write the
//  handoff. Split out of AppShell (already the largest file in the module)
//  and given an injectable destination chooser so the one ordering rule that
//  matters here is testable: buildHandToAI parks the session and writes an
//  activity record, so a cancelled save panel must run neither.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import AppKit
import UniformTypeIdentifiers
import LDACore

@MainActor
enum ExportForAIFlow {

    /// What the shell shows after the flow returns.
    enum Outcome: Equatable {
        /// The user dismissed the save panel; nothing ran.
        case cancelled
        /// Nothing in the session is ready to hand over. Carries WHY, so the
        /// banner names the next step for the state the session is actually
        /// in rather than assuming an unscanned document.
        case nothingReady(SaveBlockReason)
        /// The Markdown file and its sidecar were written.
        case exported(SessionModel.ExportForAIResult)
        /// The handoff or a write failed; the message is banner ready.
        case failed(String)
    }

    /// The default file name is deliberately neutral: matter labels and
    /// document names are the parties, and this file is uploaded to a third
    /// party.
    static let defaultFileName = "Redacted for AI.md"

    /// Run the flow. `chooseDestination` is the save panel in production and
    /// a stub in tests; it is only asked once a document is ready, and the
    /// session is only touched once it has answered.
    static func run(
        session: SessionModel,
        chooseDestination: () -> URL? = presentSavePanel,
        createdAtISO8601: String = ISO8601DateFormatter().string(from: Date())
    ) -> Outcome {
        // The reason comes out with the refusal, so the shell can name the
        // state the session is actually in rather than one fixed sentence.
        if let blockReason = session.exportForAIAvailability.blockReason {
            return .nothingReady(blockReason)
        }
        guard let url = chooseDestination() else { return .cancelled }

        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        do {
            guard let result = try session.exportForAI(to: url, createdAtISO8601: createdAtISO8601) else {
                // The gate said yes but the build found nothing to include,
                // which can only mean every ready document lost its accepted
                // entities between the two reads. Report it as unscanned work,
                // because re-scanning is the recovery.
                return .nothingReady(.scanNotFinished)
            }
            return .exported(result)
        } catch {
            return .failed(String(
                format: L10n.string("Could not export the redacted file. %@"),
                error.localizedDescription as NSString
            ))
        }
    }

    /// The save panel for the Markdown export. A name collision is the
    /// panel's own replace prompt, never a silent suffix.
    static func presentSavePanel() -> URL? {
        let panel = NSSavePanel()
        panel.message = L10n.string(
            "Save the redacted Markdown file for the AI. Keep the .ldamap file that is saved next to it on this Mac."
        )
        panel.nameFieldStringValue = defaultFileName
        panel.canCreateDirectories = true
        if let markdown = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [markdown]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }
}
