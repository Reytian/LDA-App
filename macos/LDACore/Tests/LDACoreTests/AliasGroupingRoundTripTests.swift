//
//  AliasGroupingRoundTripTests.swift
//  LDACoreTests
//
//  Facade-level proof of the recall rescan and the full-name/short-name
//  grouping: the model reports ONLY the full company name, yet every defined
//  short-name mention is detected and tokenized, the mapping records the
//  grouping via canonicalToken, and the unedited round trip restores the
//  original text byte-identically with both forms present.
//
//  The LLM layer is faked through LDAService.makeExtractorForTesting, so no
//  GGUF model is needed.
//
//  House rules: all comments and strings in English (fixtures may contain
//  Chinese). No em-dash and no en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class AliasGroupingRoundTripTests: XCTestCase {

    // MARK: - Fixtures

    private static let createdAt = "2026-08-30T00:00:00Z"
    private static let bogusModelPath = "/nonexistent.gguf"
    private static let passphrase = "correct horse battery staple"

    /// Both the full name and the defined short name appear; the fake model
    /// reports only the full name and the person.
    private static let contractText = """
    股权转让协议

    甲方：杭州快帆科技有限公司（以下简称"快帆科技"）
    乙方：张三

    第一条 快帆科技应当在本协议签署后十日内办理变更登记。
    第二条 张三应当配合快帆科技提交全部申请材料。
    第三条 杭州快帆科技有限公司的公章由其保管。
    """

    /// A completer that reports the full company name and the person, and
    /// never the short name: the rescan must recover the short name.
    private struct FullNameOnlyCompleter: TextCompleter {
        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
            return #"{"entities":[{"value":"杭州快帆科技有限公司","type":"COMPANY"},"#
                + #"{"value":"张三","type":"PERSON"}]}"#
        }
    }

    /// A completer that reports one person once; the document mentions the
    /// person five times.
    private struct SinglePersonCompleter: TextCompleter {
        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
            return #"{"entities":[{"value":"Robert King","type":"PERSON"}]}"#
        }
    }

    // MARK: - Hermetic working directory

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AliasGroupingTests-\(UUID().uuidString)", isDirectory: true)
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

    private func write(_ text: String, name: String) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    // MARK: - Detect: the rescan recovers short-name mentions

    func testDetectRecoversShortNameMentionsTheModelNeverReported() throws {
        LDAService.makeExtractorForTesting = { _ in
            LLMExtractor(completer: FullNameOnlyCompleter())
        }
        let input = try write(Self.contractText, name: "contract.txt")

        let spans = try LDAService.detect(input: input, llmModelPath: Self.bogusModelPath)

        XCTAssertEqual(
            spans.filter { $0.text == "快帆科技" }.count,
            3,
            "definition site plus two body mentions must all be detected"
        )
        XCTAssertEqual(spans.filter { $0.text == "杭州快帆科技有限公司" }.count, 2)
        XCTAssertEqual(spans.filter { $0.text == "张三" }.count, 2)
    }

    // MARK: - Anonymize: grouping in the mapping, no leak in the companion

    func testAnonymizeGroupsAliasAndLeaksNothing() throws {
        LDAService.makeExtractorForTesting = { _ in
            LLMExtractor(completer: FullNameOnlyCompleter())
        }
        let input = try write(Self.contractText, name: "contract.txt")
        let outputDir = workDir.appendingPathComponent("out", isDirectory: true)
        let protection = MappingProtection.passphrase(Self.passphrase)

        let result = try LDAService.anonymize(
            input: input,
            outputDir: outputDir,
            protection: protection,
            createdAtISO8601: Self.createdAt,
            llmModelPath: Self.bogusModelPath
        )

        // The companion text must contain neither the full name, nor the
        // short name, nor the person.
        let companion = try String(contentsOf: result.redactedFileURL, encoding: .utf8)
        XCTAssertFalse(companion.contains("快帆科技"))
        XCTAssertFalse(companion.contains("杭州快帆科技有限公司"))
        XCTAssertFalse(companion.contains("张三"))

        // The mapping groups the short name under the full name's token, while
        // both keep their own token and value.
        let mapping = try MappingStore.load(from: result.mappingFileURL, protection: protection)
        let fullEntry = mapping.entries.values.first { $0.value == "杭州快帆科技有限公司" }
        let shortEntry = mapping.entries.values.first { $0.value == "快帆科技" }
        XCTAssertNotNil(fullEntry)
        XCTAssertNotNil(shortEntry)
        XCTAssertEqual(shortEntry?.canonicalToken, fullEntry?.token)
        XCTAssertNil(fullEntry?.canonicalToken)
        XCTAssertNotEqual(shortEntry?.token, fullEntry?.token)

        // The same surface reuses the same token at every site: exactly one
        // mapping entry per distinct surface.
        XCTAssertEqual(mapping.entries.values.filter { $0.value == "快帆科技" }.count, 1)

        // Every short-name site carries the SAME placeholder in the companion.
        if let shortToken = shortEntry?.token {
            XCTAssertEqual(companion.components(separatedBy: shortToken).count - 1, 3)
        }
    }

    func testUneditedRoundTripWithBothFormsIsByteIdentical() throws {
        LDAService.makeExtractorForTesting = { _ in
            LLMExtractor(completer: FullNameOnlyCompleter())
        }
        let input = try write(Self.contractText, name: "contract.txt")
        let outputDir = workDir.appendingPathComponent("out", isDirectory: true)
        let protection = MappingProtection.passphrase(Self.passphrase)

        let result = try LDAService.anonymize(
            input: input,
            outputDir: outputDir,
            protection: protection,
            createdAtISO8601: Self.createdAt,
            llmModelPath: Self.bogusModelPath
        )

        let restoredURL = outputDir.appendingPathComponent("restored.txt")
        let report = try LDAService.restore(
            editedRedacted: result.redactedFileURL,
            mapping: result.mappingFileURL,
            protection: protection,
            output: restoredURL
        )

        XCTAssertTrue(report.orphanTokens.isEmpty)
        let restored = try String(contentsOf: restoredURL, encoding: .utf8)
        XCTAssertEqual(
            restored,
            Self.contractText,
            "full-name sites must restore the full name and short-name sites the short name, byte-identically"
        )
    }

    // MARK: - One entity, many mentions, one placeholder

    func testEntityMentionedFiveTimesAcrossChunksMapsToOnePlaceholder() throws {
        LDAService.makeExtractorForTesting = { _ in
            LLMExtractor(completer: SinglePersonCompleter())
        }
        // Spread the five mentions over enough filler prose that SegmentPacker
        // splits the document into several extraction windows (target window
        // is 2000 characters), so the mentions genuinely live in different
        // chunks and still collapse onto one placeholder.
        let filler = String(
            repeating: "The parties exchanged schedules and reviewed the annexes in detail. ",
            count: 18
        )
        let text = [
            "Robert King appeared before the tribunal.",
            filler,
            "Robert King testified about the delivery terms.",
            filler,
            "The court heard Robert King a second time.",
            filler,
            "Then Robert King rested his case.",
            filler,
            "Judgment was entered for Robert King."
        ].joined(separator: "\n\n")
        XCTAssertGreaterThan(
            text.utf16.count, 4000,
            "fixture must be large enough to span several extraction windows"
        )
        let input = try write(text, name: "mentions.txt")
        let outputDir = workDir.appendingPathComponent("out5", isDirectory: true)
        let protection = MappingProtection.passphrase(Self.passphrase)

        let result = try LDAService.anonymize(
            input: input,
            outputDir: outputDir,
            protection: protection,
            createdAtISO8601: Self.createdAt,
            llmModelPath: Self.bogusModelPath
        )

        let companion = try String(contentsOf: result.redactedFileURL, encoding: .utf8)
        XCTAssertFalse(companion.contains("Robert King"))

        let mapping = try MappingStore.load(from: result.mappingFileURL, protection: protection)
        let personEntries = mapping.entries.values.filter { $0.value == "Robert King" }
        XCTAssertEqual(personEntries.count, 1, "one surface, one token")
        if let token = personEntries.first?.token {
            XCTAssertEqual(
                companion.components(separatedBy: token).count - 1,
                5,
                "all five mentions must carry the one placeholder"
            )
        }
    }

    // MARK: - Session flow carries the grouping into the shared mapping

    func testSessionMappingCarriesAliasGrouping() throws {
        LDAService.makeExtractorForTesting = { _ in
            LLMExtractor(completer: FullNameOnlyCompleter())
        }
        let first = try write(Self.contractText, name: "doc1.txt")
        let second = try write("快帆科技确认收到全部款项。", name: "doc2.txt")

        let session = try LDAService.anonymizeSession(
            inputs: [first, second],
            createdAtISO8601: Self.createdAt,
            llmModelPath: Self.bogusModelPath
        )

        let fullEntry = session.mapping.entries.values.first { $0.value == "杭州快帆科技有限公司" }
        let shortEntry = session.mapping.entries.values.first { $0.value == "快帆科技" }
        XCTAssertEqual(shortEntry?.canonicalToken, fullEntry?.token)

        // The second document's short-name mention reuses the SAME token the
        // first document minted for that surface.
        if let shortToken = shortEntry?.token {
            XCTAssertTrue(session.documents[1].redactedMarkdown.contains(shortToken))
        }
        XCTAssertFalse(session.documents[1].redactedMarkdown.contains("快帆科技"))
    }
}
