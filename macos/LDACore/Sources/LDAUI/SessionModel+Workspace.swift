//
//  SessionModel+Workspace.swift
//  LDAUI
//
//  The session's half of the portable workspace (.ldawork): turn a live matter
//  into one file, and turn one file back into a live matter.
//
//  What travels: the original documents, every review decision and manual
//  entity, the assigned replacements, the session mapping, the pseudonym
//  overrides, and the MATTER layer's learned rules and vocabulary. What does
//  not: the global learned-rule and vocabulary layers. Those are the user's own
//  accumulated habits across every client they have ever worked on, and
//  shipping them inside a file handed to a colleague would leak a de facto
//  client list. Only the matter's own layer is the matter's to send.
//
//  What also does not travel: UI state. No selection, no scroll position, no
//  window size. A workspace restores work.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import LDACore

// MARK: - Open summary

/// What opening a workspace produced, for the banner the user reads.
public struct WorkspaceOpenSummary: Equatable, Sendable {
    public let documentCount: Int
    public let matterLabel: String?
    public let restoredEntityCount: Int

    /// Anything the user should know that did not stop the open: an archived
    /// matter, an override that no longer validates, entities that had to be
    /// relocated. Empty on a clean restore.
    public let warnings: [String]
}

extension SessionModel {

    // MARK: - Save

    /// Whether Save Workspace can run, and why not when it cannot. One
    /// document is the floor: an empty tray has no work to package.
    ///
    /// The same availability type Save Redacted uses, so the two gates state
    /// their asymmetry instead of hiding it behind two Bools that differ.
    public var workspaceAvailability: SaveAvailability {
        SaveAvailabilityRules.saveWorkspace(documentCount: entries.count)
    }

    /// Package the current session into a single encrypted file.
    ///
    /// - Parameters:
    ///   - url: the chosen .ldawork destination.
    ///   - passphrase: the only thing that will open the file again. Nothing
    ///     about it is recoverable from this Mac.
    ///   - createdAtISO8601: supplied by the caller; this layer reads no clock.
    public func saveWorkspace(
        to url: URL,
        passphrase: String,
        createdAtISO8601: String
    ) throws {
        try WorkspaceArchive.write(
            buildWorkspacePayload(createdAtISO8601: createdAtISO8601),
            to: url,
            passphrase: passphrase
        )
    }

    /// Everything the archive needs from this session.
    func buildWorkspacePayload(createdAtISO8601: String) -> WorkspacePayload {
        let records = entries.map { entry in
            WorkspaceDocumentRecord(
                id: entry.id,
                name: entry.name,
                contentKind: entry.url.pathExtension.lowercased(),
                archivePath: WorkspaceArchive.documentArchivePath(
                    id: entry.id,
                    name: entry.name
                )
            )
        }
        let manifest = WorkspaceManifest(
            formatVersion: WorkspaceArchive.currentFormatVersion,
            createdAtISO8601: createdAtISO8601,
            appVersion: appVersionProvider(),
            matterLabel: clientLabel,
            matterScopeID: matterScopeID,
            substitutionStyle: outputStyleProvider(),
            documents: records
        )
        let matterLists = archivedMatterLists()
        return WorkspacePayload(
            manifest: manifest,
            documentSources: Dictionary(
                uniqueKeysWithValues: entries.map { ($0.id, $0.url) }
            ),
            mapping: sessionMapping,
            sessionState: WorkspaceSessionState(pseudonymOverrides: pseudonymOverrides),
            snapshots: entries.filter { $0.model.exportAvailability.isAvailable }
                .map { $0.model.workspaceSnapshot(documentID: $0.id) },
            matterLearnedTermsJSON: matterLists.learnedTerms,
            matterCustomPatternsJSON: matterLists.customPatterns
        )
    }

