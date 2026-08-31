//
//  NestedArchiveBudgetTests.swift
//  LDACoreTests
//
//  The archive budget must COMPOUND across one user-initiated import.
//
//  The defect these tests pin: the budget used to be minted fresh inside every
//  expansion call, so nesting multiplied it. Plain .zip import was protected
//  only by accident (ZipImporter does not extract inner .zip entries), and two
//  later features reopened the hole:
//
//    A. the .ldawork workspace, which unpacked whatever its manifest named,
//       charging only the COMPRESSED size of an inner archive, and
//    B. folder batch import, which discovered .zip files and charged their
//       on-disk size, so a folder of tiny high-ratio archives passed both
//       batch budgets and then expanded without limit.
//
//  Neither entry needs anything from the user beyond opening a folder or a
//  file somebody sent them, so the ledger is the defense, not the user.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import ZIPFoundation
@testable import LDACore
@testable import LDAUI

/// Sizes shared by the fixtures. File scope rather than static members so a
/// default argument can read them: a @MainActor type's statics are isolated,
/// and a default argument is evaluated outside that isolation.
private enum BudgetFixture {

    /// The shared allowance every test in this file runs under. Small enough
    /// that kilobyte fixtures exercise the real metering path; see
    /// ImportLimits.archiveBudgetSeam.
    static let budgetBytes = 64 * 1024

    /// What one fixture archive inflates to. Deliberately below the budget so
    /// that ONE of them is legitimate and only the compounding total is not:
    /// that is what separates a per-call budget from a ledger.
    static let bombInflatedBytes = 40 * 1024
}

