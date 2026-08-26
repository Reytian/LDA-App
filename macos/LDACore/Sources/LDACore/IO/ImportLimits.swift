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
//  the service facade. ZipImporter enforces the archive ceilings itself, using
//  each entry's DECLARED uncompressed size, which is what makes the check
//  effective against a bomb: the budget is spent before anything is written.
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

    /// Largest total UNCOMPRESSED payload accepted from one archive (500 MB).
    public static let maxArchiveUncompressedBytes: Int = 500 * 1024 * 1024

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
