//
//  FillModel.swift
//  LDAUI
//
//  The testable view-model that orchestrates LDACore's fill-from-profile feature.
//  The user imports source documents, the model extracts a ClientPortfolio, the user
//  reviews and edits the profile, a target document is planned, and blanks are
//  accepted or rejected before the filled document is written.
//
//  Stage lifecycle:
//    idle -> importingSources -> extracting -> profileReady
//    profileReady -> planning -> reviewing -> applying -> done(FillReport)
//    (any async step) -> failed(String)
//
//  Heavy work (extraction, planning, applying) runs off the main thread in a
//  detached Task; results are published back on the main actor. The model is
//  @MainActor so every @Published mutation is main-actor isolated.
//
//  Purity at the seam: createdAtISO8601 is supplied by the caller so the model
//  never reads the clock directly.
//
//  Test seams: three nonisolated(unsafe) internal static vars shadow the real
//  LDAService calls, mirroring the ReviewModel / LDAFillService pattern exactly.
//  Tests set them to fakes and nil them out in tearDown.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import SwiftUI
import LDACore

// MARK: - FillStage

/// The stage lifecycle state of a fill session.
public enum FillStage: Equatable {
    case idle
    /// Source documents are being imported before extraction starts.
    case importingSources
    /// The LLM is running over the imported source documents.
    case extracting
    /// Profile is ready; the user may edit and must clear all conflicts before planning.
    case profileReady
    /// The fill target is imported and blanks are being matched.
    case planning
    /// Blank-by-blank review; the user accepts, rejects, or repoints each blank.
    case reviewing
    /// Applying confirmed fills to the target document.
    case applying
    /// Apply completed successfully.
    case done(FillReport)
    /// A non-recoverable error with a display message.
    case failed(String)
}

// MARK: - FillModel

/// Orchestrates LDACore for the fill-from-profile UI. @MainActor so every
/// published change is delivered on the main actor; facade work runs off the
/// main thread.
@MainActor
public final class FillModel: ObservableObject {

    // MARK: - Published state

    /// The current stage of the fill session.
    @Published public var stage: FillStage = .idle

    /// The extracted or user-loaded client portfolio. Nil before extraction completes.
    @Published public var profile: ClientPortfolio?

    /// True when the profile has unsaved user edits (field updates, removals, or
    /// a setProfile call). Cleared by loadProfile.
    @Published public var profileDirty: Bool = false

    /// The detected blanks from the most recent planFill call.
    @Published public var blanks: [Blank] = []

    /// The blank currently focused in the review loop.
    @Published public var selectedBlankID: UUID?

    /// The fill target URL, set by planFill.
    @Published public var targetURL: URL?

    /// AcroForm widget names that require manual input (checkboxes, radio, choice).
    @Published public var manualWidgetNames: [String] = []

    /// The full text of the fill target as imported by DocxImporter. Non-nil
    /// only for DOCX targets where the import succeeded; nil for PDF targets
    /// and when import fails. Used by BlankDocumentPane to render the full
    /// document text with blank spans highlighted (display-only, best-effort).
    @Published public private(set) var targetText: String?

    /// Determinate progress of the extraction pass, 0...1.
    @Published public var progress: Double = 0

    /// Display strings built from ExtractProfileResult.failedSources.
    @Published public var sourceWarnings: [String] = []

    /// When non-nil, the UI should open the field picker for this blank id.
    /// Set by acceptBlank(id:) when the blank has a nil proposedValue; the UI
    /// observes this and opens the picker, then calls repointBlank to apply the
    /// chosen field.
    @Published public var pickerRequestID: UUID?

    /// Optional absolute path to the GGUF model. Passed to LDAService.extractProfile.
    public var modelPath: String?

    // MARK: - Security-scope ownership

