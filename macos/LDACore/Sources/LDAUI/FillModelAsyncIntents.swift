//
//  FillModelAsyncIntents.swift
//  LDAUI
//
//  The three asynchronous intents of FillModel: extractProfile, planFill and
//  applyFill. Each runs its heavy work off the main actor in a detached Task
//  and publishes the result back on the main actor. Because they suspend for
//  seconds to minutes, each has to ask, when it resumes, whether the editor
//  still holds what it was started for; a completion that arrives after the
//  user moved on lands nowhere.
//
//  Two things make a completion stale. The editor's occupant changed (the
//  user went back to the library, opened or created another portfolio, loaded
//  a file): FillModel.editorGeneration. Or a later request of the same kind
//  superseded it for the same occupant: FillModel.extractionSerial for
//  extractions, the current targetURL for plans. The failure this prevents is
//  concrete: extraction A finishes into portfolio B's editor under B's id,
//  and the next Save writes A's data over B.
//
//  Stored properties (published state, the counters, the test seams) stay in
//  FillModel.swift because extensions cannot hold them. The methods here use
//  them directly as part of the same @MainActor class.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import LDACore

extension FillModel {

    // MARK: - Extraction

    /// What one extraction was started for: the editor's occupant, and this
    /// extraction's own place in the sequence of extractions.
    struct ExtractionTicket: Equatable, Sendable {
        let generation: Int
        let serial: Int
    }

    /// Extract a ClientPortfolio from source documents.
    ///
    /// Stage transitions: .importingSources -> .extracting -> .profileReady
    /// (or .failed on error). Progress is reported via onProgress from the
    /// LDAService facade.
    ///
    /// createdAtISO8601 is supplied by the caller; the model never reads the clock.
    /// kind defaults to .company; the portal UI (Task 6) will thread real kinds here.
    ///
    /// The result lands only while the editor still holds what this
    /// extraction was started for and no later extraction has superseded it;
    /// see the file header.
    public func extractProfile(
        sources: [URL],
        label: String,
        createdAtISO8601: String,
        kind: PortfolioKind = .company
    ) async {
        let ticket = beginExtraction()
        let path = modelPath ?? ""
        let seam = Self.effectiveExtractProfileOverride
        let progressCallback: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            DispatchQueue.main.async {
                self?.applyExtractionProgress(done: done, total: total, ticket: ticket)
            }
        }

