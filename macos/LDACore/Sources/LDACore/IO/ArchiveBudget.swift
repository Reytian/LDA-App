//
//  ArchiveBudget.swift
//  LDACore
//
//  The inflation allowance for ONE user-initiated import, spent once.
//
//  Why this type exists. The allowance used to be a local variable minted
//  inside each expansion call, which meant it did not compound: two archives
//  in one import each got the whole 500 MB, and an archive nested inside
//  something already being expanded got a second full allowance behind a
//  single user gesture. A folder of two hundred tiny high-ratio archives, or a
//  workspace file carrying them, therefore passed every ceiling on the way in
//  and expanded to hundreds of gigabytes in /var/folders.
//
//  A ledger is a reference type on purpose: it is created once at the import
//  entry point (the tray add, the CLI input resolution, the workspace open)
//  and handed down through every layer that inflates bytes, so nesting SPENDS
//  the same allowance instead of minting a new one.
//
//  What it does NOT do: it never charges a declared size. ZIPFoundation
//  inflates to end-of-stream without consulting the central directory, so the
//  declared size is attacker controlled; charge() is called with bytes the
//  inflater ACTUALLY produced. See ZipExtraction.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// A single import's inflation allowance, spent across every archive it
/// touches however deeply they nest.
///
/// Lock guarded and therefore safe to hand to more than one extraction at a
/// time, though today every import spends it sequentially.
public final class ArchiveBudget: @unchecked Sendable {

    /// The allowance this ledger started with, kept for error messages.
    public let totalBytes: Int

    private let lock = NSLock()

    /// Bytes still available. UInt64 throughout: a crafted ZIP64 entry can
    /// declare a size above Int.max, and a non-truncating Int conversion of
    /// that value would trap before any guard could run.
    private var remaining: UInt64

    /// A ledger for one import, starting at the archive ceiling in force.
    ///
    /// The default reads ImportLimits at CREATION time, which is what makes
    /// the debug budget seam usable: a test installs a small ceiling and the
    /// next import picks it up.
    public convenience init() {
        self.init(totalBytes: ImportLimits.effectiveArchiveUncompressedBytes)
    }

    /// A ledger with an explicit ceiling. Negative or zero ceilings are
    /// clamped to zero so the arithmetic below stays in UInt64.
    public init(totalBytes: Int) {
        self.totalBytes = max(0, totalBytes)
        self.remaining = UInt64(max(0, totalBytes))
    }

    /// Bytes this import may still inflate.
    public var remainingBytes: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return remaining
    }

    /// Bytes this import has already inflated.
    public var spentBytes: UInt64 {
        UInt64(totalBytes) - remainingBytes
    }

    /// True when a DECLARED size already cannot fit.
    ///
    /// A fast pre-check only, so an honestly-labeled oversize archive fails
    /// before any I/O. It is never the defense: a bomb declares one byte.
    public func cannotFit(declared: UInt64) -> Bool {
        declared > remainingBytes
    }

    /// Charge `produced` inflated bytes to this import.
    ///
    /// - Throws: DocumentIOError.tooLarge carrying `message` when the bytes do
    ///   not fit. The ledger is left untouched in that case, so a caller that
    ///   reports and stops sees the same remaining figure the breach saw.
    public func charge(_ produced: Int, message: String) throws {
        let amount = UInt64(max(0, produced))
        lock.lock()
        guard amount <= remaining else {
            lock.unlock()
            throw DocumentIOError.tooLarge(message)
        }
        remaining -= amount
        lock.unlock()
    }

    /// The refusal message for one named source, phrased so a lawyer reads a
    /// limit on the IMPORT rather than on that one file: with a shared ledger
    /// the file that trips the budget is often not the large one.
    public func refusalMessage(for source: String) -> String {
        "\(source) would take this import past its "
            + "\(ImportLimits.describe(bytes: totalBytes)) unpacking limit."
    }
}
