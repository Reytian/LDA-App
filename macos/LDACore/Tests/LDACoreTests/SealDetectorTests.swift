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

    /// Common PRC seal signers the original closed set missed. Each is a real
    /// stamping body, so without its suffix the whole seal stays undetected.
    func testExtendedOrgSuffixesQualifyPayload() {
        let payloads = [
            "中国某某银行北京分行",
            "中国某某银行某某支行",
            "某某市某某区人民政府",
            "某某省财政厅",
            "某某新闻出版社",
            "某某市消费者协会",
            "某某市工商业联合会",
            "某某市商会",
            "某某公司工会",
            "某某标准化学会",
            "某某教育基金会",
            "某某大学",
            "某某实验学校",
            "某某市第一中学",
            "某某区中心小学",
            "某某集团北京办事处",
            "某某电力科学研究所",
            "某某市某某派出所"
        ]
        for payload in payloads {
            let text = "见：" + payload + "公章"
            assertSingleSeal(in: text, equals: payload + "公章")
        }
    }

    /// Bare 所, 会, 学, and 处 are deliberately ABSENT from the suffix set:
    /// 本所, 开会, and 盖章处 are ordinary words, and admitting the bare form
    /// would mint a seal span over pure boilerplate. Only the explicit
    /// 事务所 / 研究所 / 派出所, 协会 / 商会 / 工会 / 学会 / 基金会 / 联合会,
    /// 大学 / 中学 / 小学 / 学校, and 办事处 forms qualify.
    func testBareSuffixLookalikesStayClear() {
        XCTAssertTrue(sealSpans(in: "本所公章由主任保管。").isEmpty)
        XCTAssertTrue(sealSpans(in: "开会公章未带。").isEmpty)
        XCTAssertTrue(sealSpans(in: "盖章处公章由前台保管。").isEmpty)
        XCTAssertTrue(sealSpans(in: "本条所有公章均须登记。").isEmpty)
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

    /// A Latin or digit initial belongs to the organization name, so the walk
    /// absorbs it. Truncating there used to emit a span covering only the CJK
    /// tail, and the uncovered initial then survived into the redacted file.
    func testLatinInitialIsAbsorbedByTheWalk() {
        assertSingleSeal(in: "ABC科技有限公司公章", equals: "ABC科技有限公司公章")
        assertSingleSeal(in: "3M中国有限公司公章", equals: "3M中国有限公司公章")
        assertSingleSeal(in: "TCL集团股份有限公司公章", equals: "TCL集团股份有限公司公章")
    }

    /// Absorbing Latin and digits does not weaken the other stops: symbols,
    /// whitespace, and CJK punctuation still pin the left edge.
    func testSymbolsAndWhitespaceStillStopTheWalk() {
        assertSingleSeal(in: "见/ABC科技有限公司公章", equals: "ABC科技有限公司公章")
        assertSingleSeal(in: "见 ABC科技有限公司公章", equals: "ABC科技有限公司公章")
        assertSingleSeal(in: "（ABC科技有限公司公章）", equals: "ABC科技有限公司公章")
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

    /// The named boilerplate case: 经办部门为总公司公章 carries no organization
    /// name at all, yet the walk absorbs the lead-in and emits a span. Left as
    /// is DELIBERATELY, and pinned here so the decision stays explicit. Every
    /// character that could act as a stop (为, 门, 部, 办, 经) is a legal name
    /// character somewhere else, so a stop list would truncate real names, and
    /// a truncated name is exactly the leak this detector must not produce.
    /// The cost is a redundant review row, which a human clears in one click.
    func testBoilerplateOverCaptureIsAcceptedNotTightened() {
        assertSingleSeal(in: "经办部门为总公司公章", equals: "经办部门为总公司公章")
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

    // MARK: - The redacted OUTPUT must not leak the organization name

    /// Anonymize a fixture the way the CLI does: deterministic detections plus
    /// the LLM company claim, merged, then tokenized. Returns the redacted text
    /// and the restored text so a test can assert on both.
    private func redactAndRestore(
        _ text: String,
        llmCompany: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> (redacted: String, restored: String) {
        let llm = EntityLocator.spans(forValue: llmCompany, type: .company, in: text)
        XCTAssertFalse(
            llm.isEmpty,
            "fixture must produce the competing company span",
            file: file,
            line: line
        )
        let spans = SpanMerger.merge(deterministic: engine.detect(text), llm: llm)
        let tokenized = Tokenizer.tokenize(
            text: text,
            spans: spans,
            sourceFile: "seal-leak-fixture.txt",
            createdAtISO8601: "2026-08-31T00:00:00Z"
        )
        let restored = Restorer.restore(text: tokenized.tokenizedText, mapping: tokenized.mapping)
        return (tokenized.tokenizedText, restored.text)
    }

    /// The shipped regression, asserted on the OUTPUT TEXT. A truncated SEAL
    /// span evicted the wider COMPANY span, so the uncovered organization
    /// prefix survived into the file handed to an AI. Span types and counts all
    /// looked right while this leaked, so only an output assertion catches it.
    func testOrganizationInitialsNeverReachRedactedText() {
        let fixtures: [(text: String, company: String, redLine: String)] = [
            ("落款：ABC科技有限公司公章。\n经办人：王小明。\n", "ABC科技有限公司", "ABC"),
            ("落款：3M中国有限公司公章。\n", "3M中国有限公司", "3M"),
            ("落款：TCL集团股份有限公司公章。\n", "TCL集团股份有限公司", "TCL")
        ]
        for fixture in fixtures {
            let output = redactAndRestore(fixture.text, llmCompany: fixture.company)
            XCTAssertFalse(
                output.redacted.contains(fixture.redLine),
                "leaked \(fixture.redLine) into: \(output.redacted)"
            )
            XCTAssertFalse(
                output.redacted.contains(fixture.company),
                "leaked the whole name into: \(output.redacted)"
            )
            XCTAssertEqual(output.restored, fixture.text, "restore must stay byte-identical")
        }
    }

    /// A registered name longer than the payload bound: the walk can only reach
    /// its tail, so the merge has to keep the LLM company claim's extra
    /// coverage or the most identifying head of the name leaks.
    func testOverlongOrganizationNameNeverReachesRedactedText() {
        let company =
            "中国某某石油化工集团有限责任公司北京燕山分公司石油化工科学研究院技术开发中心"
        let text = "用印单位：" + company + "公章。\n"
        let output = redactAndRestore(text, llmCompany: company)
        XCTAssertFalse(
            output.redacted.contains("中国某某石油化工"),
            "leaked the name head into: \(output.redacted)"
        )
        XCTAssertFalse(output.redacted.contains("燕山"), "leaked into: \(output.redacted)")
        XCTAssertEqual(output.restored, text, "restore must stay byte-identical")
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
            String(repeating: "厂院局", count: 100) + "财务专用章",
            // The walk now absorbs Latin and digits, so their runs are
            // adversarial input too.
            String(repeating: "A", count: 300) + "公司公章",
            String(repeating: "9", count: 300) + "公司公章",
            String(repeating: "分行", count: 150) + "公章",
            String(repeating: "研究所", count: 100) + "公章",
            String(repeating: "办事处", count: 100) + "财务专用章"
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
