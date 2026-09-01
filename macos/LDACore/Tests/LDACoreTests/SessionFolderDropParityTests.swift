//
//  SessionFolderDropParityTests.swift
//  LDACoreTests
//
//  Folder selection must have the same behavior whether it comes from the
//  Open panel or from a drop. SessionModel is the shared boundary, so it owns
//  folder discovery, whole-batch budgets, and direct archive expansion.
//
//  House rules: English only. No em-dash and no en-dash-as-separator.
//

import XCTest
import ZIPFoundation
@testable import LDACore
@testable import LDAUI

@MainActor
final class SessionFolderDropParityTests: XCTestCase {

    private var workDir: URL!
    private var inheritedExpansions: Set<URL> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SessionFolderDropParityTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        inheritedExpansions = ZipImporter.registeredExpansions()
    }

    override func tearDownWithError() throws {
        ZipImporter.cleanUpExpansions(
            ZipImporter.registeredExpansions().subtracting(inheritedExpansions)
        )
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    private func makeSession() -> SessionModel {
        SessionModel(makeModel: {
            let model = ReviewModel(modelPath: nil)
            model.useLLM = false
            return model
        })
    }

    @discardableResult
    private func write(_ relativePath: String, under root: URL, text: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
        return url
    }

    private func makeZip(_ name: String, members: [String: String]) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        let archive = try Archive(url: url, accessMode: .create)
        for (path, text) in members.sorted(by: { $0.key < $1.key }) {
            let bytes = Data(text.utf8)
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(bytes.count),
                provider: { position, size in
                    let start = Int(position)
                    return bytes.subdata(in: start ..< min(start + size, bytes.count))
                }
            )
        }
        return url
    }

    func testAddDocumentsExpandsFolderAndDirectZipButIgnoresZipNestedInFolder() async throws {
        let folder = workDir.appendingPathComponent("dropped-folder", isDirectory: true)
        try write("b.txt", under: folder, text: "Folder B")
        try write("A/a.txt", under: folder, text: "Folder A")

        let nestedZip = folder.appendingPathComponent("nested.zip")
        let nestedArchive = try Archive(url: nestedZip, accessMode: .create)
        let hiddenByFolderRule = Data("Nested archive document".utf8)
        try nestedArchive.addEntry(
            with: "must-not-open.txt",
            type: .file,
            uncompressedSize: Int64(hiddenByFolderRule.count),
            provider: { position, size in
                let start = Int(position)
                return hiddenByFolderRule.subdata(
                    in: start ..< min(start + size, hiddenByFolderRule.count)
                )
            }
        )

        let directZip = try makeZip(
            "direct.zip",
            members: ["chosen-directly.txt": "Direct archive document"]
        )
        let session = makeSession()

        await session.addDocuments([folder, directZip])

        XCTAssertNil(session.importFailure)
        XCTAssertEqual(
            session.entries.map(\.name),
            ["a.txt", "b.txt", "chosen-directly.txt"],
            "folder documents keep deterministic order and only a directly selected zip expands"
        )
        XCTAssertEqual(
            session.entries.map { $0.model.documentText },
            ["Folder A", "Folder B", "Direct archive document"]
        )
        XCTAssertFalse(session.entries.contains { $0.name == "must-not-open.txt" })
    }

    func testFolderBudgetFailureSurfacesAndAddsNothingFromTheWholeSelection() async throws {
        let loose = try write("loose.txt", under: workDir, text: "Loose document")
        let folder = workDir.appendingPathComponent("too-many", isDirectory: true)
        for index in 0...FolderImporter.maxBatchFileCount {
            try write(
                String(format: "document-%03d.txt", index),
                under: folder,
                text: "fixture"
            )
        }
        let session = makeSession()
        var opened: [URL] = []
        session.openDocument = { model, url in
            opened.append(url)
            await model.open(url)
        }

        await session.addDocuments([loose, folder])

        XCTAssertTrue(session.entries.isEmpty, "a refused folder batch must not partially fill the tray")
        XCTAssertTrue(opened.isEmpty, "the whole batch must resolve before any document is opened")
        let failure = try XCTUnwrap(session.importFailure)
        XCTAssertTrue(failure.contains("202 supported files"), failure)
        XCTAssertTrue(failure.contains("limit is 200"), failure)
    }
}
