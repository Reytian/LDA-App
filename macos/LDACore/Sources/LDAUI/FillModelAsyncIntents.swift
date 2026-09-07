//
//  FillModelAsyncIntents.swift
//  LDAUI
//
//  The three asynchronous intents of FillModel: extractProfile, planFill and
//  applyFill. Each runs its heavy work off the main actor in a detached Task
//  and publishes the result back on the main actor. Because they suspend,
//  each has to ask, when it resumes, whether the editor still holds what it
//  was started for (see FillModel.editorGeneration); a completion that
//  arrives after the user moved on must land nowhere.
//
//  Stored properties (published state, the generation counters, the test
//  seams) stay in FillModel.swift because extensions cannot hold them. The
//  methods here access them directly as part of the same @MainActor class.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import LDACore

extension FillModel {

    // MARK: - Async intents

    /// Extract a ClientPortfolio from source documents.
    ///
    /// Stage transitions: .importingSources -> .extracting -> .profileReady
    /// (or .failed on error). Progress is reported via onProgress from the
    /// LDAService facade.
    ///
    /// createdAtISO8601 is supplied by the caller; the model never reads the clock.
    /// kind defaults to .company; the portal UI (Task 6) will thread real kinds here.
    public func extractProfile(
        sources: [URL],
        label: String,
        createdAtISO8601: String,
        kind: PortfolioKind = .company
    ) async {
        // This extraction is now the editor's pending work; an earlier one
        // still running is superseded. Its result is bound to this generation
        // and lands only if the editor still holds what it was started for.
        invalidateInFlightEditorWork()
        let generation = editorGeneration

        // Stage starts at .importingSources (documents are being staged before the
        // LLM begins). The facade emits onProgress(0, total) when extraction actually
        // begins (after all imports succeed); we flip to .extracting on that first
        // callback so the stage honestly reflects what the engine is doing.
        stage = .importingSources
        progress = 0
        sourceFailures = []

        let path = modelPath ?? ""
        let seam = Self.effectiveExtractProfileOverride

        let progressCallback: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            DispatchQueue.main.async {
                guard let self, self.editorGeneration == generation else { return }
                // Flip to .extracting on the first progress event (done == 0 and
                // total > 0 is the "extraction started" signal from the facade).
                if case .importingSources = self.stage { self.stage = .extracting }
                if total > 0 { self.progress = Double(done) / Double(total) }
            }
        }

        // Do NOT set .extracting here; let the first onProgress callback do it
        // so the stage reflects real engine state rather than a premature guess.