        do {
            let result = try await Task.detached(priority: .userInitiated) {
                if let seam {
                    return try seam(sources, label, kind, createdAtISO8601, progressCallback)
                }
                return try LDAService.extractProfile(
                    sources: sources,
                    label: label,
                    kind: kind,
                    modelPath: path,
                    createdAtISO8601: createdAtISO8601,
                    onProgress: progressCallback
                )
            }.value

            // The editor moved on while this ran (back to the library, another
            // portfolio opened or created, a later extraction started): this
            // result belongs to nobody on screen. Drop it BEFORE it touches
            // the profile, the dirty flag, or the identity a Save would use.
            guard isCurrent(ticket) else { return }
            land(result)

        } catch {
            // A stale failure is as wrong to publish as a stale result: it
            // would put the editor the user has since opened into .failed.
            guard isCurrent(ticket) else { return }
            publishFailure(error, context: .profile)
        }
    }

    /// Mark the start of an extraction; a later one supersedes it.
    ///
    /// Stage starts at .importingSources (documents are being staged before
    /// the LLM begins). The facade emits onProgress(0, total) when extraction
    /// actually begins (after all imports succeed); the first callback flips
    /// the stage to .extracting so it honestly reflects what the engine is
    /// doing, rather than a premature guess made here.
    private func beginExtraction() -> ExtractionTicket {
        extractionSerial += 1
        stage = .importingSources
        progress = 0
        sourceFailures = []
        return ExtractionTicket(generation: editorGeneration, serial: extractionSerial)
    }

    /// True while the editor still holds what the ticket's extraction was
    /// started for and no later extraction has superseded it.
    private func isCurrent(_ ticket: ExtractionTicket) -> Bool {
        ticket.generation == editorGeneration && ticket.serial == extractionSerial
    }

    /// Progress from the engine, honored only for the extraction that is
    /// still current.
    private func applyExtractionProgress(done: Int, total: Int, ticket: ExtractionTicket) {
        guard isCurrent(ticket) else { return }
        // done == 0 and total > 0 is the "extraction started" signal from the facade.
        if case .importingSources = stage { stage = .extracting }
        if total > 0 { progress = Double(done) / Double(total) }
    }

    /// Publish a finished extraction into the editor.
    private func land(_ result: ExtractProfileResult) {
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
    }

    // MARK: - Planning

    /// Detect blanks in the target document and match them against the profile.
    ///
    /// Requires a profile to be loaded (stage .profileReady or later). Stage
    /// transitions: .planning -> .reviewing with blanks + manualWidgetNames.
    /// selectedBlankID is set to the first blank after planning succeeds.
    ///
    /// The plan lands only while the editor still holds the profile it was
    /// matched against and the target it was made for: a portfolio opened
    /// meanwhile never sees it, and a later target supersedes it.
    public func planFill(target: URL) async {
        guard let profile else { return }
        let generation = editorGeneration
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

        do {
            let plan = try await Task.detached(priority: .userInitiated) {
                if let seam {
                    // I1: Pass the live profile so tests can assert the hand-off.
                    return try seam(target, profile)
                }
                return try LDAService.planFill(target: target, profile: profile, modelPath: path)
            }.value

            guard isCurrentPlan(generation: generation, target: target) else { return }
            blanks = plan.blanks
            manualWidgetNames = plan.manualWidgetNames
            selectedBlankID = plan.blanks.first?.id
            stage = .reviewing
            await publishTargetTextForDisplay(target, generation: generation)
            // Do NOT stop the scope here: applyFill still needs to read the target.

        } catch {
            // A stale failure lands nowhere either, and leaves the scope alone:
            // a newer target holds the scope now, released from this one by
            // startTargetScope when it opened.
            guard isCurrentPlan(generation: generation, target: target) else { return }
            targetText = nil
            // Planning failed: release the scope; there is nothing to apply.
            stopTargetScope()
            publishFailure(error, context: .review)
        }
    }

    /// True while the editor still holds the occupant the plan was matched
    /// against and `target` is still the target the user wants filled.
    private func isCurrentPlan(generation: Int, target: URL) -> Bool {
        generation == editorGeneration && targetURL == target
    }

    /// Import the target's text for display in BlankDocumentPane.
    ///
    /// Display-only, best-effort: a failure here does not affect the plan
    /// already published. DOCX targets only (PDF rendering is not yet
    /// supported in BlankDocumentPane V1). The seam path also attempts a real
    /// import when the file exists on disk, so seam-driven tests with fake
    /// URLs stay green (the import throws and leaves targetText nil).
    private func publishTargetTextForDisplay(_ target: URL, generation: Int) async {
        guard target.pathExtension.lowercased() == "docx" else { return }
        let importedText: String? = await Task.detached(priority: .userInitiated) {
            (try? DocxImporter().importDocument(target))?.text
        }.value
        guard isCurrentPlan(generation: generation, target: target) else { return }
        targetText = importedText
    }

    // MARK: - Applying

    /// Apply the confirmed blanks to the target document, writing the output
    /// into outputDir.
    ///
    /// The model passes ALL current blanks to the facade; the facade performs
    /// its own filtering (confirmed-with-value only, dedupe). This ensures the
    /// FillReport's skipped list is complete.
    ///
    /// Stage transitions: .applying -> .done(FillReport) or .failed. The
    /// outcome is published only while the editor still holds the portfolio
    /// the fill belongs to: a portfolio opened meanwhile is not told about a
    /// document filled from another one. The written file is on disk either
    /// way.
    public func applyFill(outputDir: URL) async {
        // I2: Only proceed from the reviewing stage. This prevents re-entry from
        // .done overwriting a completed report, and guards against calls from any
        // other stage where a FillPlan has not yet been constructed.
        guard case .reviewing = stage else { return }
        guard let profile, let targetURL else { return }
        let generation = editorGeneration
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
                }
                return try LDAService.applyFill(
                    plan: plan,
                    target: targetURL,
                    profile: profile,
                    outputDir: outputDir
                )
            }.value

            // Stale: the scope belongs to whoever opened a target since, so it
            // is left alone too; see planFill.
            guard generation == editorGeneration else { return }
            // Apply succeeded: the engine no longer needs access to the source
            // file, so we can release the security scope.
            stopTargetScope()
            stage = .done(report)

        } catch {
            guard generation == editorGeneration else { return }
            // Apply failed: release the scope so subsequent attempts can re-open
            // it cleanly via a new Open Target flow.
            stopTargetScope()
            publishFailure(error, context: .review)
        }
    }
}
