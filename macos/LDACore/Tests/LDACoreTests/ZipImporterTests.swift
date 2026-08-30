//
//  ZipImporterTests.swift
//  LDACoreTests
//
//  Tests for .zip session import (R19): a dropped archive expands into the
//  session's documents. Junk entries (__MACOSX, dotfiles), unsupported types,
//  and path-traversal entries are skipped.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import ZIPFoundation
@testable import LDACore

final class ZipImporterTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZipImporterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Expansions are process-wide until a host clears them; never leak one
        // into another suite. Same for the budget override.
        ZipImporter.cleanUpAllExpansions()
        ImportLimits.archiveBudgetSeam.clear()
        try? FileManager.default.removeItem(at: workDir)
    }

    /// Build a zip whose single entry DECLARES a huge uncompressed size while
    /// carrying almost no bytes. This is the shape of a zip bomb, and the shape
    /// the entry-size budget is meant to reject before anything is written.
    private func makeOverDeclaredZip(declaredBytes: Int64) throws -> URL {
        let zipURL = workDir.appendingPathComponent("bomb.zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        let data = Data(repeating: 0x41, count: 1024)
        try archive.addEntry(
            with: "payload.txt",
            type: .file,
            uncompressedSize: declaredBytes,
            provider: { position, size in
                _ = position
                return Data(repeating: 0x41, count: min(size, data.count))
            }
        )
        return zipURL
    }

    /// Build a zip at workDir/archive.zip containing the given entries.
    private func makeZip(entries: [(path: String, content: String)]) throws -> URL {
        let zipURL = workDir.appendingPathComponent("archive.zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        for entry in entries {
            let data = Data(entry.content.utf8)
            try archive.addEntry(
                with: entry.path,
                type: .file,
                uncompressedSize: Int64(data.count),
                provider: { position, size in
                    data.subdata(in: Int(position)..<Int(position) + size)
                }
            )
        }
        return zipURL
    }

    func testExpandReturnsSupportedDocuments() throws {
        let zipURL = try makeZip(entries: [
            ("contract.txt", "Acme Corp agrees."),
            ("notes.md", "# Notes"),
            ("nested/intake.txt", "John Smith intake.")
        ])

        let urls = try ZipImporter.expand(zipURL).documents

        XCTAssertEqual(urls.count, 3)
        let names = Set(urls.map { $0.lastPathComponent })
        XCTAssertEqual(names, ["contract.txt", "notes.md", "intake.txt"])
        let contract = urls.first { $0.lastPathComponent == "contract.txt" }!
        XCTAssertEqual(try String(contentsOf: contract, encoding: .utf8), "Acme Corp agrees.")
    }

    func testExpandSkipsJunkAndUnsupportedEntries() throws {
        let zipURL = try makeZip(entries: [
            ("real.txt", "keep me"),
            ("__MACOSX/real.txt", "resource fork junk"),
            (".DS_Store", "finder junk"),
            ("photo.png", "not a document"),
            ("nested/.hidden.txt", "hidden")
        ])

        let urls = try ZipImporter.expand(zipURL).documents

        XCTAssertEqual(urls.map { $0.lastPathComponent }, ["real.txt"])
    }

    func testExpandSkipsPathTraversalEntries() throws {
        let zipURL = try makeZip(entries: [
            ("../evil.txt", "escape attempt"),
            ("good.txt", "safe")
        ])

        let urls = try ZipImporter.expand(zipURL).documents

        XCTAssertEqual(urls.map { $0.lastPathComponent }, ["good.txt"])
        // Nothing may have been written outside the expansion directory.
        let escaped = workDir.deletingLastPathComponent().appendingPathComponent("evil.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.path))
    }

    func testExpandRejectsNonZip() throws {
        let notZip = workDir.appendingPathComponent("plain.zip")
        try Data("this is not an archive".utf8).write(to: notZip)
        XCTAssertThrowsError(try ZipImporter.expand(notZip))
    }

    func testIsZipByExtension() {
        XCTAssertTrue(ZipImporter.isZip(URL(fileURLWithPath: "/tmp/a.zip")))
        XCTAssertTrue(ZipImporter.isZip(URL(fileURLWithPath: "/tmp/a.ZIP")))
        XCTAssertFalse(ZipImporter.isZip(URL(fileURLWithPath: "/tmp/a.docx")))
    }

    // MARK: - Temp-directory cleanup

    func testExpansionIsRegisteredUntilCleanedUp() throws {
        // Delta-based, not absolute: the registry is process-wide, so an
        // absolute count would break the moment any other suite holds a live
        // expansion when this one runs.
        let zipURL = try makeZip(entries: [("contract.txt", "Acme Corp agrees.")])
        let before = ZipImporter.liveExpansionCount

        let expansion = try ZipImporter.expand(zipURL)

        XCTAssertEqual(
            ZipImporter.liveExpansionCount, before + 1,
            "an expansion must be tracked so a host can clear it at a session boundary"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: expansion.directory.path))
    }

    func testCleanUpRemovesTheExtractedOriginals() throws {
        let zipURL = try makeZip(entries: [("contract.txt", "Acme Corp agrees.")])
        let expansion = try ZipImporter.expand(zipURL)
        let document = try XCTUnwrap(expansion.documents.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: document.path))

        XCTAssertTrue(expansion.cleanUp())

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: document.path),
            "the user's un-redacted original must not survive the session in temp"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: expansion.directory.path))
        XCTAssertEqual(ZipImporter.liveExpansionCount, 0)
    }

    func testCleanUpIsIdempotent() throws {
        let zipURL = try makeZip(entries: [("contract.txt", "x")])
        let expansion = try ZipImporter.expand(zipURL)
        XCTAssertTrue(expansion.cleanUp())
        XCTAssertTrue(expansion.cleanUp(), "a second cleanUp is a no-op, not a failure")
    }

    func testCleanUpAllExpansionsClearsEveryArchive() throws {
        let first = try makeZip(entries: [("a.txt", "one")])
        let expansionA = try ZipImporter.expand(first)
        // A second archive at a different path so both expansions coexist.
        let secondPath = workDir.appendingPathComponent("second.zip")
        let archive = try Archive(url: secondPath, accessMode: .create)
        let data = Data("two".utf8)
        try archive.addEntry(
            with: "b.txt",
            type: .file,
            uncompressedSize: Int64(data.count),
            provider: { position, size in data.subdata(in: Int(position)..<Int(position) + size) }
        )
        let expansionB = try ZipImporter.expand(secondPath)
        XCTAssertGreaterThanOrEqual(ZipImporter.liveExpansionCount, 2)

        let removed = ZipImporter.cleanUpAllExpansions()

        // At least the two created here; a leaked expansion from an earlier
        // suite would also be swept, which is this API's job, not a failure.
        XCTAssertGreaterThanOrEqual(removed, 2)
        XCTAssertEqual(ZipImporter.liveExpansionCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expansionA.directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: expansionB.directory.path))
    }

    func testARejectedExpansionLeavesNothingBehind() throws {
        let zipURL = try makeOverDeclaredZip(
            declaredBytes: Int64(ImportLimits.maxArchiveUncompressedBytes) + 1
        )

        XCTAssertThrowsError(try ZipImporter.expand(zipURL))

        XCTAssertEqual(
            ZipImporter.liveExpansionCount, 0,
            "a rejected archive must not leave a partially written expansion registered"
        )
    }

    // MARK: - Archive ceilings

    func testArchiveExceedingTheUncompressedBudgetIsRejected() throws {
        let zipURL = try makeOverDeclaredZip(
            declaredBytes: Int64(ImportLimits.maxArchiveUncompressedBytes) + 1
        )

        XCTAssertThrowsError(try ZipImporter.expand(zipURL)) { error in
            guard case DocumentIOError.tooLarge = error else {
                XCTFail("Expected tooLarge for an over-declared archive, got \(error)")
                return
            }
        }
    }

    func testArchiveWithinTheBudgetIsAccepted() throws {
        // The budget must not reject an ordinary matter bundle.
        let zipURL = try makeZip(entries: [
            ("engagement.txt", String(repeating: "a", count: 4096)),
            ("intake.md", String(repeating: "b", count: 4096))
        ])
        let expansion = try ZipImporter.expand(zipURL)
        XCTAssertEqual(expansion.documents.count, 2)
    }

    // MARK: - Lying declared sizes (the real zip-bomb shape)

    /// Build a zip whose entry REALLY inflates to `actualBytes` but whose
    /// declared uncompressed size (local file header AND central directory) is
    /// patched down to `declaredBytes`. This is the shape of a genuine zip
    /// bomb: the central directory is attacker-controlled, and the inflater
    /// runs to end-of-stream regardless of what it says.
    private func makeLyingZip(actualBytes: Int, declaredBytes: UInt32) throws -> URL {
        let zipURL = workDir.appendingPathComponent("lying.zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        let payload = Data(repeating: 0x41, count: actualBytes)
        // DEFLATE, not the store default: a stored entry is read by its
        // compressed size, so it cannot lie about its inflated size. Real
        // bombs are deflate streams, whose inflater runs to end-of-stream.
        try archive.addEntry(
            with: "payload.txt",
            type: .file,
            uncompressedSize: Int64(actualBytes),
            compressionMethod: .deflate,
            provider: { position, size in
                payload.subdata(in: Int(position) ..< Int(position) + size)
            }
        )

        var bytes = [UInt8](try Data(contentsOf: zipURL))
        let honest = withUnsafeBytes(of: UInt32(actualBytes).littleEndian) { [UInt8]($0) }
        let lying = withUnsafeBytes(of: declaredBytes.littleEndian) { [UInt8]($0) }

        // Patch every occurrence of the honest 4-byte size. It must appear
        // exactly twice: once in the local file header, once in the central
        // directory. More or fewer means the fixture assumption broke.
        var patched = 0
        var index = 0
        while index <= bytes.count - 4 {
            if Array(bytes[index ..< index + 4]) == honest {
                bytes.replaceSubrange(index ..< index + 4, with: lying)
                patched += 1
                index += 4
            } else {
                index += 1
            }
        }
        XCTAssertEqual(
            patched, 2,
            "expected the size in exactly the local header and the central directory"
        )
        try Data(bytes).write(to: zipURL)
        return zipURL
    }

    func testAnArchiveLyingAboutItsSizeIsStoppedByActualBytes() throws {
        // Arrange: entry declares 1 KB but really inflates to 200 KB; budget
        // is 64 KB. The declared-size pre-check passes (that is the attack),
        // so only actual-bytes metering can stop it.
        ImportLimits.archiveBudgetSeam.value = 64 * 1024
        let zipURL = try makeLyingZip(actualBytes: 200 * 1024, declaredBytes: 1024)
        let liveBefore = ZipImporter.liveExpansionCount

        // Act + Assert
        XCTAssertThrowsError(try ZipImporter.expand(zipURL)) { error in
            guard case DocumentIOError.tooLarge = error else {
                XCTFail("Expected tooLarge from actual-bytes metering, got \(error)")
                return
            }
        }
        // Delta-based: the registry is process-wide, so compare against the
        // count before the attempt rather than absolute zero.
        XCTAssertEqual(
            ZipImporter.liveExpansionCount, liveBefore,
            "the partially inflated bomb must not be left registered on disk"
        )
    }

    func testAnHonestArchiveStillExpandsUnderTheMeteredBudget() throws {
        // The metering must not tax the normal case: real content within the
        // budget expands exactly as before.
        ImportLimits.archiveBudgetSeam.value = 64 * 1024
        let zipURL = try makeZip(entries: [
            ("a.txt", String(repeating: "a", count: 8 * 1024)),
            ("b.txt", String(repeating: "b", count: 8 * 1024))
        ])

        let expansion = try ZipImporter.expand(zipURL)

        XCTAssertEqual(expansion.documents.count, 2)
        let contents = try String(
            contentsOf: expansion.documents[0], encoding: .utf8
        )
        XCTAssertEqual(contents.count, 8 * 1024, "metered extraction must write intact bytes")
    }

    func testAZip64SizedDeclarationDoesNotTrap() throws {
        // A crafted ZIP64 entry can declare a size above Int.max; the budget
        // arithmetic stays in UInt64, so this must REJECT, never trap. The
        // declared size here is the largest the 4-byte field can carry; the
        // UInt64 comparison path is shared with true ZIP64 sizes.
        ImportLimits.archiveBudgetSeam.value = 64 * 1024
        let zipURL = try makeLyingZip(actualBytes: 8 * 1024, declaredBytes: UInt32.max)

        XCTAssertThrowsError(try ZipImporter.expand(zipURL)) { error in
            guard case DocumentIOError.tooLarge = error else {
                XCTFail("Expected tooLarge from the declared-size pre-check, got \(error)")
                return
            }
        }
    }

    func testArchiveWithTooManyEntriesIsRejected() throws {
        let zipURL = workDir.appendingPathComponent("many.zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        let data = Data("x".utf8)
        for index in 0 ... ImportLimits.maxArchiveEntries {
            try archive.addEntry(
                with: "doc\(index).txt",
                type: .file,
                uncompressedSize: Int64(data.count),
                provider: { position, size in data.subdata(in: Int(position)..<Int(position) + size) }
            )
        }

        XCTAssertThrowsError(try ZipImporter.expand(zipURL)) { error in
            guard case DocumentIOError.tooLarge = error else {
                XCTFail("Expected tooLarge for too many entries, got \(error)")
                return
            }
        }
    }
}
