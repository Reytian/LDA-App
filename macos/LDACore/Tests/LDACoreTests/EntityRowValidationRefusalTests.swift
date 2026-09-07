//
//  EntityRowValidationRefusalTests.swift
//  LDACoreTests
//
//  R1: a malformed entity row must not produce a successful privacy export.
//
//  The parser used to accept any row carrying a nonempty value, whatever its
//  type said, and to call a mixed array complete as long as ONE row was
//  usable. The extractor then dropped every row whose type it does not keep,
//  including the .unknown rows, and still reported full coverage. Three
//  completions therefore exported clear names:
//
//  - {"entities":[{"value":"Alice Smith"}]}: no type at all.
//  - {"entities":[{"value":"Alice Smith","type":"PER"}]}: a type spelling
//    outside EntityType's raw values.
//  - a valid Alice row followed by {"text":"Bob Jones","label":"PERSON"}:
//    another schema, silently skipped, exporting Bob Jones in the clear.
//
//  The repaired contract: a row is valid only with a nonempty value AND a
//  type that decodes to a supported EntityType. A recognized type the
//  extractor does not keep (EMAIL, DATE) is still a VALID row. Any invalid
//  row makes the completion `invalid`, so the segment counts as unscanned and
//  the release gate refuses, while the decoded rows stay as salvage.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class EntityRowValidationRefusalTests: XCTestCase {

    private struct FixedCompleter: TextCompleter {
        let output: String
        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
            return output
        }
    }

    /// The reviewer's exact source text. Short enough to be one extraction
    /// window, so one malformed completion is one unscanned segment.
    private static let text = "Alice Smith signed with Bob Jones."

    /// The reviewer's exact completions.
    private static let missingType = #"{"entities":[{"value":"Alice Smith"}]}"#
    private static let unknownType = #"{"entities":[{"value":"Alice Smith","type":"PER"}]}"#
    private static let mixedRow = #"{"entities":[{"value":"Alice Smith","type":"PERSON"},{"text":"Bob Jones","label":"PERSON"}]}"#

    override func setUpWithError() throws {
        try super.setUpWithError()
        assertNoTestSeamsInstalled()
    }

    override func tearDown() {
        LDAService.makeExtractorForTesting = nil
        super.tearDown()
    }

    // MARK: - Parser: an invalid row invalidates the completion

    func testRowWithoutATypeIsInvalidAndKeepsItsSalvage() {
        let parse = EntityJSONParser.parseDetailed(Self.missingType)

        XCTAssertTrue(parse.invalid, "a row with no type says nothing about what it is")
        XCTAssertFalse(parse.isComplete)
        XCTAssertEqual(
            parse.entities,
            [ExtractedEntity(value: "Alice Smith", type: .unknown)],
            "the decoded row stays as salvage"
        )
    }

    func testRowWithAnUnrecognizedTypeIsInvalid() {
        let parse = EntityJSONParser.parseDetailed(Self.unknownType)

        XCTAssertTrue(parse.invalid, "PER is not a supported EntityType spelling")
        XCTAssertFalse(parse.isComplete)
    }

    func testMixedArrayWithOneOtherSchemaRowIsInvalid() {
        let parse = EntityJSONParser.parseDetailed(Self.mixedRow)

        XCTAssertTrue(
            parse.invalid,
            "one silently skipped row means the completion is partly uninterpretable"
        )
        XCTAssertEqual(
            parse.entities,
            [ExtractedEntity(value: "Alice Smith", type: .person)],
            "the valid row stays as salvage"
        )
    }

    func testRecognizedTypeTheExtractorDropsIsStillAValidRow() {
        let parse = EntityJSONParser.parseDetailed(
            #"{"entities":[{"value":"a@b.test","type":"EMAIL"},{"value":"2026-09-07","type":"DATE"}]}"#
        )

        XCTAssertTrue(
            parse.isComplete,
            "EMAIL and DATE are recognized types the DeterministicEngine owns, not schema failures"
        )
        XCTAssertFalse(parse.invalid)
    }

    // MARK: - Extractor: coverage sees an unscanned segment

    func testMalformedRowsMarkTheSegmentUnscanned() throws {
        for output in [Self.missingType, Self.unknownType, Self.mixedRow] {
            let result = try LLMExtractor(completer: FixedCompleter(output: output))
                .extractDetailed(from: Self.text)

            XCTAssertFalse(
                result.fullyCovered,
                "a partly uninterpretable completion is not a clean scan: \(output)"
            )
            XCTAssertEqual(result.incompleteSegmentCount, 1, "for \(output)")
        }
    }

    // MARK: - Facade: the release gate refuses and writes nothing

    private func writeFixture() throws -> (dir: URL, input: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EntityRowValidationRefusalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let input = dir.appendingPathComponent("source.txt")
        try Data(Self.text.utf8).write(to: input)
        return (dir, input)
    }

    private func assertAnonymizeRefuses(_ output: String) throws {
        let fixture = try writeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        LDAService.makeExtractorForTesting = { _ in
            LLMExtractor(completer: FixedCompleter(output: output))
        }
        let outputDir = fixture.dir.appendingPathComponent("out", isDirectory: true)

        XCTAssertThrowsError(
            try LDAService.anonymize(
                input: fixture.input,
                outputDir: outputDir,
                protection: .passphrase("synthetic"),
                createdAtISO8601: "2026-09-07T00:00:00Z",
                llmModelPath: "/nonexistent.gguf"
            ),
            "the export must be refused for \(output)"
        ) { error in
            XCTAssertEqual(
                error as? LDAServiceError,
                .incompleteExtraction(incompleteSegmentCount: 1),
                "for \(output)"
            )
        }
        let written = (try? FileManager.default.contentsOfDirectory(atPath: outputDir.path)) ?? []
        XCTAssertTrue(written.isEmpty, "no artifact may be written for \(output), got \(written)")
    }

    func testAnonymizeRefusesTheRowWithoutAType() throws {
        try assertAnonymizeRefuses(Self.missingType)
    }

    func testAnonymizeRefusesTheUnrecognizedType() throws {
        try assertAnonymizeRefuses(Self.unknownType)
    }

    func testAnonymizeRefusesTheMixedArrayThatWouldExportBobJones() throws {
        try assertAnonymizeRefuses(Self.mixedRow)
    }
}
