//
//  ZipImporter.swift
//  LDACore
//
//  Session .zip import (R19): a dropped archive expands into the session's
//  documents. Only supported document types are extracted; macOS junk entries
//  (__MACOSX, dotfiles), directories, unsupported types, and any entry whose
//  path would escape the expansion directory (zip-slip) are skipped.
//
//  Two things this unit is responsible for beyond extraction:
//
//  1. CLEANUP. Expansion writes the user's original, un-redacted documents into
//     a temporary directory. Leaving them there until the OS decides to purge
//     /var/folders means plaintext client material outlives the session that
//     needed it, which is the one thing this app exists to prevent. Every
//     expansion is therefore registered, and a host clears them at a boundary
//     it controls: the CLI and the MCP server at the end of the command or
//     request, the GUI when the document tray empties and at termination.
//     Expanded files must stay readable for as long as the session holds them,
//     so cleanup cannot be a defer inside expand().
//
//  2. CEILINGS. The uncompressed-size budget is charged for bytes ACTUALLY
//     inflated, streamed through a counting consumer, because the declared
//     uncompressedSize in the central directory is attacker controlled and
//     the inflater runs to end-of-stream regardless of it: a bomb can declare
//     one byte and expand to gigabytes. The declared size still serves as a
//     fast pre-check so an honestly-declared oversize archive fails before
//     any I/O, but enforcement never trusts it. Entry count is capped too.
//     See ImportLimits.
//
//     The allowance is an ArchiveBudget the CALLER owns, so every archive in
//     one user-initiated import spends the same ledger. Minting a fresh one
//     per call was the defect that let a folder of high-ratio archives, or a
//     workspace carrying them, multiply the ceiling by the number of files.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import ZIPFoundation

/// Expands .zip archives into per-session document sets.
public enum ZipImporter {

    // MARK: - Expanded archive

    /// One expansion: the temporary directory it lives in and the documents
    /// extracted into it.
    ///
    /// Hold this for as long as the documents are in use, then call cleanUp().
    /// A host that cannot conveniently track individual expansions can call
    /// ZipImporter.cleanUpAllExpansions() at a session boundary instead.
    public struct ExpandedArchive {
        /// The temporary directory holding the extracted documents.
        public let directory: URL
        /// The extracted document URLs, sorted by their path inside the archive.
        public let documents: [URL]

        /// Delete the expansion directory and everything in it.
        ///
        /// Idempotent and best effort: an already-removed directory is success,
        /// and a failure to remove is reported through the return value rather
        /// than thrown, because cleanup runs on paths where the primary work has
        /// already succeeded and must not be turned into a failure. A caller
        /// that wants to surface the problem can inspect the result.
        @discardableResult
        public func cleanUp() -> Bool {
            ZipImporter.deregister(directory)
            guard FileManager.default.fileExists(atPath: directory.path) else { return true }
            do {
                try FileManager.default.removeItem(at: directory)
                return true
            } catch {
                return false
            }
        }
    }

    // MARK: - Expansion registry

    private static let registryLock = NSLock()
    private static var liveExpansions: Set<URL> = []

    /// Put a temporary expansion directory under the cleanup contract.
    ///
    /// Internal rather than private because the workspace reader unpacks its
    /// own documents and must land under the SAME contract: one registry, one
    /// set of boundaries, no second way for un-redacted originals to be left
    /// behind in /var/folders.
    static func register(_ directory: URL) {
        registryLock.lock()
        liveExpansions.insert(directory)
        registryLock.unlock()
    }

    private static func deregister(_ directory: URL) {
        registryLock.lock()
        liveExpansions.remove(directory)
        registryLock.unlock()
    }

    /// The expansion directories registered right now.
    ///
    /// For a caller that must clean up exactly the expansions that existed
    /// BEFORE it created its own: snapshot first, create, then clean up the
    /// snapshot. Opening a workspace does this, so a failure while unpacking
    /// the incoming file cannot destroy the session it was going to replace.
    public static func registeredExpansions() -> Set<URL> {
        registryLock.lock()
        defer { registryLock.unlock() }
        return liveExpansions
    }

    /// Delete the given expansions and leave every other registered expansion
    /// alone. Same cleanup contract as cleanUpAllExpansions, narrower scope.
    ///
    /// - Returns: how many expansion directories were removed.
    @discardableResult
    public static func cleanUpExpansions(_ directories: Set<URL>) -> Int {
        registryLock.lock()
        liveExpansions.subtract(directories)
        registryLock.unlock()

        var removed = 0
        for directory in directories {
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            if (try? FileManager.default.removeItem(at: directory)) != nil {
                removed += 1
            }
        }
        return removed
    }

    /// Delete every expansion this process has created and not yet cleaned up.
    ///
    /// Call this at a boundary where no expanded document is still in use: the
    /// end of a CLI command, the end of an MCP request, an emptied GUI tray, or
    /// application termination.
    ///
    /// - Returns: how many expansion directories were removed.
    @discardableResult
    public static func cleanUpAllExpansions() -> Int {
        registryLock.lock()
        let directories = liveExpansions
        liveExpansions = []
        registryLock.unlock()

        var removed = 0
        for directory in directories {
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            if (try? FileManager.default.removeItem(at: directory)) != nil {
                removed += 1
            }
        }
        return removed
    }

    /// How many expansions are live. Test visibility for the cleanup contract.
    public static var liveExpansionCount: Int {
        registryLock.lock()
        defer { registryLock.unlock() }
        return liveExpansions.count
    }

    // MARK: - Recognition

