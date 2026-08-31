//
//  ZipExtraction.swift
//  LDACore
//
//  The metered zip extraction shared by every archive reader in the app.
//
//  The rule this file exists to keep in ONE place: the uncompressed-size budget
//  is charged for bytes ACTUALLY inflated, never for the size the archive
//  declares. ZIPFoundation inflates to end-of-stream without consulting the
//  declared size, so a bomb can declare one byte and expand to gigabytes; the
//  only place it can be stopped is mid-stream, inside the consumer closure.
//  ZipImporter learned this the hard way, and the workspace reader must not
//  learn it again separately.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import ZIPFoundation

/// Metered extraction of single zip entries against a shared byte budget.
enum ZipExtraction {

    /// Extract one entry to `target`, charging the budget for each inflated
    /// chunk and aborting the moment the budget runs out.
    ///
    /// - Returns: the budget left after the entry.
    /// - Throws: DocumentIOError.tooLarge when the budget is exhausted, or the
    ///   underlying write error.
    static func extractMetered(
        _ entry: Entry,
        from archive: Archive,
        to target: URL,
        remainingBudget: UInt64,
        budgetMessage: String
    ) throws -> UInt64 {
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
            throw DocumentIOError.unreadable(
                "Could not create \(target.lastPathComponent) in the expansion directory."
            )
        }
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }

        var budget = remainingBudget
        _ = try archive.extract(entry) { chunk in
            budget = try charge(chunk.count, against: budget, message: budgetMessage)
            try handle.write(contentsOf: chunk)
        }
        return budget
    }

    /// Extract one entry into memory under the same budget.
    ///
    /// Used for the small JSON members of a workspace archive. They stay in
    /// memory on purpose: the session mapping is the re-identification key, and
    /// unpacking it as plaintext JSON into a temporary directory would put on
    /// disk exactly what MappingStore exists to keep off it.
    static func extractMeteredData(
        _ entry: Entry,
        from archive: Archive,
        remainingBudget: UInt64,
        budgetMessage: String
    ) throws -> (data: Data, remainingBudget: UInt64) {
        var budget = remainingBudget
        var collected = Data()
        _ = try archive.extract(entry) { chunk in
            budget = try charge(chunk.count, against: budget, message: budgetMessage)
            collected.append(chunk)
        }
        return (collected, budget)
    }

    /// Charge `produced` bytes against `budget`, or throw when it does not fit.
    /// UInt64 throughout: a crafted ZIP64 entry can declare a size above
    /// Int.max, and a non-truncating Int conversion of that value would trap
    /// before any guard could run.
    private static func charge(
        _ produced: Int,
        against budget: UInt64,
        message: String
    ) throws -> UInt64 {
        let amount = UInt64(produced)
        guard amount <= budget else {
            throw DocumentIOError.tooLarge(message)
        }
        return budget - amount
    }
}
