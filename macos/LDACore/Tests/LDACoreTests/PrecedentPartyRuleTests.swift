//
//  PrecedentPartyRuleTests.swift
//  LDACoreTests
//
//  A published precedent's own parties stay visible. The rule reads the
//  document's caption, releases the PERSON and COMPANY values the caption
//  names, by value, and leaves witnesses, judges, counsel and unspelled short
//  forms redacted. It runs inside the service detector, so the body and the
//  supplementary channels agree, and it never releases a value another
//  document of the session redacts.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class PrecedentPartyRuleTests: XCTestCase {

    private struct FixedCompleter: TextCompleter {
        let output: String
        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
            output
        }
    }

    private static let guiding = """
    指导案例96号：宋文军诉西安市大华餐饮有限公司股东资格确认纠纷案
    （最高人民法院审判委员会讨论通过 2018年6月20日发布）
    关键词 民事/股东资格确认
    基本案情
    原告宋文军诉称，西安市大华餐饮有限公司（以下简称大华公司）未向其返还出资。证人李明出庭作证。
    """

    private static let guidingEntities = #"""
    {"entities":[{"value":"宋文军","type":"PERSON"},{"value":"西安市大华餐饮有限公司","type":"COMPANY"},{"value":"大华公司","type":"COMPANY"},{"value":"李明","type":"PERSON"}],"redacted_text":""}
    """#

    override func setUpWithError() throws {
        try super.setUpWithError()
        assertNoTestSeamsInstalled()
    }

    override func tearDown() {
        LDAService.makeExtractorForTesting = nil
        super.tearDown()
    }

    private func spans(_ text: String, _ items: [(String, EntityType)]) -> [Span] {
        let ns = text as NSString
        var out: [Span] = []
        for (surface, type) in items {
            var from = 0
            while true {
                let r = ns.range(of: surface, range: NSRange(location: from, length: ns.length - from))
                if r.location == NSNotFound { break }
                out.append(Span(start: r.location, end: r.location + r.length, type: type, text: surface,
                                source: .llm, confidence: 0.9, priority: 30))
                from = r.location + r.length
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    // MARK: - The rule

    func testAGuidingCaseReleasesItsCaptionPartiesOnly() throws {
        let text = Self.guiding
        let all = spans(text, [("宋文军", .person), ("西安市大华餐饮有限公司", .company), ("李明", .person), ("大华公司", .company)])
        let release = try XCTUnwrap(PrecedentPartyRule.release(text: text, spans: all))
        XCTAssertTrue(release.caption.hasPrefix("指导案例96号"))
        XCTAssertEqual(Set(release.values), ["宋文军", "西安市大华餐饮有限公司"])
        let kept = all.filter { !release.releases($0) }.map(\.text)
        XCTAssertEqual(Set(kept), ["李明", "大华公司"], "the witness and the unspelled short form stay redacted")
    }

    func testAPublishedUSOpinionReleasesItsPartiesButNotTheJudge() throws {
        let text = """
        UNITED STATES COURT OF APPEALS FOR THE FIFTH CIRCUIT

        Parker v. Highland Park, Inc.

        Before SMITH, JONES and DAVIS, Circuit Judges.

        OPINION

        Parker sued Highland Park, Inc. for fraud. Judge Lindsay found that Parker had no claim.
        """
        let all = spans(text, [("Parker", .person), ("Highland Park, Inc.", .company), ("Lindsay", .person)])
        let release = try XCTUnwrap(PrecedentPartyRule.release(text: text, spans: all))
        XCTAssertEqual(release.caption, "Parker v. Highland Park, Inc.")
        XCTAssertEqual(all.filter { !release.releases($0) }.map(\.text), ["Lindsay"])
    }

    func testAnOrdinaryDocumentReleasesNothing() {
        let text = "原告宋文军诉称，被告西安市大华餐饮有限公司未返还出资。"
        let all = spans(text, [("宋文军", .person), ("西安市大华餐饮有限公司", .company)])
        XCTAssertNil(PrecedentPartyRule.release(text: text, spans: all))
    }

    func testAnUnpublishedOpinionReleasesNothing() {
        let text = """
        NOT FOR PUBLICATION

        Parker v. Highland Park, Inc.

        OPINION

        Parker sued Highland Park, Inc. for fraud.
        """
        let all = spans(text, [("Parker", .person), ("Highland Park, Inc.", .company)])
        XCTAssertNil(PrecedentPartyRule.release(text: text, spans: all))
    }

    func testAValueAnotherDocumentRedactsIsNotReleased() throws {
        // The same company is redacted in a client memo shared alongside. Its
        // name in clear here beside its token there would disclose the mapping.
        let text = Self.guiding
        let all = spans(text, [("宋文军", .person), ("西安市大华餐饮有限公司", .company)])
        let memo = spans("被告西安市大华餐饮有限公司", [("西安市大华餐饮有限公司", .company)])
        let release = try XCTUnwrap(PrecedentPartyRule.release(text: text, spans: all, redactedElsewhere: memo))
        XCTAssertEqual(release.values, ["宋文军"])
    }

    func testOnlyPersonAndCompanyValuesAreEverReleased() {
        let text = Self.guiding
        let all = spans(text, [("2018年6月20日", .date)])
        XCTAssertNil(PrecedentPartyRule.release(text: text, spans: all), "a date in a caption is not a party")
    }

    // MARK: - Through the service

    func testTheServiceLeavesCaptionPartiesInClearAndRedactsTheRest() throws {
        LDAService.makeExtractorForTesting = { _ in
            LLMExtractor(completer: FixedCompleter(output: Self.guidingEntities))
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrecedentPartyRuleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("guiding-case.txt")
        try Data(Self.guiding.utf8).write(to: input)

        let detected = try LDAService.detect(input: input, llmModelPath: "/fixture/model.gguf")
        let texts = Set(detected.map(\.text))
        XCTAssertFalse(texts.contains("宋文军"), "a caption party must stay visible")
        XCTAssertFalse(texts.contains("西安市大华餐饮有限公司"), "a caption party must stay visible")
        XCTAssertTrue(texts.contains("李明"), "a witness stays redacted")
        XCTAssertTrue(texts.contains("大华公司"), "a short form the caption does not spell stays redacted")
    }

    func testTheSupplementaryPassFollowsTheBodyDecision() throws {
        LDAService.makeExtractorForTesting = { _ in
            LLMExtractor(completer: FixedCompleter(output: Self.guidingEntities))
        }
        let detector = try LDAService.makeDetector(modelPath: "/fixture/model.gguf")
        _ = try detector.detectText(Self.guiding)

        // A header of the same document names a released party and the witness.
        let header = detector.detectForImages("宋文军 李明")
        let texts = Set(header.map(\.text))
        XCTAssertFalse(texts.contains("宋文军"), "a party left in clear in the body must not get a token in a header")
        XCTAssertTrue(texts.contains("李明"))
    }
}
