//
//  LDAV4ExtractorTests.swift
//  LDACoreTests
//
//  The built-in LDA V4 tagger as a detection source: which labels it redacts,
//  what a model folder must hold, how a model path chooses between the tagger
//  and a GGUF, and that a folder that cannot load is refused like any other
//  model that cannot run. The live test runs only when LDA_V4_MODEL_DIR names
//  a model folder laid out as the app carries it (LDA-V4.mlmodelc,
//  runtime.json, tokenizer/).
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class LDAV4ExtractorTests: XCTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        assertNoTestSeamsInstalled()
    }

    private func temporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LDAV4ExtractorTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A folder with every file the tagger loads, all of them empty.
    private func emptyModelFolder() throws -> URL {
        let root = try temporaryDirectory("folder")
        let fm = FileManager.default
        try fm.createDirectory(
            at: root.appendingPathComponent(LDAV4Extractor.compiledModelName, isDirectory: true),
            withIntermediateDirectories: true
        )
        try fm.createDirectory(at: root.appendingPathComponent("tokenizer"), withIntermediateDirectories: true)
        for file in [LDAV4Extractor.runtimeFileName, "tokenizer/vocab.json", "tokenizer/charsmap.bin", "tokenizer/tables.json"] {
            try Data().write(to: root.appendingPathComponent(file))
        }
        return root
    }

    // MARK: - Labels

    func testRedactionLabelsMapToLDATypesAndKeepLabelsAreDropped() {
        XCTAssertEqual(LDAV4Extractor.entityType(forTaggerLabel: "PERSON"), .person)
        XCTAssertEqual(LDAV4Extractor.entityType(forTaggerLabel: "COMPANY"), .company)
        XCTAssertEqual(LDAV4Extractor.entityType(forTaggerLabel: "ADDRESS"), .address)
        // Brands get their own placeholder type, so they never count as
        // companies; they are still redacted, as the model was evaluated.
        XCTAssertEqual(LDAV4Extractor.entityType(forTaggerLabel: "TRADEMARK"), .trademark)
        // LDA has no vessel placeholder type, so vessels are replaced as COMPANY.
        XCTAssertEqual(LDAV4Extractor.entityType(forTaggerLabel: "VESSEL"), .company)
        // Courts, agencies and jurisdictions are kept, never redacted.
        XCTAssertNil(LDAV4Extractor.entityType(forTaggerLabel: "KEEP_ORG"))
        XCTAssertNil(LDAV4Extractor.entityType(forTaggerLabel: "KEEP_PLACE"))
        XCTAssertNil(LDAV4Extractor.entityType(forTaggerLabel: "O"))
    }

    // MARK: - Spans the tagger reports end to end

    func testTouchingSpansOfOneTypeAreJoined() {
        let joined = LDAV4Extractor.joiningTouchingSpans([(10, 15, .company), (15, 18, .company), (30, 33, .company)])
        XCTAssertEqual(joined.map { [$0.start, $0.end] }, [[10, 18], [30, 33]])
    }

    func testABrandTouchingACompanyJoinsAsTheLaterType() {
        let joined = LDAV4Extractor.joiningTouchingSpans([(0, 3, .trademark), (3, 6, .company), (6, 8, .person)])
        XCTAssertEqual(joined.map { [$0.start, $0.end] }, [[0, 6], [6, 8]])
        XCTAssertEqual(joined.map(\.type), [.company, .person], "a person is never joined to a name")
    }

    func testSpansWithAGapStayApart() {
        let joined = LDAV4Extractor.joiningTouchingSpans([(0, 3, .company), (4, 6, .company)])
        XCTAssertEqual(joined.count, 2)
    }

    // MARK: - Model folder

    func testAModelFolderNeedsEveryFileTheTaggerLoads() throws {
        let root = try emptyModelFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(LDAV4Extractor.isModelDirectory(root.path))

        try FileManager.default.removeItem(at: root.appendingPathComponent("tokenizer/vocab.json"))
        XCTAssertFalse(LDAV4Extractor.isModelDirectory(root.path), "a folder without the vocabulary is not a model")
    }

    func testAFileIsNeverAModelFolder() throws {
        let root = try temporaryDirectory("file")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("model.gguf")
        try Data("GGUF".utf8).write(to: file)
        XCTAssertFalse(LDAV4Extractor.isModelDirectory(file.path))
        XCTAssertFalse(LDAV4Extractor.isModelDirectory(root.appendingPathComponent("missing").path))
    }

    func testAModelFolderThatCannotLoadIsRefusedBeforeAnythingIsWritten() throws {
        // The folder has the right shape but empty files. Asking for it is a
        // request for names to be found, so it must be refused, never run as
        // a pattern-only pass that reports success.
        let root = try emptyModelFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try LDAService.makeDetector(modelPath: root.path)) { error in
            guard case LDAServiceError.modelUnavailable(let path, _) = error else {
                return XCTFail("expected modelUnavailable, got \(error)")
            }
            XCTAssertEqual(path, root.path)
        }
    }

    func testFillingRefusesTheTaggerWithAnExplanation() throws {
        let root = try emptyModelFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try LDAService.makeCompleter(modelPath: root.path)) { error in
            guard case LDAServiceError.modelUnavailable(_, let reason) = error else {
                return XCTFail("expected modelUnavailable, got \(error)")
            }
            XCTAssertTrue(reason.contains("cannot fill"), reason)
        }
    }

    // MARK: - Live model (opt in)

    func testTheBundledModelFindsNamesThroughTheService() throws {
        guard let folder = ProcessInfo.processInfo.environment["LDA_V4_MODEL_DIR"] else {
            throw XCTSkip("set LDA_V4_MODEL_DIR to an LDA V4 model folder to run the live tagger")
        }
        XCTAssertTrue(LDAV4Extractor.isModelDirectory(folder))
        let root = try temporaryDirectory("live")
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("agreement.txt")
        let text = """
        This Agreement is made between Margaret Ellison and Northwind Lantern Holdings Ltd. \
        before the Superior Court of California. 原告张晓明诉被告杭州云帆网络科技有限公司买卖合同纠纷一案。
        """
        try Data(text.utf8).write(to: input)

        let spans = try LDAService.detect(input: input, llmModelPath: folder)
        let found = Set(spans.map { "\($0.type.rawValue):\($0.text)" })
        for expected in [
            "PERSON:Margaret Ellison",
            "COMPANY:Northwind Lantern Holdings Ltd.",
            "PERSON:张晓明",
            "COMPANY:杭州云帆网络科技有限公司"
        ] {
            XCTAssertTrue(found.contains(expected), "missing \(expected) in \(found.sorted())")
        }
        XCTAssertFalse(
            spans.contains { $0.text.contains("Superior Court") },
            "a court is a keep label and must stay visible"
        )
    }

    func testTheBundledModelListsANameRedactedOnceAndGluedElsewhere() throws {
        guard let folder = ProcessInfo.processInfo.environment["LDA_V4_MODEL_DIR"] else {
            throw XCTSkip("set LDA_V4_MODEL_DIR to an LDA V4 model folder to run the live tagger")
        }
        // The shape a reviewer reproduced with the shipped model: the first
        // mention anchors and is redacted, and the footnoted repeat was left
        // in clear with nothing said. It is listed now, and the service
        // refuses to write output, as for a value that anchors nowhere.
        let text = "This Agreement is made between Margaret Ellison and Northwind Lantern Holdings Ltd. "
            + "Witnessed by Margaret Ellison3 on 3 May."
        let extractor = try LDAV4Extractor(
            modelDirectory: URL(fileURLWithPath: folder, isDirectory: true),
            cancelToken: nil
        )
        let result = try extractor.extractDetailed(from: text, onProgress: nil)
        XCTAssertTrue(
            result.spans.contains { $0.type == .person && $0.start == (text as NSString).range(of: "Margaret Ellison").location },
            "the first mention is redacted as before"
        )
        XCTAssertTrue(
            result.unlocatedEntities.contains(ExtractedEntity(value: "Margaret Ellison", type: .person)),
            "the glued repeat is named: \(result.unlocatedEntities.map(\.type))"
        )
        XCTAssertFalse(result.fullyAnchored)

        let root = try temporaryDirectory("live-glued")
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("glued.txt")
        try Data(text.utf8).write(to: input)
        XCTAssertThrowsError(try LDAService.detect(input: input, llmModelPath: folder)) { error in
            guard case LDAServiceError.unanchoredEntities = error else {
                XCTFail("expected LDAServiceError.unanchoredEntities, got \(error)")
                return
            }
        }
    }
}