    /// The document extensions a session can import from an archive. Images
    /// (png / jpg / jpeg) are session documents since the standalone image
    /// feature: chat screenshots and receipts arrive zipped as often as not.
    public static let supportedExtensions: Set<String> =
        ["docx", "pdf", "txt", "md", "text", "png", "jpg", "jpeg"]

    /// True when the URL looks like a zip archive (by extension).
    public static func isZip(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "zip"
    }

    // MARK: - Expansion

    /// Expand the archive into a fresh temporary directory.
    ///
    /// Skipped entries: directories and symlinks, __MACOSX resource forks, any
    /// path component starting with ".", unsupported extensions, and any entry
    /// whose normalized destination would fall outside the expansion directory.
    ///
    /// - Parameter zipURL: the archive to expand.
    /// - Returns: the expansion, whose documents may be empty. The caller owns
    ///   cleanup; see ExpandedArchive.cleanUp().
    /// - Throws: DocumentIOError.unreadable when the file is not a readable
    ///   zip archive, DocumentIOError.tooLarge when the archive exceeds an
    ///   ImportLimits ceiling, or the underlying write error during extraction.
    ///
    /// This overload expands ONE archive on its own allowance. A caller
    /// expanding several archives for one user gesture must use the
    /// budget-taking overload instead, or the ceiling stops compounding.
    public static func expand(_ zipURL: URL) throws -> ExpandedArchive {
        try expand(zipURL, budget: ArchiveBudget())
    }

    /// Expand the archive, spending the given import's allowance.
    ///
    /// - Parameter budget: the ledger for the whole user-initiated import.
    ///   Pass the SAME instance for every archive in that import.
    public static func expand(_ zipURL: URL, budget: ArchiveBudget) throws -> ExpandedArchive {
        try ImportLimits.enforceDocumentSize(at: zipURL)

        let archive: Archive
        do {
            archive = try Archive(url: zipURL, accessMode: .read)
        } catch {
            throw DocumentIOError.unreadable(
                "\(zipURL.lastPathComponent) is not a readable zip archive: \(error)"
            )
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("lda-zip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        register(destination)
        let expansion = ExpandedArchive(directory: destination, documents: [])
        let destinationPath = destination.standardizedFileURL.path

        var extracted: [(entryPath: String, url: URL)] = []
        var examinedEntries = 0
        let budgetMessage = budget.refusalMessage(for: zipURL.lastPathComponent)

        do {
            for entry in archive {
                examinedEntries += 1
                guard examinedEntries <= ImportLimits.maxArchiveEntries else {
                    throw DocumentIOError.tooLarge(
                        "\(zipURL.lastPathComponent) declares more than "
                            + "\(ImportLimits.maxArchiveEntries) entries."
                    )
                }
                guard entry.type == .file else { continue }

                let entryPath = entry.path
                guard isSupportedEntryPath(entryPath) else { continue }

                // Fast pre-check on the DECLARED size so an honestly-labeled
                // oversize archive fails before any I/O. This is an
                // optimization, not the defense: the declared size is attacker
                // controlled, so the enforcement below meters actual bytes.
                guard !budget.cannotFit(declared: entry.uncompressedSize) else {
                    throw DocumentIOError.tooLarge(budgetMessage)
                }

                let target = destination.appendingPathComponent(entryPath)
                // Zip-slip guard: the normalized target must stay inside the
                // expansion directory.
                let normalized = target.standardizedFileURL.path
                guard normalized.hasPrefix(destinationPath + "/") else { continue }

                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                // Stream the entry through a counting consumer and charge the
                // budget for what the inflater ACTUALLY produces. ZIPFoundation
                // inflates to end-of-stream without consulting the declared
                // size, so this mid-stream abort is the only place a
                // lying-declaration bomb can be stopped; the write cost before
                // the abort is bounded by the remaining budget.
                try extractMetered(
                    entry,
                    from: archive,
                    to: target,
                    budget: budget,
                    budgetMessage: budgetMessage
                )
                extracted.append((entryPath, target))
            }
        } catch {
            // A rejected or failed expansion must not leave the partially
            // written originals behind; that is exactly the residue this unit
            // is responsible for not creating.
            expansion.cleanUp()
            throw error
        }

        return ExpandedArchive(
            directory: destination,
            documents: extracted
                .sorted { $0.entryPath < $1.entryPath }
                .map { $0.url }
        )
    }

    /// Extract one entry to `target`, charging the import's ledger for each
    /// inflated chunk and aborting with tooLarge the moment it runs out.
    ///
    /// The metering itself lives in ZipExtraction so the workspace reader
    /// charges bytes the same way; see that file for why the DECLARED size can
    /// never be the enforcement.
    private static func extractMetered(
        _ entry: Entry,
        from archive: Archive,
        to target: URL,
        budget: ArchiveBudget,
        budgetMessage: String
    ) throws {
        try ZipExtraction.extractMetered(
            entry,
            from: archive,
            to: target,
            budget: budget,
            budgetMessage: budgetMessage
        )
    }

    /// True when an archive entry path denotes a supported, non-junk document.
    private static func isSupportedEntryPath(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        guard let fileName = components.last else { return false }
        // macOS resource forks and hidden files anywhere in the path.
        guard components.first != "__MACOSX" else { return false }
        guard !components.contains(where: { $0.hasPrefix(".") }) else { return false }
        // Path traversal components are never extracted.
        guard !components.contains("..") else { return false }
        let ext = (fileName as NSString).pathExtension.lowercased()
        return supportedExtensions.contains(ext)
    }
}
