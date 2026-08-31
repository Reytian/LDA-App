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
//  The second rule, learned later: the budget is a LEDGER handed in by the
//  caller, never minted here. One user-initiated import spends one allowance,
//  so nesting an archive inside an archive cannot multiply it. See
//  ArchiveBudget.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import ZIPFoundation

/// Metered extraction of single zip entries against one import's ledger.
enum ZipExtraction {

    /// Extract one entry to `target`, charging the import's ledger for each
    /// inflated chunk and aborting the moment the allowance runs out.
    ///
    /// - Throws: DocumentIOError.tooLarge when the budget is exhausted, or the
    ///   underlying write error.
    static func extractMetered(
        _ entry: Entry,
        from archive: Archive,
        to target: URL,
        budget: ArchiveBudget,
        budgetMessage: String
    ) throws {
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
            throw DocumentIOError.unreadable(
                "Could not create \(target.lastPathComponent) in the expansion directory."
            )
        }
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }

        _ = try archive.extract(entry) { chunk in
            try budget.charge(chunk.count, message: budgetMessage)
            try handle.write(contentsOf: chunk)
        }
    }

    /// Extract one entry into memory under the same ledger.
    ///
    /// Used for the small JSON members of a workspace archive. They stay in
    /// memory on purpose: the session mapping is the re-identification key, and
    /// unpacking it as plaintext JSON into a temporary directory would put on
    /// disk exactly what MappingStore exists to keep off it.
    static func extractMeteredData(
        _ entry: Entry,
        from archive: Archive,
        budget: ArchiveBudget,
        budgetMessage: String
    ) throws -> Data {
        var collected = Data()
        _ = try archive.extract(entry) { chunk in
            try budget.charge(chunk.count, message: budgetMessage)
            collected.append(chunk)
        }
        return collected
    }
}