    /// The MATTER layer's rules as JSON, or nils when no matter layer exists.
    /// The global layers are never read here; see this file's header.
    private func archivedMatterLists() -> (learnedTerms: Data?, customPatterns: Data?) {
        guard matterScopeID != nil else { return (nil, nil) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let terms = scopedLearningStore?.matter.map { $0.allTerms }
        let patterns = scopedPatternStore?.matter.map { $0.activePatterns }
        return (
            terms.flatMap { try? encoder.encode($0) },
            patterns.flatMap { try? encoder.encode($0) }
        )
    }

    // MARK: - Open

    /// Replace this session with the one stored in a workspace file.
    ///
    /// The file is decrypted, validated AND unpacked BEFORE anything live is
    /// discarded, so a wrong passphrase, a file from a newer LDA, a damaged
    /// member or an over-budget archive all cost the user nothing.
    ///
    /// - Throws: WorkspaceArchiveError from the format layer.
    @discardableResult
    public func openWorkspace(at url: URL, passphrase: String) async throws -> WorkspaceOpenSummary {
        // One ledger for the whole open: the workspace's own members and the
        // tray import that follows spend the SAME unpacking allowance, so a
        // single user gesture cannot inflate more than the ceiling however the
        // file is nested.
        let budget = ArchiveBudget()
        let prepared = try WorkspaceArchive.prepare(
            from: url,
            passphrase: passphrase,
            budget: budget
        )
        // Unpack BEFORE discarding live work. prepare() proves the passphrase
        // and the format version, but unpacking can still fail on a damaged
        // member or the inflated-size budget, and a tray emptied ahead of that
        // failure is unrecoverable user work.
        let outgoingExpansions = ZipImporter.registeredExpansions()
        let opened = try prepared.unpack()
        resetForWorkspaceOpen(discardingExpansions: outgoingExpansions)

        var warnings = adoptWorkspaceMatter(opened)
        await addDocuments(opened.orderedDocumentURLs, budget: budget)
        if let failure = importFailure {
            warnings.append(failure)
        }

        let restoredCount = applyWorkspaceSnapshots(opened, warnings: &warnings)
        adoptWorkspaceMapping(opened.mapping)
        warnings.append(contentsOf: restoreWorkspaceOverrides(opened))

        return WorkspaceOpenSummary(
            documentCount: entries.count,
            matterLabel: clientLabel,
            restoredEntityCount: restoredCount,
            warnings: warnings
        )
    }

    /// Re-select the matter and rebuild its rule layer.
    ///
    /// Two ways this can land. When this Mac knows the matter, selectMatter
    /// adopts the LOCAL scope id and the archived rules merge into the local
    /// matter layer, which is what a colleague sharing a matter wants. When it
    /// does not, the layer is minted from the ARCHIVED id so the matter's rules
    /// still apply, standalone.
    private func adoptWorkspaceMatter(_ opened: OpenedWorkspace) -> [String] {
        var warnings: [String] = []
        if let label = opened.manifest.matterLabel {
            do {
                _ = try selectMatter(label, discardingDocuments: true)
            } catch {
                warnings.append(
                    WorkspacePresentation.matterSelectionWarning(
                        matterLabel: label,
                        errorDescription: error.localizedDescription
                    )
                )
            }
        }
        if matterScopeID == nil, let archivedID = opened.manifest.matterScopeID,
           opened.matterLearnedTermsJSON != nil || opened.matterCustomPatternsJSON != nil {
            adoptWorkspaceMatterScope(id: archivedID)
        }
        mergeWorkspaceMatterLists(opened)
        return warnings
    }

    /// Merge the archived matter-layer rules into whichever matter layer is
    /// now active. A merge, never a replace: the local matter may already hold
    /// rules this archive has never seen.
    private func mergeWorkspaceMatterLists(_ opened: OpenedWorkspace) {
        let decoder = JSONDecoder()
        if let data = opened.matterLearnedTermsJSON,
           let terms = try? decoder.decode([LearnedTerm].self, from: data) {
            scopedLearningStore?.layer(for: .matter)?.merge(terms)
        }
        if let data = opened.matterCustomPatternsJSON,
           let patterns = try? decoder.decode([CustomPattern].self, from: data) {
            scopedPatternStore?.layer(for: .matter)?.merge(patterns)
        }
    }

    /// Put each document's decisions back, without re-running detection.
    ///
    /// Snapshots are keyed by the SENDING session's tray id, and this session
    /// minted fresh ids when it imported the unpacked files. The unpacked file
    /// URL is the identity that survives the crossing: each document unpacks
    /// into its own id-named directory, so the path is unique per document.
    private func applyWorkspaceSnapshots(
        _ opened: OpenedWorkspace,
        warnings: inout [String]
    ) -> Int {
        var archivedIDByPath: [String: UUID] = [:]
        for (archivedID, url) in opened.documentURLs {
            archivedIDByPath[url.standardizedFileURL.path] = archivedID
        }

        var restored = 0
        for entry in entries {
            guard let archivedID = archivedIDByPath[entry.url.standardizedFileURL.path],
                  let snapshot = opened.snapshots[archivedID] else { continue }
            let result = entry.model.applyWorkspaceSnapshot(snapshot)
            restored += result.appliedCount
            guard result.didRelocate else { continue }
            warnings.append(
                WorkspacePresentation.snapshotRelocationWarning(
                    documentName: entry.name,
                    appliedCount: result.appliedCount,
                    droppedCount: result.droppedCount
                )
            )
        }
        return restored
    }

    /// Reinstate the pseudonym overrides through the ordinary setter, so a
    /// restored override is held to exactly the rules a typed one is.
    private func restoreWorkspaceOverrides(_ opened: OpenedWorkspace) -> [String] {
        var warnings: [String] = []
        for surface in opened.sessionState.pseudonymOverrides.keys.sorted() {
            let replacement = opened.sessionState.pseudonymOverrides[surface]
            do {
                try setPseudonymOverride(surface: surface, replacement: replacement)
            } catch {
                let detail: String
                if let overrideError = error as? PseudonymOverrideError {
                    detail = PseudonymOverrideErrorPresentation.message(
                        for: overrideError
                    )
                } else {
                    detail = DocumentErrorPresentation.describeOrFallback(error)
                }
                warnings.append(
                    WorkspacePresentation.savedReplacementWarning(
                        errorDescription: detail
                    )
                )
            }
        }
        return warnings
    }
}
