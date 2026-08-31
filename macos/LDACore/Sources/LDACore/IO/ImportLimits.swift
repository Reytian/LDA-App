//
//  ImportLimits.swift
//  LDACore
//
//  Resource ceilings applied at the import boundary, before a file's bytes
//  reach a parser.
//
//  Why: every importer used to read whatever it was handed. A 4 GB "document"
//  or a zip bomb (a small archive that expands to hundreds of gigabytes) would
//  be read into memory until the process was killed, which for a lawyer mid
//  review means losing the open session. The ceilings below are generous
//  against real legal documents and tight against that failure mode.
//
//  Where these are enforced: each concrete DocumentImporter calls
//  enforceDocumentSize(at:) as its first statement, so no import path can
//  bypass the check by calling an importer directly instead of going through
//  the service facade. The archive ceiling is enforced by ArchiveBudget, a
//  ledger the import entry point creates once and every expansion spends: the
//  charge is for bytes ACTUALLY inflated (a declared size is attacker
//  controlled), and one ledger per user gesture is what stops nesting from
//  multiplying the ceiling.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// Ceilings applied to imported files and archives.
public enum ImportLimits {

    /// Largest single document accepted, in bytes (200 MB).
    ///
    /// Calibration: a 500 page scanned PDF at 300 dpi is roughly 50 MB, so this
    /// leaves a wide margin over any real filing while still bounding what one
    /// import can allocate.
    public static let maxDocumentBytes: Int = 200 * 1024 * 1024

    /// Largest total UNCOMPRESSED payload accepted from one IMPORT (500 MB).
    ///
    /// Per import, not per archive: an ArchiveBudget created at the entry point
    /// is spent by every archive that gesture expands, however they nest.
    public static let maxArchiveUncompressedBytes: Int = 500 * 1024 * 1024

#if DEBUG
    /// Debug-only override of the archive budget, so the actual-bytes metering
    /// can be exercised with kilobyte fixtures instead of writing 500 MB in a
    /// unit test. Lock guarded and compiled out of release; see TestSeam.
    static let archiveBudgetSeam = TestSeam<Int>()
#endif

    /// The archive budget in force: the debug override when a test installed
    /// one, otherwise maxArchiveUncompressedBytes. Release builds always return
    /// the constant. Read when an ArchiveBudget is CREATED, so a test installs
    /// the seam before the import it wants to bound.
    static var effectiveArchiveUncompressedBytes: Int {
#if DEBUG
        return archiveBudgetSeam.value ?? maxArchiveUncompressedBytes
#else
        return maxArchiveUncompressedBytes
#endif
    }

    /// Largest number of entries examined in one archive.
    public static let maxArchiveEntries: Int = 1_000

    /// Throw when the file at url is larger than maxDocumentBytes.
    ///
    /// A missing or unreadable size is NOT treated as a failure here: the
    /// importer that follows will produce its own, more specific error for a
    /// file it cannot read. This check speaks only to size.
    public static func enforceDocumentSize(at url: URL) throws {
        guard let size = fileSize(at: url) else { return }
        guard size <= maxDocumentBytes else {
            throw DocumentIOError.tooLarge(
                "\(url.lastPathComponent) is \(describe(bytes: size)); the limit is "
                    + "\(describe(bytes: maxDocumentBytes)) per document."
            )
        }
    }

    /// Byte size of a file, or nil when it cannot be determined.
    public static func fileSize(at url: URL) -> Int? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values?.fileSize { return size }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue
    }

    /// A short human size for an error message a lawyer will read.
    public static func describe(bytes: Int) -> String {
        let megabytes = Double(bytes) / (1024 * 1024)
        if megabytes >= 1024 {
            return String(format: "%.1f GB", megabytes / 1024)
        }
        if megabytes >= 1 {
            return String(format: "%.0f MB", megabytes)
        }
        return "\(bytes) bytes"
    }
}
