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
        try? FileManager.default.removeItem(at: workDir)
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

        let urls = try ZipImporter.expand(zipURL)

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

        let urls = try ZipImporter.expand(zipURL)

        XCTAssertEqual(urls.map { $0.lastPathComponent }, ["real.txt"])
    }

    func testExpandSkipsPathTraversalEntries() throws {
        let zipURL = try makeZip(entries: [
            ("../evil.txt", "escape attempt"),
            ("good.txt", "safe")
        ])

        let urls = try ZipImporter.expand(zipURL)

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
}