@MainActor
final class NestedArchiveBudgetTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        assertNoTestSeamsInstalled()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NestedArchiveBudget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        ZipImporter.cleanUpAllExpansions()
        ImportLimits.archiveBudgetSeam.clear()
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// A high-ratio archive: a few hundred bytes on disk that inflate to
    /// `inflatedBytes`. Honest declared size, real deflate stream. This is the
    /// shape a client folder can carry without looking suspicious.
    @discardableResult
    private func makeHighRatioZip(
        named name: String,
        under root: URL? = nil,
        inflatedBytes: Int = BudgetFixture.bombInflatedBytes
    ) throws -> URL {
        let directory = root ?? workDir!
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let zipURL = directory.appendingPathComponent(name)
        let archive = try Archive(url: zipURL, accessMode: .create)
        let payload = Data(repeating: 0x41, count: inflatedBytes)
        try archive.addEntry(
            with: "payload.txt",
            type: .file,
            uncompressedSize: Int64(inflatedBytes),
            compressionMethod: .deflate,
            provider: { position, size in
                payload.subdata(in: Int(position) ..< Int(position) + size)
            }
        )
        return zipURL
    }

    /// A high-ratio archive that also LIES: its declared uncompressed size is
    /// patched down to `declaredBytes` while the deflate stream still inflates
    /// to `inflatedBytes`. Only actual-bytes metering can stop this shape, so
    /// it proves the shared ledger did not quietly regress to declared sizes.
    private func makeLyingZip(
        named name: String,
        inflatedBytes: Int,
        declaredBytes: UInt32
    ) throws -> URL {
        let zipURL = workDir.appendingPathComponent(name)
        let archive = try Archive(url: zipURL, accessMode: .create)
        let payload = Data(repeating: 0x42, count: inflatedBytes)
        try archive.addEntry(
            with: "payload.txt",
            type: .file,
            uncompressedSize: Int64(inflatedBytes),
            compressionMethod: .deflate,
            provider: { position, size in
                payload.subdata(in: Int(position) ..< Int(position) + size)
            }
        )

        var bytes = [UInt8](try Data(contentsOf: zipURL))
        let honest = withUnsafeBytes(of: UInt32(inflatedBytes).littleEndian) { [UInt8]($0) }
        let lying = withUnsafeBytes(of: declaredBytes.littleEndian) { [UInt8]($0) }
        // The honest size appears exactly twice: local file header and central
        // directory. A different count means the fixture assumption broke.
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
        XCTAssertEqual(patched, 2, "expected the size in the local header and the directory")
        try Data(bytes).write(to: zipURL)
        return zipURL
    }

    /// Total bytes of every regular file under a directory tree.
    private func bytesOnDisk(under directory: URL) -> Int {
        guard let walker = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return 0 }
        var total = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            total += values?.fileSize ?? 0
        }
        return total
    }

    /// An ordinary small archive holding one real document.
    private func makeOrdinaryZip(named name: String, text: String) throws -> URL {
        let zipURL = workDir.appendingPathComponent(name)
        let archive = try Archive(url: zipURL, accessMode: .create)
        let data = Data(text.utf8)
        try archive.addEntry(
            with: "contract.txt",
            type: .file,
            uncompressedSize: Int64(data.count),
            provider: { position, size in
                data.subdata(in: Int(position) ..< Int(position) + size)
            }
        )
        return zipURL
    }

    /// A .ldawork file whose manifest names exactly the given documents.
    private func makeWorkspace(
        named name: String,
        documents: [(name: String, kind: String, source: URL)]
    ) throws -> URL {
        var records: [WorkspaceDocumentRecord] = []
        var sources: [UUID: URL] = [:]
        for document in documents {
            let id = UUID()
            records.append(
                WorkspaceDocumentRecord(
                    id: id,
                    name: document.name,
                    contentKind: document.kind,
                    archivePath: WorkspaceArchive.documentArchivePath(id: id, name: document.name)
                )
            )
            sources[id] = document.source
        }
        let manifest = WorkspaceManifest(
            formatVersion: WorkspaceArchive.currentFormatVersion,
            createdAtISO8601: "2026-08-31T09:00:00Z",
            appVersion: nil,
            matterLabel: nil,
            matterScopeID: nil,
            substitutionStyle: .token,
            documents: records
        )
        let fileURL = workDir.appendingPathComponent(name)
        try WorkspaceArchive.write(
            WorkspacePayload(manifest: manifest, documentSources: sources),
            to: fileURL,
            passphrase: "correct horse battery staple"
        )
        return fileURL
    }

    private func makeSession() -> SessionModel {
        let clientRoot = workDir.appendingPathComponent("clients")
        let session = SessionModel(
            makeModel: {
                let model = ReviewModel(modelPath: nil)
                model.useLLM = false
                return model
            },
            clientStore: { try ClientMappingStore(rootDirectory: clientRoot) }
        )
        session.clientProtection = { _ in .passphrase("pw") }
        return session
    }

    // MARK: - The ledger itself

    func testOneLedgerBoundsTheBytesWrittenAcrossSeveralArchives() throws {
        // Five archives that each inflate to 40 KB, expanded for one gesture
        // against a 64 KB allowance. A per-call budget writes 200 KB; the
        // ledger must stop after the first and leave at most the allowance on
        // disk.
        let budget = ArchiveBudget(totalBytes: BudgetFixture.budgetBytes)
        let archives = try (0 ..< 5).map { try makeHighRatioZip(named: "bomb-\($0).zip") }
        let inherited = ZipImporter.registeredExpansions()

        var expanded = 0
        var refusal: Error?
        for archive in archives {
            do {
                _ = try ZipImporter.expand(archive, budget: budget)
                expanded += 1
            } catch {
                refusal = error
                break
            }
        }

        XCTAssertEqual(expanded, 1, "the allowance fits one archive, not each archive")
        guard case DocumentIOError.tooLarge = try XCTUnwrap(refusal) else {
            return XCTFail("expected tooLarge from the shared ledger, got \(refusal as Any)")
        }
        let mine = ZipImporter.registeredExpansions().subtracting(inherited)
        let written = mine.reduce(0) { $0 + bytesOnDisk(under: $1) }
        XCTAssertLessThanOrEqual(
            written, budget.totalBytes,
            "one import must never inflate more than its allowance, however many archives it holds"
        )
        ZipImporter.cleanUpExpansions(mine)
    }

    func testTheLedgerStillChargesActualBytesNotDeclaredOnes() throws {
        // The second archive declares 1 KB and really inflates to 40 KB. With
        // 24 KB left on the ledger the declared-size pre-check waves it
        // through, so only mid-stream metering can refuse it.
        let budget = ArchiveBudget(totalBytes: BudgetFixture.budgetBytes)
        let honest = try makeHighRatioZip(named: "honest.zip")
        let lying = try makeLyingZip(named: "lying.zip", inflatedBytes: 40 * 1024, declaredBytes: 1024)
        let inherited = ZipImporter.registeredExpansions()

        let first = try ZipImporter.expand(honest, budget: budget)
        XCTAssertEqual(first.documents.count, 1)
        XCTAssertEqual(budget.spentBytes, UInt64(BudgetFixture.bombInflatedBytes))

        XCTAssertThrowsError(try ZipImporter.expand(lying, budget: budget)) { error in
            guard case DocumentIOError.tooLarge = error else {
                return XCTFail("expected tooLarge from actual-bytes metering, got \(error)")
            }
        }
        ZipImporter.cleanUpExpansions(ZipImporter.registeredExpansions().subtracting(inherited))
    }

    func testASingleArchiveStillGetsTheWholeAllowance() throws {
        // A ledger must not tax the ordinary case: one archive alone still has
        // the full ceiling to expand into.
        ImportLimits.archiveBudgetSeam.value = BudgetFixture.budgetBytes
        let zipURL = try makeHighRatioZip(named: "solo.zip")

        let expansion = try ZipImporter.expand(zipURL)

        XCTAssertEqual(expansion.documents.count, 1)
        XCTAssertEqual(
            try Data(contentsOf: expansion.documents[0]).count, BudgetFixture.bombInflatedBytes,
            "metered extraction must still write the intact document"
        )
    }

    // MARK: - Entry A: the workspace

    func testAWorkspaceCarryingANestedArchiveIsRefused() throws {
        let bomb = try makeHighRatioZip(named: "inner-bomb.zip")
        let fileURL = try makeWorkspace(
            named: "hostile.ldawork",
            documents: [(name: "inner-bomb.zip", kind: "zip", source: bomb)]
        )
        let liveBefore = ZipImporter.liveExpansionCount

        XCTAssertThrowsError(
            try WorkspaceArchive.read(from: fileURL, passphrase: "correct horse battery staple")
        ) { error in
            guard case WorkspaceArchiveError.unsupportedDocumentKind = error else {
                return XCTFail("expected unsupportedDocumentKind, got \(error)")
            }
        }
        XCTAssertEqual(
            ZipImporter.liveExpansionCount, liveBefore,
            "a refused workspace must not leave its partial unpack registered"
        )
    }

    func testAWorkspaceOfOrdinaryDocumentsStillOpensAndSpendsTheGivenLedger() throws {
        let text = workDir.appendingPathComponent("statement.txt")
        try Data("Zhang Weiming signed on Tuesday.".utf8).write(to: text)
        let image = workDir.appendingPathComponent("stamp.png")
        try Data(repeating: 0x89, count: 512).write(to: image)
        let fileURL = try makeWorkspace(
            named: "ordinary.ldawork",
            documents: [
                (name: "statement.txt", kind: "txt", source: text),
                (name: "stamp.png", kind: "png", source: image)
            ]
        )
        let budget = ArchiveBudget(totalBytes: BudgetFixture.budgetBytes)

        let opened = try WorkspaceArchive.read(
            from: fileURL,
            passphrase: "correct horse battery staple",
            budget: budget
        )

        XCTAssertEqual(opened.documentURLs.count, 2, "the whitelist must pass the real tray types")
        XCTAssertGreaterThan(
            budget.spentBytes, 0,
            "the open must spend the ledger it was handed, not a private one"
        )
        opened.expansion.cleanUp()
    }

    // MARK: - Entry B: folder batch import

    func testFolderDiscoveryDoesNotCollectArchives() throws {
        let root = workDir.appendingPathComponent("from-client", isDirectory: true)
        for index in 0 ..< 5 {
            try makeHighRatioZip(named: "bundle-\(index).zip", under: root)
        }
        try Data("real document".utf8).write(
            to: root.appendingPathComponent("statement.txt")
        )

        let discovered = try FolderImporter.discoverDocuments(in: root)

        XCTAssertEqual(
            discovered.map { $0.lastPathComponent }, ["statement.txt"],
            "a folder import must not recurse into archives it finds inside the folder"
        )
    }

    // MARK: - One import, one ledger

    func testASelectionOfSeveralArchivesSharesOneBudget() async throws {
        // Each archive inflates to 40 KB against a 64 KB allowance, so any ONE
        // of them fits and the pair does not. With a per-call budget both
        // expand and 80 KB lands in temp; with a ledger the import is refused.
        ImportLimits.archiveBudgetSeam.value = BudgetFixture.budgetBytes
        let first = try makeHighRatioZip(named: "one.zip")
        let second = try makeHighRatioZip(named: "two.zip")
        let session = makeSession()
        let liveBefore = ZipImporter.liveExpansionCount

        await session.addDocuments([first, second])

        XCTAssertTrue(
            session.entries.isEmpty,
            "a refused import must put nothing in the tray, not a partial batch"
        )
        XCTAssertEqual(
            ZipImporter.liveExpansionCount, liveBefore,
            "the expansions written before the breach must be cleaned up"
        )
        let failure = try XCTUnwrap(
            session.importFailure,
            "a budget breach must be reported, not swallowed into a missing document"
        )
        XCTAssertTrue(
            failure.contains("64 KB") || failure.contains("65536 bytes"),
            "the refusal must name the limit it hit: \(failure)"
        )
        XCTAssertTrue(
            failure.contains("unpacking limit"),
            "the refusal must say what kind of limit it is: \(failure)"
        )
    }

    func testAnOrdinaryArchiveStillImportsInOneSelection() async throws {
        ImportLimits.archiveBudgetSeam.value = BudgetFixture.budgetBytes
        let loose = workDir.appendingPathComponent("cover.txt")
        try Data("Cover letter.".utf8).write(to: loose)
        let zipURL = try makeOrdinaryZip(named: "bundle.zip", text: "Acme Corp agrees.")
        let session = makeSession()

        await session.addDocuments([loose, zipURL])

        XCTAssertNil(session.importFailure)
        XCTAssertEqual(
            session.entries.map { $0.name }, ["cover.txt", "contract.txt"],
            "an ordinary selection with an archive in it must still import whole"
        )
    }
}