    /// The target URL for which a security-scoped resource access is currently
    /// held. Non-nil only between planFill starting and applyFill completing (or
    /// planFill failing).
    ///
    /// Ownership rules:
    ///   - startAccessingSecurityScopedResource is called by planFill before the
    ///     detached Task begins reading the target.
    ///   - stopAccessingSecurityScopedResource is called by stopTargetScope().
    ///   - stopTargetScope() is called from applyFill on success or failure, from
    ///     planFill on failure, and when a NEW target is opened (so the old scope
    ///     is released before the new one is started).
    ///   - deinit calls stopTargetScope() as a safety net (the model is long-lived
    ///     but if it ever goes away while a scope is open, the sandbox reference
    ///     must be released).
    ///
    /// In the dev binary (unsandboxed) startAccessingSecurityScopedResource is a
    /// no-op that returns false, so this whole mechanism is dormant until the
    /// packaged .app runs under the sandbox.
    ///
    /// Internal (not private) so FillModelTests can assert scope bookkeeping
    /// without depending on the actual sandbox API.
    internal var scopedTargetURL: URL?

    /// True when scopedTargetURL was opened with startAccessingSecurityScopedResource
    /// and the scope has not yet been stopped.
    internal var targetScopeActive: Bool = false

    /// Start the security scope for a new target URL. Releases any previously
    /// held scope first so there is never more than one open scope at a time.
    private func startTargetScope(_ url: URL) {
        stopTargetScope()
        let active = url.startAccessingSecurityScopedResource()
        scopedTargetURL = url
        targetScopeActive = active
    }

    /// Stop the currently held security scope, if any. Safe to call repeatedly.
    private func stopTargetScope() {
        if targetScopeActive, let url = scopedTargetURL {
            url.stopAccessingSecurityScopedResource()
        }
        scopedTargetURL = nil
        targetScopeActive = false
    }

    deinit {
        // Safety net: release the scope if the model is torn down while a fill
        // session is still open (should not normally happen, but avoids a leak).
        // Cannot be @MainActor-isolated, so we read the stored value directly;
        // the model is @MainActor so all writes happen before deinit.
        if targetScopeActive, let url = scopedTargetURL {
            url.stopAccessingSecurityScopedResource()
        }
    }

    // MARK: - Test seams

    /// Replaces LDAService.extractProfile in tests. Receives (sources, label,
    /// createdAtISO8601, onProgress) and returns an ExtractProfileResult or throws.
    /// The onProgress closure mirrors the production signature so fakes can fire
    /// progress callbacks to drive the importingSources -> extracting transition.
    /// Nil in production. Mirrors the ReviewModel / LDAFillService static-var seam pattern.
    nonisolated(unsafe) internal static var extractProfileForTesting: (([URL], String, String, (Int, Int) -> Void) throws -> ExtractProfileResult)?

    /// Replaces LDAService.planFill in tests. Receives (target, profile) and
    /// returns a FillPlan or throws. The live profile is passed at the call site
    /// so tests can assert the hand-off. Nil in production.
    nonisolated(unsafe) internal static var planFillForTesting: ((URL, ClientPortfolio) throws -> FillPlan)?

    /// Replaces LDAService.applyFill in tests. Receives (plan, target, outputDir)
    /// and returns a FillReport or throws. Nil in production.
    nonisolated(unsafe) internal static var applyFillForTesting: ((FillPlan, URL, URL) throws -> FillReport)?

    // MARK: - Init

    public init(modelPath: String?) {
        self.modelPath = modelPath
    }

    // MARK: - Synchronous intents

    /// Set the profile directly and mark dirty. Stage is NOT updated; use
    /// loadProfile when a clean profile-ready state is desired.
    public func setProfile(_ profile: ClientPortfolio) {
        self.profile = profile
        profileDirty = true
    }

    /// Set the profile, advance stage to .profileReady, and clear the dirty flag.
    /// Used by extractProfile on success and by tests to seed a clean profile.
    public func loadProfile(_ profile: ClientPortfolio) {
        self.profile = profile
        profileDirty = false
        stage = .profileReady
    }

