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
        try requireArchivedReviewsDescribeTheirFiles()
        try WorkspaceArchive.write(
            buildWorkspacePayload(createdAtISO8601: createdAtISO8601),
            to: url,
            passphrase: passphrase
        )
    }

    /// A snapshot travels with the file it describes, and the archive copies
    /// the FILE as it is now. If a file changed after its scan, the pair would
    /// hand a colleague an "original" nobody reviewed, with decisions that
    /// relocate by value onto it and read as a finished review. Refuse, and
    /// name the document, because a workspace holds several and only one
    /// needs opening again; the remedy is the export's.
    private func requireArchivedReviewsDescribeTheirFiles() throws {
        for entry in entries where entry.model.exportAvailability.isAvailable {
            do {
                try entry.model.requireSourceUnchangedSinceScan()
            } catch is SourceChangedSinceScanError {
                throw WorkspaceSourceChangedError(documentName: entry.name)
            }
        }
    }

    /// Everything the archive needs from this session.
    ///
    /// - Parameters:
    ///   - documentIDs: the tray entries to include, or nil for all of them.
    ///     Save Workspace packages the whole session; the default workspace an
    ///     export keeps its mapping in packages the ONE document it belongs to,
    ///     so a matter's other documents are not copied into a file named
    ///     after this one.
    ///   - mapping: the mapping to store, or nil for the session's. An export
    ///     passes its own, because the export mints the key and the session
    ///     has not adopted it yet at the moment the workspace is written.
    func buildWorkspacePayload(
        createdAtISO8601: String,
        documentIDs: Set<UUID>? = nil,
        mapping overrideMapping: Mapping? = nil
    ) -> WorkspacePayload {
        let entries = documentIDs.map { ids in
            self.entries.filter { ids.contains($0.id) }
        } ?? self.entries
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
            mapping: overrideMapping ?? sessionMapping,
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

    // MARK: - The default workspace an export keeps its mapping in
    //
    // Save Redacted writes no .ldamap beside its output any more, so the key
    // has to be kept somewhere the app can find later or the user is left
    // with a redacted document nothing can restore. It is kept in a
    // workspace, using the machinery above rather than a second store of its
    // own: same format, same reader, same validation.
    //
    // WHICH WORKSPACE. The one named after the document, derived from the
    // source file's own path (DefaultWorkspace), and sealed with a key in
    // this Mac's Keychain. It is created when the user chose no destination,
    // which today is every Save Redacted, and updated in place on every
    // later export of the same document.
    //
    // WHAT STAYS AVAILABLE, deliberately. A workspace the user SAVES is a
    // different thing and is never touched here: it is passphrase protected
    // so it can be handed to a colleague, this app keeps no copy of that
    // passphrase, and a file meant to travel must not change under the person
    // holding it. And a mapping can still travel two ways on purpose: a
    // passphrase protected .ldamap sidecar from the export sheet, or Save
    // Workspace. A mapping that cannot travel cannot be restored on another
    // Mac, so neither route is closed by keeping a local default.

    /// The default workspace file for the document at `source`.
    public func defaultWorkspaceURL(forSource source: URL) throws -> URL {
        DefaultWorkspace.url(
            forSource: source,
            in: try defaultWorkspaceDirectory()
        )
    }

    /// The mapping an export of `source` must extend.
    ///
    /// The session's own mapping when it has one, and otherwise whatever the
    /// document's default workspace already holds. That second half is not
    /// belt and braces: after a quit and relaunch the session mapping is gone,
    /// and an unseeded second export would mint the same {COMPANY_1} for a
    /// different value, then overwrite the workspace and leave the FIRST
    /// export's redacted file restoring to the wrong party. Seeding makes
    /// every rewrite of a default workspace a superset of what it replaced.
    ///
    /// A workspace that cannot be opened yields no seed rather than throwing,
    /// and the export goes on to REPLACE it. That is deliberate and it loses
    /// nothing: a workspace this Mac can no longer open was already no key to
    /// anything, so refusing to overwrite it would only leave the user with a
    /// document they cannot redact and a file they cannot read. What it must
    /// never do is replace a workspace that WOULD have opened, which is why
    /// the seed is read on the same rule the writer names its output by.
    func exportMappingSeed(forSource source: URL) -> Mapping? {
        if let sessionMapping { return sessionMapping }
        return try? defaultWorkspaceMapping(forSource: source)
    }

    /// The mapping held in the default workspace for a document, or nil when
    /// that workspace does not exist.
    ///
    /// Reads the mapping member only: no document is unpacked, so this never
    /// puts a plaintext original back on disk to answer a question about the
    /// key.
    public func defaultWorkspaceMapping(forSource source: URL) throws -> Mapping? {
        let url = try defaultWorkspaceURL(forSource: source)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try WorkspaceArchive.readMapping(
            from: url,
            protection: defaultWorkspaceProtection(url)
        )
    }

    /// Keep an export's mapping in the document's default workspace, and adopt
    /// it as the session's mapping so a restore in this same sitting needs no
    /// file at all.
    ///
    /// Returns where it was kept. Throws rather than degrading: a caller that
    /// has already written a redacted document needs to hear that its key did
    /// not land, because nothing else on screen would say so. ReviewModel.export
    /// takes that further and removes what it wrote, so a failure here cannot
    /// leave an unrestorable document behind.
    @discardableResult
    public func keepMappingInWorkspace(
        _ mapping: Mapping,
        forSource source: URL,
        documentID: UUID,
        createdAtISO8601: String
    ) throws -> URL {
        let url = try defaultWorkspaceURL(forSource: source)
        try WorkspaceArchive.write(
            buildWorkspacePayload(
                createdAtISO8601: createdAtISO8601,
                documentIDs: [documentID],
                mapping: mapping
            ),
            to: url,
            protection: defaultWorkspaceProtection(url)
        )
        adoptWorkspaceMapping(mapping)
        return url
    }

    /// The mapping that restores `redactedFile`, taken from the default
    /// workspace the export kept it in, or nil when there is no single
    /// workspace that can be said to belong to that file.
    ///
    /// Resolved from the file's NAME, because the file that came back is all
    /// Restore has. Two documents with the same stem resolve to two
    /// workspaces, and this returns nil rather than choosing between them: see
    /// DefaultWorkspace's header for why guessing there would restore one
    /// matter's document with another matter's names.
    public func defaultWorkspaceMapping(forRedactedFile redactedFile: URL) throws -> Mapping? {
        guard let url = DefaultWorkspace.unambiguousCandidate(
            forRedactedFileNamed: redactedFile.lastPathComponent,
            in: try defaultWorkspaceDirectory()
        ) else { return nil }
        return try WorkspaceArchive.readMapping(
            from: url,
            protection: defaultWorkspaceProtection(url)
        )
    }

    // MARK: - Save Redacted

    /// Redact the active document into `outputDir` and keep its key.
    ///
    /// The session owns this rather than the review model because the key's
    /// home is a workspace, and a workspace is session state: the matter
    /// label, the pseudonym overrides, the matter's own rule layer. The
    /// per-document model cannot see any of that.
    ///
    /// - Parameter passphrase: nil, the default, writes no .ldamap beside the
    ///   output. A passphrase writes one, protected by it, for a mapping the
    ///   user means to carry to another Mac.
    public func exportRedacted(
        to outputDir: URL,
        passphrase: String?,
        createdAtISO8601: String
    ) async throws -> ExportResult {
        guard let entry = activeEntry else {
            throw DocumentIOError.unreadable("No document is open to redact.")
        }
        let source = entry.url
        let documentID = entry.id
        return try await entry.model.export(
            to: outputDir,
            passphrase: passphrase,
            createdAtISO8601: createdAtISO8601,
            seedMapping: exportMappingSeed(forSource: source),
            keepMapping: { mapping in
                try keepMappingInWorkspace(
                    mapping,
                    forSource: source,
                    documentID: documentID,
                    createdAtISO8601: createdAtISO8601
                )
            }
        )
    }
}
