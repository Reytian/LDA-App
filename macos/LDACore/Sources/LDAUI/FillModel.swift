//
//  FillModel.swift
//  LDAUI
//
//  The testable view-model that orchestrates LDACore's fill-from-profile feature.
//  The user imports source documents, the model extracts a CompanyProfile, the user
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

    /// The extracted or user-loaded company profile. Nil before extraction completes.
    @Published public var profile: CompanyProfile?

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

    // MARK: - Test seams

    /// Replaces LDAService.extractProfile in tests. Receives (sources, label,
    /// createdAtISO8601) and returns an ExtractProfileResult or throws. Nil in
    /// production. Mirrors the ReviewModel / LDAFillService static-var seam pattern.
    nonisolated(unsafe) internal static var extractProfileForTesting: (([URL], String, String) throws -> ExtractProfileResult)?

    /// Replaces LDAService.planFill in tests. Receives the target URL and
    /// returns a FillPlan or throws. Profile is captured from the model at call
    /// time. Nil in production.
    nonisolated(unsafe) internal static var planFillForTesting: ((URL) throws -> FillPlan)?

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
    public func setProfile(_ profile: CompanyProfile) {
        self.profile = profile
        profileDirty = true
    }

    /// Set the profile, advance stage to .profileReady, and clear the dirty flag.
    /// Used by extractProfile on success and by tests to seed a clean profile.
    public func loadProfile(_ profile: CompanyProfile) {
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
            // Signal the UI to open the picker for this blank.
            pickerRequestID = id
        }
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
        guard let idx = blanks.firstIndex(where: { $0.id == id }) else { return }
        blanks[idx].status = .rejected
    }

    /// Repoint a blank to a different profile field: set proposedFieldID,
    /// proposedValue (from the field's current value), and status .proposed.
    /// No-op when the blank id or field id is not found.
    public func repointBlank(id: UUID, fieldID: UUID) {
        guard let blankIdx = blanks.firstIndex(where: { $0.id == id }) else { return }
        guard let field = profile?.fields.first(where: { $0.id == fieldID }) else { return }
        blanks[blankIdx].proposedFieldID = fieldID
        blanks[blankIdx].proposedValue = field.value
        blanks[blankIdx].status = .proposed
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

    /// Extract a CompanyProfile from source documents.
    ///
    /// Stage transitions: .importingSources -> .extracting -> .profileReady
    /// (or .failed on error). Progress is reported via onProgress from the
    /// LDAService facade.
    ///
    /// createdAtISO8601 is supplied by the caller; the model never reads the clock.
    public func extractProfile(sources: [URL], label: String, createdAtISO8601: String) async {
        stage = .importingSources
        progress = 0
        sourceWarnings = []

        let path = modelPath ?? ""
        let seam = Self.extractProfileForTesting

        let progressCallback: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            DispatchQueue.main.async {
                guard let self else { return }
                if total > 0 { self.progress = Double(done) / Double(total) }
            }
        }

        // Transition to extracting before launching off-main work.
        stage = .extracting

        do {
            let result = try await Task.detached(priority: .userInitiated) {
                if let seam {
                    return try seam(sources, label, createdAtISO8601)
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
        stage = .planning
        targetURL = target

        let seam = Self.planFillForTesting
        let path = modelPath

        do {
            let plan = try await Task.detached(priority: .userInitiated) {
                if let seam {
                    return try seam(target)
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

        } catch {
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
        guard let profile, let targetURL else { return }
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

            stage = .done(report)

        } catch {
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
