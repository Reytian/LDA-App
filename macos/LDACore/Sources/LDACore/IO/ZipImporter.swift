//
//  ZipImporter.swift
//  LDACore
//
//  Session .zip import (R19): a dropped archive expands into the session's
//  documents. Only supported document types are extracted; macOS junk entries
//  (__MACOSX, dotfiles), directories, unsupported types, and any entry whose
//  path would escape the expansion directory (zip-slip) are skipped.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import ZIPFoundation

/// Expands .zip archives into per-session document sets.
public enum ZipImporter {

    /// The document extensions a session can import from an archive.
    public static let supportedExtensions: Set<String> = ["docx", "pdf", "txt", "md", "text"]

    /// True when the URL looks like a zip archive (by extension).
    public static func isZip(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "zip"
    }

    /// Expand the archive into a fresh temporary directory and return the
    /// extracted document URLs, sorted by their path inside the archive.
    ///
    /// Skipped entries: directories and symlinks, __MACOSX resource forks, any
    /// path component starting with ".", unsupported extensions, and any entry
    /// whose normalized destination would fall outside the expansion directory.
    ///
    /// - Parameter zipURL: the archive to expand.
    /// - Returns: URLs of the extracted documents (possibly empty).
    /// - Throws: DocumentIOError.unreadable when the file is not a readable
    ///   zip archive, or the underlying write error during extraction.
    public static func expand(_ zipURL: URL) throws -> [URL] {
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
        let destinationPath = destination.standardizedFileURL.path

        var extracted: [(entryPath: String, url: URL)] = []

        for entry in archive where entry.type == .file {
            let entryPath = entry.path
            guard isSupportedEntryPath(entryPath) else { continue }

            let target = destination.appendingPathComponent(entryPath)
            // Zip-slip guard: the normalized target must stay inside the
            // expansion directory.
            let normalized = target.standardizedFileURL.path
            guard normalized.hasPrefix(destinationPath + "/") else { continue }

            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            _ = try archive.extract(entry, to: target)
            extracted.append((entryPath, target))
        }

        return extracted
            .sorted { $0.entryPath < $1.entryPath }
            .map { $0.url }
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
