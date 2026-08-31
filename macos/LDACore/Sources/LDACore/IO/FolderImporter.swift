//
//  FolderImporter.swift
//  LDACore
//
//  Directory batch import (F3): recursive discovery of the session's
//  supported document types under a user-chosen folder, plus the batch
//  budgets that bound what one folder import may pull into the tray.
//
//  Discovery rules: hidden files and hidden directories are skipped, package
//  directories (.app and friends) are opaque and never descended into,
//  symlinks are never followed (file or directory, so a cycle cannot recurse
//  and a link cannot reach outside the folder the user granted), archives are
//  not collected (see supportedExtensions), and the result is sorted by full
//  path so the tray order, and with it the cross-document sweep order, is
//  reproducible run to run.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

public enum FolderImporter {

    /// The document types a directory import collects: text, Word, PDF, and
    /// evidence images.
    ///
    /// Archives are deliberately NOT collected. A folder import is the app's
    /// lowest-trust entry point (the user picks a folder somebody sent them,
    /// with no passphrase and no per-file decision), and a .zip inside it is a
    /// container the user never chose to open. Recursing into one would also
    /// make maxBatchFileCount meaningless, since each of the 200 permitted
    /// entries could fan out to hundreds of tray documents. A user who does
    /// want an archive's contents drops the .zip on the app directly, which
    /// still expands, metered by the import's ArchiveBudget.
    public static let supportedExtensions: Set<String> =
        ["txt", "docx", "pdf", "png", "jpg", "jpeg"]

    /// The most files one directory import may add to the tray.
    ///
    /// Calibration: every document gets its own review model and its own
    /// sequential scan pass, so 200 documents is already far beyond a
    /// workable review session. The ceiling exists to stop a mis-chosen
    /// folder (a whole case archive, a home directory) from flooding the
    /// tray, not to constrain real work.
    public static let maxBatchFileCount = 200

    /// The most total bytes one directory import may reference (500 MB).
    /// Matches ImportLimits.maxArchiveUncompressedBytes, so a folder cannot
    /// bring in more than a zip of the same content would be allowed to.
    /// This budget counts bytes ON DISK, which is only a true measure because
    /// discovery collects no archives; an inflating file type would need the
    /// ArchiveBudget ledger instead.
    public static let maxBatchTotalBytes = 500 * 1024 * 1024

    /// The resource metadata one discovery pass reads per entry.
    private static let discoveryKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isHiddenKey
    ]

    // MARK: - Selection expansion

    /// Expand an Open panel selection: every chosen directory contributes its
    /// discovered documents and chosen files pass through unchanged. When the
    /// selection contains at least one directory, the WHOLE resolved batch is
    /// checked against the batch budgets before anything reaches the tray;
    /// a pure file selection keeps today's unbudgeted multi-file behavior.
    public static func expandSelection(_ urls: [URL]) throws -> [URL] {
        var resolved: [URL] = []
        var containsDirectory = false
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if values?.isDirectory == true, values?.isPackage != true {
                containsDirectory = true
                resolved.append(contentsOf: try discoverDocuments(in: url))
            } else {
                resolved.append(url)
            }
        }
        if containsDirectory {
            try enforceBatchBudget(on: resolved)
        }
        return resolved
    }

    // MARK: - Discovery

    /// Recursively discover the supported documents under one directory, in
    /// deterministic sorted-path order. See the header for the skip rules.
    public static func discoverDocuments(in directory: URL) throws -> [URL] {
        var found: [URL] = []
        try collectSupportedFiles(under: directory, into: &found)
        return found.sorted { $0.path < $1.path }
    }

    private static func collectSupportedFiles(
        under directory: URL,
        into found: inout [URL]
    ) throws {
        // Children are rebuilt from the parent the caller handed in, so the
        // returned URLs keep the caller's path spelling. Enumerating with
        // contentsOfDirectory(at:) instead would rewrite /var into
        // /private/var and the discovered URLs would stop being prefix
        // children of the chosen folder.
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        for name in names {
            let child = directory.appendingPathComponent(name)
            let values = try? child.resourceValues(forKeys: discoveryKeys)
            // Hidden entries are configuration or junk, never documents; a
            // hidden directory hides its whole subtree.
            if values?.isHidden == true || child.lastPathComponent.hasPrefix(".") {
                continue
            }
            // A symlink is never followed, whatever it points at.
            if values?.isSymbolicLink == true {
                continue
            }
            if values?.isDirectory == true {
                // A package (.app and friends) is one opaque item to the
                // user; its internals are program files, not documents.
                if values?.isPackage == true {
                    continue
                }
                try collectSupportedFiles(under: child, into: &found)
                continue
            }
            if supportedExtensions.contains(child.pathExtension.lowercased()) {
                found.append(child)
            }
        }
    }

    // MARK: - Batch budgets

    /// Throw when the batch breaches a budget, naming which budget and the
    /// offending measure so the user can act on the message.
    static func enforceBatchBudget(on urls: [URL]) throws {
        guard urls.count <= maxBatchFileCount else {
            throw DocumentIOError.tooLarge(
                "Folder contains \(urls.count) supported files; "
                    + "the import limit is \(maxBatchFileCount)."
            )
        }
        let totalBytes = urls.reduce(0) { $0 + (ImportLimits.fileSize(at: $1) ?? 0) }
        guard totalBytes <= maxBatchTotalBytes else {
            throw DocumentIOError.tooLarge(
                "Folder contains \(ImportLimits.describe(bytes: totalBytes)) of documents; "
                    + "the import limit is \(ImportLimits.describe(bytes: maxBatchTotalBytes))."
            )
        }
    }
}
