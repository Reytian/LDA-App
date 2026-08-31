//
//  FolderImporterTests.swift
//  LDACoreTests
//
//  Directory batch import discovery and budgets (F3). Discovery must find
//  exactly the supported document set in deterministic sorted-path order,
//  skipping hidden entries, package internals, symlinks, and archives; the
//  batch budgets must reject an oversize folder selection as a whole, with an
//  error naming the budget and the offending measure, while pure file
//  selections keep today's unbudgeted behavior.
//
//  Archives are not discovered inside a folder (see FolderImporter.
//  supportedExtensions and NestedArchiveBudgetTests): the batch budgets count
//  bytes on disk, which a high-ratio archive makes meaningless, and the file
//  count budget would stop bounding the tray. A directly chosen .zip still
//  expands, metered by the import's ArchiveBudget.
//
//  The oversize byte fixtures are sparse files, so the 500 MB ceiling is
//  exercised without writing 500 MB.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class FolderImporterTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderImporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        // Note: the temp root is spelled /var (a symlink to /private/var).
        // FolderImporter preserves the caller's spelling, which is exactly
        // what these strict URL equalities pin.
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    /// Create a small file at a relative path under the given root, creating
    /// intermediate directories.
    @discardableResult
    private func makeFile(_ relativePath: String, under root: URL) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fixture".utf8).write(to: url)
        return url
    }

    /// Create a sparse file reporting the given logical size while occupying
    /// almost no disk (the ImportLimitsTests pattern).
    private func makeSparseFile(_ relativePath: String, under root: URL, bytes: Int) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(bytes))
    }

    private func relativePaths(_ urls: [URL], under root: URL) -> [String] {
        let prefix = root.path + "/"
        return urls.map { $0.path.replacingOccurrences(of: prefix, with: "") }
    }

    // MARK: - Discovery

    func testDiscoveryFindsExactlyTheSupportedSetInSortedPathOrder() throws {
        let root = workDir.appendingPathComponent("case-folder", isDirectory: true)
        // Supported documents, including a nested one and an uppercase
        // extension.
        try makeFile("b.txt", under: root)
        try makeFile("A/nested.pdf", under: root)
        try makeFile("z.docx", under: root)
        try makeFile("photo.JPG", under: root)
        try makeFile("scan.jpeg", under: root)
        // Unsupported types. An archive is deliberately among them: a folder
        // import must not open a container the user never chose.
        try makeFile("bundle.zip", under: root)
        try makeFile("notes.md", under: root)
        try makeFile("data.rtf", under: root)
        // Hidden file and hidden directory.
        try makeFile(".hidden.txt", under: root)
        try makeFile(".secrets/inside.txt", under: root)
        // Package contents must stay opaque.
        try makeFile("Fake.app/Contents/doc.txt", under: root)
        // Symlinks are never followed: one to a supported file, one cycle.
        let realDoc = root.appendingPathComponent("b.txt")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.txt"),
            withDestinationURL: realDoc
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("loop"),
            withDestinationURL: root
        )

        let discovered = try FolderImporter.discoverDocuments(in: root)

        XCTAssertEqual(
            relativePaths(discovered, under: root),
            ["A/nested.pdf", "b.txt", "photo.JPG", "scan.jpeg", "z.docx"],
            "discovery must return exactly the supported set, sorted by path"
        )
    }

    func testDiscoveryOrderIsReproducible() throws {
        let root = workDir.appendingPathComponent("order-folder", isDirectory: true)
        for name in ["c.txt", "a.txt", "B/d.pdf", "b.docx"] {
            try makeFile(name, under: root)
        }
        let first = try FolderImporter.discoverDocuments(in: root)
        let second = try FolderImporter.discoverDocuments(in: root)
        XCTAssertEqual(first, second)
        XCTAssertEqual(
            relativePaths(first, under: root),
            ["B/d.pdf", "a.txt", "b.docx", "c.txt"]
        )
    }

    // MARK: - Budgets

    func testFolderWithTooManyFilesIsRejectedAsAWholeBatch() throws {
        let root = workDir.appendingPathComponent("crowded", isDirectory: true)
        for index in 0...(FolderImporter.maxBatchFileCount) {
            try makeFile(String(format: "doc-%03d.txt", index), under: root)
        }

        XCTAssertThrowsError(try FolderImporter.expandSelection([root])) { error in
            guard case DocumentIOError.tooLarge(let message) = error else {
                return XCTFail("expected tooLarge, got \(error)")
            }
            XCTAssertEqual(
                message,
                "Folder contains \(FolderImporter.maxBatchFileCount + 1) supported files; "
                    + "the import limit is \(FolderImporter.maxBatchFileCount)."
            )
        }
    }

    func testFolderWithTooManyBytesIsRejectedAsAWholeBatch() throws {
        let root = workDir.appendingPathComponent("heavy", isDirectory: true)
        try makeSparseFile("one.pdf", under: root, bytes: 300 * 1024 * 1024)
        try makeSparseFile("two.pdf", under: root, bytes: 300 * 1024 * 1024)

        XCTAssertThrowsError(try FolderImporter.expandSelection([root])) { error in
            guard case DocumentIOError.tooLarge(let message) = error else {
                return XCTFail("expected tooLarge, got \(error)")
            }
            XCTAssertEqual(
                message,
                "Folder contains 600 MB of documents; the import limit is 500 MB."
            )
        }
    }

    func testMixedSelectionBudgetsTheWholeResolvedBatch() throws {
        let root = workDir.appendingPathComponent("mixed", isDirectory: true)
        for index in 0..<(FolderImporter.maxBatchFileCount - 1) {
            try makeFile(String(format: "doc-%03d.txt", index), under: root)
        }
        let looseA = try makeFile("loose-a.txt", under: workDir)
        let looseB = try makeFile("loose-b.txt", under: workDir)

        XCTAssertThrowsError(
            try FolderImporter.expandSelection([looseA, root, looseB])
        ) { error in
            guard case DocumentIOError.tooLarge(let message) = error else {
                return XCTFail("expected tooLarge, got \(error)")
            }
            XCTAssertTrue(
                message.contains("\(FolderImporter.maxBatchFileCount + 1) supported files"),
                "the count must measure the whole resolved batch: \(message)"
            )
        }
    }

    func testMixedSelectionWithinBudgetKeepsLooseFilesAndDiscoversTheFolder() throws {
        let root = workDir.appendingPathComponent("small", isDirectory: true)
        try makeFile("inside.pdf", under: root)
        let loose = try makeFile("loose.txt", under: workDir)
        let zip = try makeFile("chosen.zip", under: workDir)

        let resolved = try FolderImporter.expandSelection([loose, root, zip])

        XCTAssertEqual(
            resolved,
            [loose, root.appendingPathComponent("inside.pdf"), zip],
            "loose files pass through in place; the folder expands where it was chosen"
        )
    }

    func testPureFileSelectionIsNotBudgeted() throws {
        var files: [URL] = []
        for index in 0...(FolderImporter.maxBatchFileCount) {
            files.append(try makeFile(String(format: "loose-%03d.txt", index), under: workDir))
        }

        let resolved = try FolderImporter.expandSelection(files)

        XCTAssertEqual(
            resolved,
            files,
            "a selection with no folder keeps today's unbudgeted multi-file behavior"
        )
    }
}
