//
//  DefaultWorkspace.swift
//  LDAUI
//
//  Where an export keeps its mapping when the user chose no destination, and
//  how Restore finds it again. Pure naming and location rules, no file system
//  side effects, so both halves are checkable without a window.
//
//  WHY THIS EXISTS. Save Redacted no longer drops a .ldamap next to the
//  document it writes, so the key has to live somewhere the app can find on
//  its own or the user gets a redacted file they can never restore. It lives
//  in a WORKSPACE: the same .ldawork format Save Workspace writes, in an app
//  managed folder, sealed with a key held only in this Mac's Keychain. That
//  form deliberately does not travel; see WorkspaceArchive's header.
//
//  THE NAME, and the two things it has to do at once.
//
//  1. Say which document it belongs to. The name carries the document's own
//     stem, so a user looking in the folder can tell what each file is for.
//     That does put document names in a directory listing. It is the same
//     exposure the user's own Documents folder already carries for the same
//     documents, and the file's CONTENTS stay sealed. What it must never
//     become is the outer name of a file that LEAVES the Mac, which is why
//     WorkspacePresentation.defaultFileName still refuses to name a saved
//     workspace after the matter.
//
//  2. Be unique per document, not per document NAME. Two matters both holding
//     a "contract.docx" are ordinary in this practice, and a name derived from
//     the stem alone would make the second export overwrite the first
//     matter's only key. So the name also carries a digest of the source
//     file's own path: same document means the same name (so repeated exports
//     update one file rather than littering), a different document means a
//     different name (so no export can destroy another document's key).
//
//  FINDING IT AGAIN. Restore has only the file that came back, so it works
//  from that file's name: strip the "_redacted" suffix the export added, then
//  look for workspaces whose name carries that stem. Exactly one match is
//  used automatically. SEVERAL matches are never guessed between: two
//  same-stemmed documents cannot be told apart from the redacted file alone,
//  and restoring one matter's document with another matter's key would put
//  the wrong party's name into it, so Restore asks instead.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import CryptoKit
import LDACore

/// The naming and location rules for the workspace an export keeps its
/// mapping in when the user chose no destination.
enum DefaultWorkspace {

    // MARK: - Shape

    /// The suffix Save Redacted adds to a source stem when naming its output.
    /// Shared with the export so the two sides of the round trip cannot drift:
    /// the export appends it, and `documentStem(forRedactedFileNamed:)` is
    /// exactly its inverse.
    static let redactedSuffix = "_redacted"

    /// Separates the readable stem from the path digest. A character that
    /// cannot appear in the digest and is not added by the export's own
    /// collision suffix, so splitting on the LAST one is unambiguous.
    private static let digestSeparator = "~"

    /// Hex characters of source-path digest in a workspace name. Eight bytes
    /// is far past the point where two of a user's documents collide, and a
    /// collision is the one failure that would let one export overwrite
    /// another document's key.
    private static let digestLength = 16

    // MARK: - Naming

    /// The default workspace file name for the document at `source`.
    ///
    /// A pure function of the source URL, which is what makes "created exactly
    /// once" fall out: exporting the same document again resolves to the same
    /// name and updates that file instead of adding another.
    static func fileName(forSource source: URL) -> String {
        let stem = safeStem(source.deletingPathExtension().lastPathComponent)
        let digest = pathDigest(source)
        return stem + digestSeparator + digest + "." + WorkspaceArchive.fileExtension
    }

    /// The default workspace URL for the document at `source`.
    static func url(forSource source: URL, in directory: URL) -> URL {
        directory.appendingPathComponent(fileName(forSource: source))
    }

    /// The Keychain account a default workspace is sealed under: its own file
    /// name, minus the extension. The same rule sidecars use, so the file
    /// found on disk is the whole key and nothing has to be stored beside it.
    static func keychainAccount(for workspaceURL: URL) -> String {
        workspaceURL.deletingPathExtension().lastPathComponent
    }

    // MARK: - Finding it from a redacted file

    /// The source document stem behind a redacted output's file name, or nil
    /// when the name does not look like one this app wrote.
    ///
    /// The export names its output `<stem>_redacted` and, when that name is
    /// taken in the chosen folder, `<stem>_redacted_2`, `<stem>_redacted_3`
    /// and so on. This undoes both shapes and nothing else: a name that never
    /// went through Save Redacted must resolve to nothing rather than to a
    /// plausible looking guess.
    static func documentStem(forRedactedFileNamed name: String) -> String? {
        let stem = (name as NSString).deletingPathExtension
        if stem.hasSuffix(redactedSuffix) {
            let head = String(stem.dropLast(redactedSuffix.count))
            return head.isEmpty ? nil : head
        }
        // "<stem>_redacted_2": a trailing "_<digits>" over the suffix.
        guard let separator = stem.range(of: "_", options: .backwards) else { return nil }
        let tail = stem[separator.upperBound...]
        guard !tail.isEmpty, tail.allSatisfy(\.isNumber) else { return nil }
        return documentStem(forRedactedFileNamed: String(stem[..<separator.lowerBound]))
    }

    /// Every default workspace in `directory` that carries `stem`.
    ///
    /// Sorted, so a caller that has to report an ambiguity reports it the same
    /// way twice. A missing or unreadable directory yields no candidates
    /// rather than throwing: no workspace found is a normal answer here.
    static func candidates(forDocumentStem stem: String, in directory: URL) -> [URL] {
        let wanted = safeStem(stem) + digestSeparator
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents
            .filter { url in
                url.pathExtension == WorkspaceArchive.fileExtension
                    && url.lastPathComponent.hasPrefix(wanted)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The one default workspace that holds the key for `redactedFile`, or nil
    /// when there is no match or more than one.
    ///
    /// More than one is deliberately nil rather than a choice. See this file's
    /// header: the redacted file's name cannot separate two same-stemmed
    /// documents, and picking either would restore one matter's document with
    /// another matter's names.
    static func unambiguousCandidate(
        forRedactedFileNamed name: String,
        in directory: URL
    ) -> URL? {
        guard let stem = documentStem(forRedactedFileNamed: name) else { return nil }
        let matches = candidates(forDocumentStem: stem, in: directory)
        return matches.count == 1 ? matches.first : nil
    }

    // MARK: - Pieces

    /// A single path component that cannot traverse, hide, or nest, and that
    /// carries no separator of its own.
    private static func safeStem(_ stem: String) -> String {
        let component = (stem as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: digestSeparator, with: "_")
        let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else { return "document" }
        return trimmed.hasPrefix(".") ? "_" + trimmed : trimmed
    }

    /// Hex digest of the source file's standardized path. Identity only; it
    /// protects nothing, so the length is chosen against accidental collision
    /// rather than against an attacker.
    private static func pathDigest(_ source: URL) -> String {
        let path = source.standardizedFileURL.path
        let hash = SHA256.hash(data: Data(path.utf8))
        return hash.map { String(format: "%02x", $0) }
            .joined()
            .prefix(digestLength)
            .lowercased()
    }
}
