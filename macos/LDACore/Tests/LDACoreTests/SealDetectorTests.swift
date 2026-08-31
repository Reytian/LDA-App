//
//  SealDetectorTests.swift
//  LDACoreTests
//
//  Tests for the deterministic SEAL (organization seal name) detector: a
//  closed anchor set of seal words plus a bounded backward walk that absorbs
//  the organization payload. The seal wording itself is boilerplate; the PII
//  is the organization name stamped into it, so an anchor with no payload
//  must yield ZERO detections.
//
//  Every golden hit asserts the exact surface text and that the UTF-16
//  offsets slice back to that surface. Pathological inputs pin linear-time
//  behavior per the address-detector incident (a single big CJK regex once
//  hung for minutes on a repeated-character run).
//
//  House rules: all comments and strings in English (fixture CONTENT may be
//  Chinese). No em-dash and no en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

final class SealDetectorTests: XCTestCase {

    private let engine = DeterministicEngine()

    // MARK: - Helpers

    /// Assert that every span's UTF-16 [start, end) range slices back to
    /// exactly span.text out of the original text.
    private func assertOffsetsSliceBack(
        _ spans: [Span],
        in text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let ns = text as NSString
        for span in spans {
            XCTAssertGreaterThanOrEqual(span.start, 0, "start in range", file: file, line: line)
            XCTAssertLessThanOrEqual(span.end, ns.length, "end in range", file: file, line: line)
            XCTAssertLessThanOrEqual(span.start, span.end, "start before end", file: file, line: line)
            let sliced = ns.substring(
                with: NSRange(location: span.start, length: span.end - span.start))
            XCTAssertEqual(
                sliced,
                span.text,
                "Offsets must slice back to the span surface text",
                file: file,
                line: line
            )
        }
    }

    /// The SEAL spans detected in the given text.
    private func sealSpans(in text: String) -> [Span] {
        engine.detect(text).filter { $0.type == .seal }
    }

    /// Assert the text yields exactly one SEAL span with the expected surface.
    private func assertSingleSeal(
        in text: String,
        equals expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let spans = sealSpans(in: text)
        XCTAssertEqual(
            spans.map { $0.text },
            [expected],
            "Expected exactly one SEAL span",
            file: file,
            line: line
        )
        assertOffsetsSliceBack(spans, in: text, file: file, line: line)
    }

    // MARK: - Golden hits

    /// The canonical positive: an organization name directly followed by a
    /// specialized seal word is ONE span covering the whole string.
    func testCompanyNameWithContractSealIsOneSpan() {
        assertSingleSeal(
            in: "北京某某科技有限公司合同专用章",
            equals: "北京某某科技有限公司合同专用章"
        )
    }

    /// The general seal word 公章 takes the same payload rule.
    func testCompanyNameWithGeneralSealIsOneSpan() {
        assertSingleSeal(in: "上海某某贸易有限公司公章", equals: "上海某某贸易有限公司公章")
    }

    /// Every anchor in the closed set detects with a company payload.
    func testEveryAnchorWordDetectsWithPayload() {
        let anchors = ["公章", "财务专用章", "合同专用章", "发票专用章", "业务专用章", "人事专用章"]
        for anchor in anchors {
            let text = "深圳某某实业公司" + anchor
            assertSingleSeal(in: text, equals: text)
        }
    }

    /// Every organization suffix in the closed set qualifies as a payload
    /// ending. Each fixture is punctuation-led so the span is the whole tail.
    func testEveryOrgSuffixQualifiesPayload() {
        let payloads = [
            "某某网络科技有限公司",
            "某某商业银行",
            "某某律师事务所",
            "某某市市场监督管理局",
            "某某村民委员会",
            "某某检测中心",
            "某某控股集团",
            "某某机械厂",
            "某某人民医院"
        ]
        for payload in payloads {
            let text = "见：" + payload + "公章"
            assertSingleSeal(in: text, equals: payload + "公章")
        }
    }