        do {
            let result = try await Task.detached(priority: .userInitiated) {
                if let seam {
                    return try seam(sources, label, kind, createdAtISO8601, progressCallback)
                } else {
                    return try LDAService.extractProfile(
                        sources: sources,
                        label: label,
                        kind: kind,
                        modelPath: path,
                        createdAtISO8601: createdAtISO8601,
                        onProgress: progressCallback
                    )
                }
            }.value

            // The editor moved on while this ran (back to the library, another
            // portfolio opened or created, a later extraction started): this
            // result belongs to nobody on screen. Drop it BEFORE it touches
            // the profile, the dirty flag, or the identity a Save would use.
            guard generation == editorGeneration else { return }

            // Keep service values raw; the banner localizes known reasons when rendered.
            sourceFailures = result.failedSources.map {
                FillSourceFailure(name: $0.name, reason: $0.reason)
            }
            progress = 1
            loadProfile(result.profile)
            // An extracted-but-unsaved portfolio is unsaved work: mark dirty so
            // "Save to library" is enabled and "Back to Library" shows the discard
            // confirmation. loadProfile intentionally clears dirty (it is also used
            // to load a clean saved copy); we restore dirty here whenever extraction
            // produced any fields (an empty extraction adds nothing new to save).
            if !result.profile.fields.isEmpty {
                profileDirty = true
            }

        } catch {
            // A stale failure is as wrong to publish as a stale result: it
            // would put the editor the user has since opened into .failed.
            guard generation == editorGeneration else { return }
            publishFailure(error, context: .profile)
        }
    }

    /// Detect blanks in the target document and match them against the profile.
    ///
    /// Requires a profile to be loaded (stage .profileReady or later). Stage
    /// transitions: .planning -> .reviewing with blanks + manualWidgetNames.
    /// selectedBlankID is set to the first blank after planning succeeds.
    public func planFill(target: URL) async {
        guard let profile else { return }
        // I3: Reset progress at the start of each new planning pass.
        progress = 0
        stage = .planning
        targetURL = target
        // Clear any previously published targetText so a stale document is never
        // displayed while a new plan is in flight.
        targetText = nil

        // Sandbox: start the security scope for the new target. Any previously
        // held scope for an older target is released first by startTargetScope.
        // The scope must remain open through applyFill so the engine can read
        // the file in a second detached Task (closing it here would cause EPERM
        // when applyFill runs inside the sandboxed .app).
        startTargetScope(target)

        let seam = Self.effectivePlanFillOverride
        let path = modelPath
        let isDocx = target.pathExtension.lowercased() == "docx"

        do {
            let plan = try await Task.detached(priority: .userInitiated) {
                if let seam {
                    // I1: Pass the live profile so tests can assert the hand-off.
                    return try seam(target, profile)
                } else {
                    return try LDAService.planFill(
                        target: target,
                        profile: profile,
                        modelPath: path
                    )
                }
            }.value

            blanks = plan.blanks
            manualWidgetNames = plan.manualWidgetNames
            selectedBlankID = plan.blanks.first?.id
            stage = .reviewing

            // Import the document text for display in BlankDocumentPane. This is a
            // display-only, best-effort step: a failure here does not affect the
            // fill plan already computed above. Only attempted for DOCX targets
            // (PDF rendering is not yet supported in BlankDocumentPane V1).
            // The seam path also attempts a real import when the file exists on
            // disk so that seam-driven tests with fake URLs remain green (the
            // import will simply throw and leave targetText nil).
            if isDocx {
                let importedText: String? = await Task.detached(priority: .userInitiated) {
                    (try? DocxImporter().importDocument(target))?.text
                }.value
                targetText = importedText
            }

            // Do NOT stop the scope here: applyFill still needs to read the target.

        } catch {
            targetText = nil
            // Planning failed: release the scope; there is nothing to apply.
            stopTargetScope()
            publishFailure(error, context: .review)
        }
    }

    /// Apply the confirmed blanks to the target document, writing the output
    /// into outputDir.
    ///
    /// The model passes ALL current blanks to the facade; the facade performs
    /// its own filtering (confirmed-with-value only, dedupe). This ensures the
    /// FillReport's skipped list is complete.
    ///
    /// Stage transitions: .applying -> .done(FillReport) or .failed.
    public func applyFill(outputDir: URL) async {
        // I2: Only proceed from the reviewing stage. This prevents re-entry from
        // .done overwriting a completed report, and guards against calls from any
        // other stage where a FillPlan has not yet been constructed.
        guard case .reviewing = stage else { return }
        guard let profile, let targetURL else { return }
        // I3: Reset progress at the start of each apply pass.
        progress = 0
        stage = .applying

        let plan = FillPlan(
            targetFormat: targetURL.pathExtension.lowercased() == "docx" ? .docx : .pdf,
            blanks: blanks,
            manualWidgetNames: manualWidgetNames
        )

        let seam = Self.effectiveApplyFillOverride

        do {
            let report = try await Task.detached(priority: .userInitiated) {
                if let seam {
                    return try seam(plan, targetURL, outputDir)
                } else {
                    return try LDAService.applyFill(
                        plan: plan,
                        target: targetURL,
                        profile: profile,
                        outputDir: outputDir
                    )
                }
            }.value

            // Apply succeeded: the engine no longer needs access to the source
            // file, so we can release the security scope.
            stopTargetScope()
            stage = .done(report)

        } catch {
            // Apply failed: release the scope so subsequent attempts can re-open
            // it cleanly via a new Open Target flow.
            stopTargetScope()
            publishFailure(error, context: .review)
        }
    }
}