    /// Update a field's value and mark it user-edited. No-op when the field id
    /// is not found in the current profile.
    public func updateField(id: UUID, value: String) {
        guard let profileIndex = profile?.fields.firstIndex(where: { $0.id == id }) else { return }
        profile!.fields[profileIndex].value = value
        profile!.fields[profileIndex].userEdited = true
        profileDirty = true
    }

    /// Remove a field by id. No-op when id is not found.
    public func removeField(id: UUID) {
        guard let idx = profile?.fields.firstIndex(where: { $0.id == id }) else { return }
        profile!.fields.remove(at: idx)
        profileDirty = true
    }

    /// Resolve a key conflict by keeping one field and removing the rest.
    /// The winning field is identified by keepFieldID; every OTHER field with
    /// the same key is removed. conflictedKeys is derived, so it clears
    /// automatically once only one normalized value remains for that key.
    public func resolveConflict(key: ProfileFieldKey, keepFieldID: UUID) {
        guard var p = profile else { return }
        p.fields = p.fields.filter { field in
            field.key == key ? field.id == keepFieldID : true
        }
        profile = p
        profileDirty = true
    }

    /// Accept a blank.
    ///
    /// If the blank is .proposed and has a non-nil proposedValue, the blank
    /// moves to .confirmed.
    ///
    /// If the blank is .proposed and proposedValue is nil (ambiguous match),
    /// the blank stays .proposed and pickerRequestID is set to the blank id
    /// so the UI knows to open the field picker. This is a NO-OP with respect
    /// to status.
    ///
    /// Any other status is left unchanged.
    public func acceptBlank(id: UUID) {
        guard let idx = blanks.firstIndex(where: { $0.id == id }) else { return }
        let blank = blanks[idx]
        guard blank.status == .proposed else { return }
        if blank.proposedValue != nil {
            blanks[idx].status = .confirmed
        } else {
            // M2: nil-then-reassign so SwiftUI .onChange observers re-fire even
            // when the same blank is accepted twice in a row (SwiftUI skips
            // .onChange if the new value equals the old value).
            pickerRequestID = nil
            pickerRequestID = id
        }
    }

    /// Clear the pending picker request. Call after the picker is dismissed or
    /// after the user selects a field so the request does not linger.
    public func clearPickerRequest() {
        pickerRequestID = nil
    }

    /// Accept all blanks that are .proposed and have a non-nil proposedValue.
    /// Blanks with nil proposedValue, .unmatched, and .rejected are skipped.
    public func acceptAllProposed() {
        for idx in blanks.indices {
            if blanks[idx].status == .proposed, blanks[idx].proposedValue != nil {
                blanks[idx].status = .confirmed
            }
        }
    }

    /// Move a blank to .rejected regardless of its current status.
    public func rejectBlank(id: UUID) {
        // M2: A pending picker request for this blank is no longer relevant once rejected.
        pickerRequestID = nil
        guard let idx = blanks.firstIndex(where: { $0.id == id }) else { return }
        blanks[idx].status = .rejected
    }

    /// Repoint a blank to a different profile field: set proposedFieldID,
    /// proposedValue (from the field's current value), and status .proposed.
    /// No-op when the blank id or field id is not found.
    public func repointBlank(id: UUID, fieldID: UUID) {
        // M2: The picker has been satisfied; clear the pending request.
        pickerRequestID = nil
        guard let blankIdx = blanks.firstIndex(where: { $0.id == id }) else { return }
        guard let field = profile?.fields.first(where: { $0.id == fieldID }) else { return }
        blanks[blankIdx].proposedFieldID = fieldID
        blanks[blankIdx].proposedValue = field.value
        blanks[blankIdx].status = .proposed
    }

    /// Navigate back to the profile builder from any fill-review stage.
    ///
    /// Sets stage to .profileReady and clears pickerRequestID. Any open security
    /// scope for the current target is NOT released here because the user may
    /// return to fill-review by opening the same target again; if they open a new
    /// target, startTargetScope will release the old scope before starting the new
    /// one.
    public func backToProfile() {
        pickerRequestID = nil
        stage = .profileReady
    }