    /// Detection carries the deterministic source and the SEAL type constants.
    func testSealSpanMetadata() {
        let spans = sealSpans(in: "杭州某某信息技术有限公司财务专用章")
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].source, .deterministic)
        XCTAssertEqual(spans[0].type, .seal)
        XCTAssertGreaterThan(spans[0].priority, EntityLocator.llmPriority)
    }

    // MARK: - Boilerplate stays clear

    /// The canonical negative: seal wording with no organization payload is
    /// contract boilerplate and must yield zero detections.
    func testBareSealBoilerplateYieldsNothing() {
        XCTAssertTrue(sealSpans(in: "本合同经双方签字并加盖公章后生效。").isEmpty)
        XCTAssertTrue(sealSpans(in: "加盖公章后生效").isEmpty)
        XCTAssertTrue(sealSpans(in: "加盖发票专用章方可报销。").isEmpty)
        XCTAssertTrue(sealSpans(in: "公章").isEmpty)
        XCTAssertTrue(sealSpans(in: "合同专用章样式见附件。").isEmpty)
    }

    /// 公章 embedded in an unrelated word (办公章程, office charter) has no
    /// organization suffix immediately before it, so nothing is emitted.
    func testSealWordInsideUnrelatedWordYieldsNothing() {
        XCTAssertTrue(sealSpans(in: "详见本所办公章程第三条。").isEmpty)
    }

    /// A role label before the seal word is not an organization suffix, so
    /// party boilerplate stays clear (甲方公章 is everywhere in contracts).
    func testPartyLabelSealYieldsNothing() {
        XCTAssertTrue(sealSpans(in: "甲方公章：").isEmpty)
        XCTAssertTrue(sealSpans(in: "乙方合同专用章：").isEmpty)
    }

    /// A possessive 的 between the organization and the seal word breaks the
    /// payload adjacency; the organization itself stays LLM territory.
    func testPossessiveBreaksPayloadAdjacency() {
        XCTAssertTrue(sealSpans(in: "北京某某公司的公章由行政部保管。").isEmpty)
    }

    // MARK: - Walk boundaries

    /// Punctuation pins the left edge: the span starts after the colon.
    func testPunctuationStopsTheWalk() {
        assertSingleSeal(
            in: "盖章处：北京某某科技有限公司公章",
            equals: "北京某某科技有限公司公章"
        )
    }

    /// A Latin run stops the walk: the CJK tail is covered, the Latin name
    /// part stays out (same accepted limitation as the address walk).
    func testNonCJKStopsTheWalk() {
        assertSingleSeal(in: "ABC科技有限公司公章", equals: "科技有限公司公章")
    }

    /// A newline immediately before the anchor defeats the suffix adjacency,
    /// so a seal word on its own line is boilerplate.
    func testNewlineBeforeAnchorYieldsNothing() {
        XCTAssertTrue(sealSpans(in: "北京某某公司\n公章").isEmpty)
    }

    /// The walk is bounded: with an over-long CJK run before the suffix, the
    /// span keeps the trailing 30 UTF-16 units of payload plus the anchor.
    func testWalkIsBoundedToThirtyUnits() {
        let filler = String(repeating: "某", count: 40)
        let text = filler + "公司公章"
        let spans = sealSpans(in: text)
        XCTAssertEqual(spans.count, 1)
        // 30 payload units total: 28 filler characters plus the 2-unit suffix.
        XCTAssertEqual(spans[0].text, String(repeating: "某", count: 28) + "公司公章")
        assertOffsetsSliceBack(spans, in: text)
    }

    /// Absorbing leading CJK prose (加盖 and the like) into the payload is the
    /// ACCEPTED over-capture direction: the walk stops only at punctuation,
    /// whitespace, and non-CJK, because trimming by a prose stop list would
    /// truncate organization names that contain those characters, and a miss
    /// is a leak while over-covering is cosmetic.
    func testLeadingProseIsAbsorbedNotLeaked() {
        assertSingleSeal(
            in: "，加盖上海某某集团公章",
            equals: "加盖上海某某集团公章"
        )
    }

    /// Two seals in one line are two separate spans.
    func testTwoSealsYieldTwoSpans() {
        let text = "北京某公司公章、上海某银行财务专用章"
        let spans = sealSpans(in: text).sorted { $0.start < $1.start }
        XCTAssertEqual(spans.map { $0.text }, ["北京某公司公章", "上海某银行财务专用章"])
        assertOffsetsSliceBack(spans, in: text)
    }

    // MARK: - Merge priority

    /// When the LLM claims the company and the detector claims the company
    /// plus the seal word, the deterministic SEAL span wins the overlap and
    /// the whole surface is redacted once.
    func testSealBeatsLLMCompanyClaimOnMerge() {
        let text = "落款：北京某某科技有限公司合同专用章"
        let deterministic = engine.detect(text)
        let llm = EntityLocator.spans(
            forValue: "北京某某科技有限公司",
            type: .company,
            in: text
        )
        XCTAssertFalse(llm.isEmpty, "fixture must produce the competing company span")

        let merged = SpanMerger.merge(deterministic: deterministic, llm: llm)
        let overlapping = merged.filter { $0.text.contains("北京某某科技有限公司") }
        XCTAssertEqual(overlapping.map { $0.type }, [.seal])
        XCTAssertEqual(overlapping.map { $0.text }, ["北京某某科技有限公司合同专用章"])
    }

    // MARK: - Round trip

    /// Token-style anonymize plus restore over a seal fixture is
    /// byte-identical, and the redacted text carries a SEAL token.
    func testTokenStyleRoundTripIsByteIdentical() {
        let text = "落款：北京某某科技有限公司合同专用章。\n签订日期另行填写。"
        let spans = SpanMerger.merge(deterministic: engine.detect(text), llm: [])
        let tokenized = Tokenizer.tokenize(
            text: text,
            spans: spans,
            sourceFile: "seal-fixture.txt",
            createdAtISO8601: "2026-08-31T00:00:00Z"
        )

        XCTAssertTrue(tokenized.tokenizedText.contains("{SEAL_1}"))
        XCTAssertFalse(tokenized.tokenizedText.contains("北京某某科技有限公司"))

        let restored = Restorer.restore(text: tokenized.tokenizedText, mapping: tokenized.mapping)
        XCTAssertEqual(restored.text, text)
        XCTAssertTrue(restored.orphanTokens.isEmpty)
    }

    // MARK: - Wire and styling registration

    /// The defensive parser mapping recognizes the SEAL wire string even
    /// though SEAL is deterministic-only and absent from the prompt contract.
    func testEntityJSONParserMapsSealWireString() {
        let entities = EntityJSONParser.parse(
            #"{"entities":[{"value":"北京某公司公章","type":"SEAL"}]}"#
        )
        XCTAssertEqual(entities.count, 1)
        XCTAssertEqual(entities[0].type, .seal)
    }

    /// Pseudonym styling has explicit per-script seal entries following the
    /// generic-label scheme.
    func testSealPseudonymsFollowGenericLabelScheme() {
        var generator = PseudonymGenerator()
        let chinese = generator.mint(
            type: .seal,
            surface: "北京某公司公章",
            isTaken: { _ in false }
        )
        XCTAssertEqual(chinese, "某印章1")

        let latin = generator.mint(
            type: .seal,
            surface: "ACME CORP SEAL",
            isTaken: { _ in false }
        )
        XCTAssertEqual(latin, "Seal 1")
    }

    // MARK: - Pathological inputs stay linear

    /// Adversarial repeated-character runs must detect fast: the anchor set
    /// is literal and the payload walk is bounded, so nothing may backtrack.
    /// Mirrors the performance-guard pattern in RestorerSuspectTests.
    func testAdversarialInputsDetectFast() {
        // Warm the regex caches so the measurement sees scan time, not
        // one-time pattern compilation.
        _ = engine.detect("预热：北京某公司公章")

        let adversarialInputs = [
            String(repeating: "章", count: 200),
            "财务专用" + String(repeating: "章", count: 200),
            String(repeating: "司", count: 300) + "公章",
            String(repeating: "公司", count: 150) + "公章",
            String(repeating: "公章", count: 150),
            String(repeating: "委员会", count: 100) + "公章",
            String(repeating: "厂院局", count: 100) + "财务专用章"
        ]

        for input in adversarialInputs {
            let started = Date()
            _ = engine.detect(input)
            let elapsed = Date().timeIntervalSince(started)
            XCTAssertLessThan(
                elapsed,
                0.1,
                "detect must stay linear on a \(input.count) character adversarial input"
            )
        }
    }

    // MARK: - UI registration

    /// SEAL carries its own theme color, distinct from the fallback hue that
    /// date and unknown share, so sidebar dots and underlines identify it.
    @MainActor
    func testSealHasDistinctThemeColor() {
        XCTAssertNotEqual(
            CounselTheme.color(for: .seal),
            CounselTheme.color(for: .unknown)
        )
    }
}
