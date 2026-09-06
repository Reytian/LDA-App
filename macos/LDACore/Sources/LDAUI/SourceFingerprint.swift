//
//  SourceFingerprint.swift
//  LDAUI
//
//  The review is of the text that was imported. The DOCX and image exports,
//  however, rebuild their deliverable from the FILE: the redactor rewrites the
//  original package around the reviewed spans, and the image export re-reads
//  the picture to box the values. Nothing stops the user editing that file in
//  Word between the scan and the export, and when they do, whatever they added
//  is copied into the "redacted" document without ever having been reviewed,
//  and every earlier edit shifts the offsets the redaction is applied at.
//
//  So the file is fingerprinted when it is imported, and the fingerprint is
//  checked again immediately before an export reads it. A mismatch refuses the
//  export with a reason the banner renders, and the only remedy is to open the
//  file again, because a re-scan alone would still be scanning the OLD text.
//
//  Why a fingerprint rather than keeping the imported bytes: the tray holds
//  every document of a sitting for hours, a DOCX with scans or a PDF can run to
//  tens of megabytes, and the workspace already keeps a durable copy of the
//  original bytes for anyone who needs them later. What remains is the gap
//  between this check and the redactor's own read, a few milliseconds against
//  the minutes-long window the finding is about; closing it fully would mean
//  teaching every reader in LDACore to work from bytes, which is a wider
//  change than this refusal.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import CryptoKit
import Foundation
import LDACore

/// SHA-256 of a source file's bytes, taken when the file was imported.
struct SourceFingerprint: Equatable, Sendable {

    /// Lowercase hex digest of the whole file.
    let sha256Hex: String

    /// The file's size when fingerprinted, for the diagnostic and as a cheap
    /// first comparison.
    let byteCount: Int

    /// Read the file and fingerprint it. Mapped where the system allows, so a
    /// large document is hashed without a second full copy in memory.
    static func of(_ url: URL) throws -> SourceFingerprint {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SourceFingerprint(
            sha256Hex: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            byteCount: data.count
        )
    }

    /// Re-read the file and throw when it no longer matches `expected`.
    static func verify(_ url: URL, matches expected: SourceFingerprint) throws {
        guard try of(url) == expected else {
            throw SourceChangedSinceScanError()
        }
    }
}

/// Thrown by an export when the file on disk is no longer the file that was
/// scanned. Its description is the same sentence the standing Save Redacted
/// gate renders for the condition, so the one-line outcome and the banner
/// agree.
public struct SourceChangedSinceScanError: LocalizedError, Equatable {
    public init() {}
    public var errorDescription: String? {
        SaveAvailabilityPresentation.sentence(for: .sourceChangedSinceScan)
    }
}

extension ReviewModel {

    /// True for the source kinds whose export reads the FILE rather than only
    /// the reviewed text: a DOCX (the redactor rewrites the original package)
    /// and a standalone image (the PNG is boxed over a re-read of the
    /// picture). A .txt or .pdf export is written from the reviewed text
    /// alone, so a changed file cannot contribute to it and is not checked.
    nonisolated static func exportReadsSource(_ source: URL) -> Bool {
        let ext = source.pathExtension.lowercased()
        return ext == "docx" || ImageTextExtractor.shouldTreatAsImage(source, extension: ext)
    }
}