    /// Move selection to the next blank, wrapping at the end.
    /// With no current selection, selects the first blank.
    public func selectNextBlank() {
        guard !blanks.isEmpty else { return }
        guard let current = selectedBlankID,
              let idx = blanks.firstIndex(where: { $0.id == current }) else {
            selectedBlankID = blanks[0].id
            return
        }
        selectedBlankID = blanks[(idx + 1) % blanks.count].id
    }

    /// Move selection to the previous blank, wrapping at the start.
    /// With no current selection, selects the last blank.
    public func selectPreviousBlank() {
        guard !blanks.isEmpty else { return }
        guard let current = selectedBlankID,
              let idx = blanks.firstIndex(where: { $0.id == current }) else {
            selectedBlankID = blanks[blanks.count - 1].id
            return
        }
        selectedBlankID = blanks[(idx + blanks.count - 1) % blanks.count].id
    }

    // MARK: - Async intents

    /// Extract a ClientPortfolio from source documents.
    ///
    /// Stage transitions: .importingSources -> .extracting -> .profileReady
    /// (or .failed on error). Progress is reported via onProgress from the
    /// LDAService facade.
    ///
    /// createdAtISO8601 is supplied by the caller; the model never reads the clock.
    public func extractProfile(sources: [URL], label: String, createdAtISO8601: String) async {
        // Stage starts at .importingSources (documents are being staged before the
        // LLM begins). The facade emits onProgress(0, total) when extraction actually
        // begins (after all imports succeed); we flip to .extracting on that first
        // callback so the stage honestly reflects what the engine is doing.
        stage = .importingSources
        progress = 0
        sourceWarnings = []

        let path = modelPath ?? ""
        let seam = Self.extractProfileForTesting

        let progressCallback: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            DispatchQueue.main.async {
                guard let self else { return }
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
                    return try seam(sources, label, createdAtISO8601, progressCallback)
                } else {
                    return try LDAService.extractProfile(
                        sources: sources,
                        label: label,
                        modelPath: path,
                        createdAtISO8601: createdAtISO8601,
                        onProgress: progressCallback
                    )
                }
            }.value

            // Build display strings for any sources that could not be imported.
            sourceWarnings = result.failedSources.map { "\($0.name): \($0.reason)" }
            progress = 1
            loadProfile(result.profile)

        } catch {
            stage = .failed(Self.describe(error))
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

        let seam = Self.planFillForTesting
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
            stage = .failed(Self.describe(error))
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

        let seam = Self.applyFillForTesting

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
            stage = .failed(Self.describe(error))
        }
    }

    // MARK: - Error rendering

    /// A user-facing one-line description of an error.
    private nonisolated static func describe(_ error: Error) -> String {
        switch error {
        case let ioError as DocumentIOError:
            switch ioError {
            case .unreadable(let detail):
                return "The file could not be read. \(detail)"
            case .unsupportedFormat(let detail):
                return "Unsupported format. \(detail)"
            case .corrupt(let detail):
                return "The file is corrupt. \(detail)"
            case .ocrUnavailable:
                return "OCR is unavailable on this system."
            case .decryptionFailed:
                return "The document could not be decrypted."
            case .keychainError(let status):
                return "A Keychain error occurred (status \(status))."
            }
        case let svcError as LDAServiceError:
            switch svcError {
            case .noReadableSources:
                return "None of the source documents could be imported."
            case .staleTarget(let detail):
                return "The target document changed since planning. \(detail)"
            case .outputEqualsInput:
                return "The output path must differ from the source path."
            case .incompleteExtraction(let count):
                return "Extraction could not fully scan \(count) "
                    + (count == 1 ? "segment" : "segments") + "; some fields may be missing."
            }
        default:
            return error.localizedDescription
        }
    }
}
