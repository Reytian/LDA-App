//
//  CrossFeatureIntegrationTests.swift
//  LDACoreTests
//
//  Cross-feature proofs for the 2026-08-30 roadmap wave: the features landed
//  in separate workstreams (structured deterministic types, rescan plus alias
//  grouping, substitution styles) and each was proven in isolation on its own
//  branch. These tests pin the INTERACTIONS after the merge:
//
//   1. Alias grouping under the pseudonym style still restores the original
//      byte-identically, and the companion carries no brace markup at all,
//      which is what makes it immune to the AI rewriting that breaks tokens.
//   2. The new deterministic types (case number, plate, WeChat, URL) flow
//      through the pseudonym style and restore byte-identically.
//
//  The LLM layer is faked through LDAService.makeExtractorForTesting, so no
//  GGUF model is needed.
//
//  House rules: all comments and strings in English (fixtures may contain
//  Chinese). No em-dash and no en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class CrossFeatureIntegrationTests: XCTestCase {

    private static let createdAt = "2026-08-30T00:00:00Z"
    private static let bogusModelPath = "/nonexistent.gguf"
    private static let passphrase = "correct horse battery staple"

    /// Full name, defined short name, a person, and one of each structured
    /// deterministic type. The fake model reports only the full company name
    /// and the person: the short name comes from the alias scan plus rescan,
    /// the structured values from the deterministic engine.
    private static let contractText = """
    股权转让协议（2026）粤03民初12345号

    甲方：杭州快帆科技有限公司（以下简称"快帆科技"）
    乙方：张三（微信号：zhangsan_88，车牌 粤B·AA0003）

    第一条 快帆科技应当在本协议签署后十日内办理变更登记。
    第二条 张三应当配合快帆科技提交全部申请材料，详见 https://example.com/filing 。
    第三条 杭州快帆科技有限公司的公章由其保管。
    """

    private struct FullNameOnlyCompleter: TextCompleter {
        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
            return #"{"entities":[{"value":"杭州快帆科技有限公司","type":"COMPANY"},"#
                + #"{"value":"张三","type":"PERSON"}]}"#
        }
    }

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrossFeatureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        LDAService.makeExtractorForTesting = nil
        if let workDir, FileManager.default.fileExists(atPath: workDir.path) {
            try? FileManager.default.removeItem(at: workDir)
        }
        workDir = nil
        try super.tearDownWithError()
    }

    func testAliasGroupingAndStructuredTypesUnderPseudonymStyleRoundTrip() throws {
        LDAService.makeExtractorForTesting = { _ in
            LLMExtractor(completer: FullNameOnlyCompleter())
        }
        let input = workDir.appendingPathComponent("contract.txt")
        try Data(Self.contractText.utf8).write(to: input)
        let outputDir = workDir.appendingPathComponent("out", isDirectory: true)
        let protection = MappingProtection.passphrase(Self.passphrase)

        let result = try LDAService.anonymize(
            input: input,
            outputDir: outputDir,
            protection: protection,
            createdAtISO8601: Self.createdAt,
            llmModelPath: Self.bogusModelPath,
            style: .pseudonym
        )

        let companion = try String(contentsOf: result.redactedFileURL, encoding: .utf8)

        // Nothing sensitive survives: the LLM-reported names, the alias the
        // model never reported, and every structured deterministic value.
        for leaked in [
            "杭州快帆科技有限公司", "快帆科技", "张三",
            "（2026）粤03民初12345号", "zhangsan_88",
            "粤B·AA0003", "https://example.com/filing"
        ] {
            XCTAssertFalse(companion.contains(leaked), "companion leaked \(leaked)")
        }

        // The pseudonym companion carries NO brace markup anywhere. That is
        // the mechanism of the AI-rewrite robustness: an AI that rewrites
        // {COMPANY_1} into [COMPANY_1] has nothing to rewrite here, so the
        // strongest brace mangler is a no-op on this text by construction.
        XCTAssertFalse(companion.contains("{"), "pseudonym output must carry no brace tokens")
        XCTAssertFalse(companion.contains("}"), "pseudonym output must carry no brace tokens")

        // The alias grouping survived the style: short name grouped under the
        // full name's canonical replacement, both with their own entries.
        let mapping = try MappingStore.load(from: result.mappingFileURL, protection: protection)
        XCTAssertEqual(mapping.style, .pseudonym)
        let fullEntry = mapping.entries.values.first { $0.value == "杭州快帆科技有限公司" }
        let shortEntry = mapping.entries.values.first { $0.value == "快帆科技" }
        XCTAssertNotNil(fullEntry)
        XCTAssertNotNil(shortEntry)
        XCTAssertEqual(shortEntry?.canonicalToken, fullEntry?.token)

        // The unedited round trip restores the original byte-identically,
        // with the alias, the person, and every structured value back in
        // place.
        let restored = workDir.appendingPathComponent("restored.txt")
        let report = try LDAService.restore(
            editedRedacted: result.redactedFileURL,
            mapping: result.mappingFileURL,
            protection: protection,
            output: restored
        )
        XCTAssertTrue(report.orphanTokens.isEmpty)
        XCTAssertTrue(report.ambiguousReplacements.isEmpty)
        let restoredText = try String(contentsOf: restored, encoding: .utf8)
        XCTAssertEqual(restoredText, Self.contractText)
    }
}
