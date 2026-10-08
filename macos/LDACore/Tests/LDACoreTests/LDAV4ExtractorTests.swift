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
        // LDA has no trademark or vessel placeholder type, so both are replaced
        // as COMPANY, the way the model was evaluated.
        XCTAssertEqual(LDAV4Extractor.entityType(forTaggerLabel: "TRADEMARK"), .company)
        XCTAssertEqual(LDAV4Extractor.entityType(forTaggerLabel: "VESSEL"), .company)
        // Courts, agencies and jurisdictions are kept, never redacted.
        XCTAssertNil(LDAV4Extractor.entityType(forTaggerLabel: "KEEP_ORG"))
        XCTAssertNil(LDAV4Extractor.entityType(forTaggerLabel: "KEEP_PLACE"))
        XCTAssertNil(LDAV4Extractor.entityType(forTaggerLabel: "O"))
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
}
