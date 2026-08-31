//
//  BatchScanAndSealUITests.swift
//  LDACoreTests
//
//  The session half of the folder batch feature (F3) plus the SEAL picker
//  leftovers: the canScanAll gate, the sequential Scan All pass with
//  selection following the live document, the stop behavior (cancel the
//  current document, leave the queue remainder imported), and SEAL being
//  assignable by hand in the missed-item and vocabulary pickers.
//
//  Deterministic-only sessions except the stop test, which fakes the LLM
//  through the extractor seam with a completer that blocks until the user's
//  stop lands, so the cancellation is staged without timing luck.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

/// A fake model whose completion blocks until the pass is cancelled, then
/// aborts exactly like the real engine. The fallback return bounds a broken
/// test instead of hanging the suite.
private struct BlockingCompleter: TextCompleter {
    let cancel: ExtractionCancelToken?

    func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
        for _ in 0..<400 {
            if cancel?.isCancelled == true { throw ExtractionCancelled() }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return #"{"entities":[]}"#
    }
}

@MainActor
final class BatchScanAndSealUITests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatchScanAndSealUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    private func write(_ name: String, _ content: String) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    /// A deterministic-only session (or, with a model path, one whose AI pass
    /// runs through the extractor seam), on hermetic temp-rooted stores.
    private func makeSession(modelPath: String? = nil) -> SessionModel {
        let clientRoot = workDir.appendingPathComponent("clients")
        let session = SessionModel(
            makeModel: {
                let model = ReviewModel(modelPath: modelPath)
                model.useLLM = modelPath != nil
                return model
            },
            clientStore: { try ClientMappingStore(rootDirectory: clientRoot) }
        )
        session.clientProtection = { _ in .passphrase("pw") }
        let recordRoot = workDir.appendingPathComponent("records")
        session.recordStore = { try SessionRecordStore(rootDirectory: recordRoot) }
        session.recordProtection = { .passphrase("pw") }
        let matterRoot = workDir.appendingPathComponent("matters")
        session.matterStore = { try MatterMetadataStore(rootDirectory: matterRoot) }
        session.matterProtection = { .passphrase("pw") }
        let parkedURL = workDir.appendingPathComponent("parked-test.ldamap")
        session.parkedMappingURL = { parkedURL }
        session.parkedProtection = { .passphrase("parked-pw") }
        return session
    }

    // MARK: - canScanAll gating

    func testCanScanAllRequiresAnImportedDocument() async throws {
        let session = makeSession()
        XCTAssertFalse(session.canScanAll, "an empty tray has nothing to scan")

        let docA = try write("a.txt", "Mail john@acme.com please.")
        let docB = try write("b.txt", "Call 13812345678 now.")
        await session.addDocuments([docA, docB])
        XCTAssertTrue(session.canScanAll)

        await session.anonymizeAll()
        XCTAssertFalse(
            session.canScanAll,
            "with every document scanned there is nothing left for Scan All"
        )
    }

    // MARK: - Sequential pass

    func testScanAllScansEveryImportedDocumentAndFollowsSelection() async throws {
        let session = makeSession()
        let docA = try write("a.txt", "Mail john@acme.com please.")
        let docB = try write("b.txt", "Call 13812345678 now.")
        await session.addDocuments([docA, docB])
        // Park the selection on the first document so the follow is visible.
        session.selectedID = session.entries[0].id

        await session.anonymizeAll()

        XCTAssertEqual(session.entries[0].model.status, .ready)
        XCTAssertEqual(session.entries[1].model.status, .ready)
        XCTAssertEqual(session.entries[0].model.entities.count, 1)
        XCTAssertEqual(session.entries[1].model.entities.count, 1)
        XCTAssertEqual(
            session.selectedID,
            session.entries[1].id,
            "selection must follow the pass so the banner Stop reaches the live document"
        )
    }

    // MARK: - Stop behavior

    func testStopDuringScanAllCancelsCurrentAndLeavesTheRemainderImported() async throws {
        let dummyModel = workDir.appendingPathComponent("dummy.gguf")
        try Data("placeholder".utf8).write(to: dummyModel)
        ReviewModel.llmExtractorFactoryForTesting = { _, cancel in
            LLMExtractor(completer: BlockingCompleter(cancel: cancel), cancelToken: cancel)
        }
        defer { ReviewModel.llmExtractorFactoryForTesting = nil }

        let session = makeSession(modelPath: dummyModel.path)
        let docA = try write("a.txt", "Witness statement: Jordan Marlowe attended.")
        let docB = try write("b.txt", "The filing was prepared this week.")
        await session.addDocuments([docA, docB])

        let pass = Task { await session.anonymizeAll() }
        var sawDetecting = false
        for _ in 0..<400 {
            if session.entries[0].model.status == .detecting {
                sawDetecting = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(sawDetecting, "fixture: the first document must reach the model pass")
        XCTAssertFalse(session.canScanAll, "Scan All must be gated while a pass runs")

        session.entries[0].model.cancelAnonymize()
        await pass.value

        XCTAssertEqual(
            session.entries[0].model.status,
            .imported,
            "the stopped document returns to imported with no partial results"
        )
        XCTAssertTrue(session.entries[0].model.entities.isEmpty)
        XCTAssertEqual(
            session.entries[1].model.status,
            .imported,
            "stopping ends the queue; the remainder stays imported and untouched"
        )
        XCTAssertTrue(session.entries[1].model.entities.isEmpty)
        XCTAssertTrue(session.canScanAll, "the untouched remainder can be scanned again")
    }

    // MARK: - SEAL assignment

    func testSealIsAssignableInBothPickersAndGroupsInTheSidebar() {
        XCTAssertTrue(AssignableEntityTypes.manual.contains(.seal))
        XCTAssertTrue(AssignableEntityTypes.vocabulary.contains(.seal))
        XCTAssertTrue(
            AssignableEntityTypes.vocabulary.contains(.unknown),
            "the vocabulary picker keeps its neutral bucket"
        )
        XCTAssertFalse(
            AssignableEntityTypes.manual.contains(.unknown),
            "a manually protected item always has a concrete kind"
        )
        XCTAssertTrue(
            ReviewModel.groupTypeOrder.contains(.seal),
            "the sidebar section order must carry SEAL groups"
        )

        // A manual seal entity groups under SEAL like any other kind.
        let model = ReviewModel(modelPath: nil)
        model.documentText = "Stamped with the corporate seal HONGZHANG."
        XCTAssertEqual(model.addManualEntity(text: "HONGZHANG", type: .seal), 1)
        XCTAssertEqual(model.groups(of: .seal).count, 1)
        XCTAssertEqual(model.groups(of: .seal).first?.value, "HONGZHANG")
    }
}
