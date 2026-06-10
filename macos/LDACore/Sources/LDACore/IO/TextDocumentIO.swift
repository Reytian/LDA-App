//
//  TextDocumentIO.swift
//  LDACore
//
//  Plain-text DocumentImporter plus the redacted .txt edit-surface writer.
//
//  Import path: reads .txt/.text/.md files as UTF-8, falling back to a small set
//  of common encodings, and returns an ImportedDocument whose text uses the same
//  UTF-16 offset convention as the engine Spans. The redacted .txt produced for
//  plain-text inputs is the round-trip edit surface.
//
//  Offset convention: ImportedDocument.text uses UTF-16 code-unit offsets, the
//  NSRange-compatible convention shared with Span in CoreTypes.swift.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

// MARK: - TextDocumentIO

/// A DocumentImporter for plain-text formats (.txt, .text, .md). It reads the
/// file as UTF-8 when possible, falls back to other common encodings, and throws
/// DocumentIOError.unreadable when no encoding succeeds.
public struct TextDocumentIO: DocumentImporter, Sendable {
    /// The file extensions this importer recognizes. Lowercased, without a dot.
    public static let supportedExtensions: Set<String> = ["txt", "text", "md"]

    /// Encodings tried in order when UTF-8 decoding fails. UTF-8 is attempted
    /// first because it is the dominant on-disk encoding for these formats.
    /// isoLatin1 comes before utf16 so that single odd-length bytes (e.g. 0xE9
    /// alone) are decoded as Latin-1 rather than misinterpreted as UTF-16 big-endian.
    private static let fallbackEncodings: [String.Encoding] = [
        .utf8,
        .isoLatin1,
        .windowsCP1252,
        .utf16,
        .ascii
    ]

    public init() {}

    // MARK: DocumentImporter

    /// Returns true when the file extension is one of the supported plain-text
    /// extensions. The comparison is case-insensitive.
    public func canImport(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return TextDocumentIO.supportedExtensions.contains(ext)
    }

    /// Imports a plain-text file. Reads the raw bytes once, then decodes them by
    /// trying UTF-8 first and a small set of fallback encodings after. Throws
    /// DocumentIOError.unreadable when the file cannot be read or decoded.
    public func importDocument(_ url: URL) throws -> ImportedDocument {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DocumentIOError.unreadable(
                "Could not read file at \(url.path): \(error.localizedDescription)"
            )
        }

        guard let text = TextDocumentIO.decode(data) else {
            throw DocumentIOError.unreadable(
                "Could not decode file at \(url.path) with any known text encoding."
            )
        }

        return ImportedDocument(
            text: TextDocumentIO.normalize(text),
            format: .plainText,
            isScanned: false,
            pageCount: 1
        )
    }

    /// Deliberate import normalization: strip a leading UTF-8 BOM (it would
    /// shift every detection offset by one UTF-16 unit and leak U+FEFF into
    /// the restored output) and normalize CRLF and bare CR line endings to LF
    /// (a CR surviving into the companion .docx breaks the Word edit surface).
    /// The restored output is therefore LF-normalized by design.
    static func normalize(_ text: String) -> String {
        var out = text
        if out.hasPrefix("\u{FEFF}") {
            out = String(out.dropFirst())
        }
        if out.contains("\r") {
            out = out.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
        }
        return out
    }

    // MARK: Export

    /// Writes plain text to the given URL as UTF-8. Used to write the redacted
    /// .txt edit surface and the restored output. Throws
    /// DocumentIOError.unreadable when the bytes cannot be produced or written.
    public static func exportText(_ text: String, to url: URL) throws {
        guard let data = text.data(using: .utf8) else {
            throw DocumentIOError.unreadable(
                "Could not encode text as UTF-8 for \(url.path)."
            )
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw DocumentIOError.unreadable(
                "Could not write text to \(url.path): \(error.localizedDescription)"
            )
        }
    }

    // MARK: Decoding

    /// Attempts to decode raw bytes using the fallback encodings in order.
    /// Returns nil only when every encoding fails.
    private static func decode(_ data: Data) -> String? {
        for encoding in fallbackEncodings {
            if let text = String(data: data, encoding: encoding) {
                return text
            }
        }
        return nil
    }
}
