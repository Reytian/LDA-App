//
//  StructuredEntityDetectorTests.swift
//  LDACoreTests
//
//  Tests for the four deterministic detectors added for the 2026-08-29 roadmap:
//  CASE_NUMBER (PRC court case numbers), LICENSE_PLATE (mainland plates),
//  WECHAT_ID (cue-gated WeChat account IDs), and URL (web addresses).
//
//  Every golden hit asserts the exact surface text and that the UTF-16 offsets
//  slice back to that surface (the offset-integrity contract). Near-miss guards
//  pin precision, merge tests document overlap precedence, and pathological
//  inputs pin linear-time behavior per the address-detector incident.
//
//  House rules: all comments and strings in English (fixture CONTENT may be
//  Chinese). No em-dash and no en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

final class StructuredEntityDetectorTests: XCTestCase {

    private let engine = DeterministicEngine()

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StructuredEntityDetectorTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir {
            try? FileManager.default.removeItem(at: workDir)
        }
    }

    // MARK: - Helpers

    /// Assert that every span's UTF-16 [start, end) range slices back to exactly
    /// span.text out of the original text.
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

    /// Assert a span of the given type and exact text exists, and return it.
    @discardableResult
    private func assertHasSpan(
        _ spans: [Span],
        type: EntityType,
        text expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Span {
        let match = spans.first { $0.type == type && $0.text == expected }
        XCTAssertNotNil(
            match,
            "Expected a \(type.rawValue) span with text \"\(expected)\"; got "
                + "\(spans.filter { $0.type == type }.map { $0.text })",
            file: file,
            line: line
        )
        return match ?? Span(
            start: 0, end: 0, type: type, text: "",
            source: .deterministic, confidence: 0, priority: 0
        )
    }

    /// Assert no span of the given type exists in the detection output.
    private func assertNoSpan(
        _ spans: [Span],
        type: EntityType,
        in text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let offenders = spans.filter { $0.type == type }
        XCTAssertTrue(
            offenders.isEmpty,
            "Expected no \(type.rawValue) in \"\(text)\"; got \(offenders.map { $0.text })",
            file: file,
            line: line
        )
    }

    // MARK: - CASE_NUMBER golden hits

    /// The canonical new-format civil first-instance case number with fullwidth
    /// parentheses, as printed by every PRC court since 2016. Leaving it in
    /// cleartext allows a reverse lookup of all parties on the judgment portal,
    /// so this is the single highest-value detection of the four.
    func testCaseNumberFullwidthCivilFirstInstance() {
        let text = "本院受理（2026）粤03民初12345号原告诉被告一案。"
        let spans = engine.detect(text)

        assertHasSpan(spans, type: .caseNumber, text: "（2026）粤03民初12345号")
        assertOffsetsSliceBack(spans, in: text)
    }

    /// Halfwidth parentheses and the Supreme People's Court code.
    func testCaseNumberHalfwidthSupremeCourt() {
        let text = "参见(2019)最高法民申1234号民事裁定书。"
        let spans = engine.detect(text)

        assertHasSpan(spans, type: .caseNumber, text: "(2019)最高法民申1234号")
        assertOffsetsSliceBack(spans, in: text)
    }

    /// Criminal second instance and a district court with a long numeric code.
    func testCaseNumberCriminalAndDistrictCourts() {
        let text = "被告人曾因（2020）京01刑终88号判决服刑，另涉（2018）沪0115民初5678号一案。"
        let spans = engine.detect(text)

        assertHasSpan(spans, type: .caseNumber, text: "（2020）京01刑终88号")
        assertHasSpan(spans, type: .caseNumber, text: "（2018）沪0115民初5678号")
        assertOffsetsSliceBack(spans, in: text)
    }

    /// Mixed fullwidth and halfwidth parentheses on the same number, which OCR
    /// and sloppy copy-paste both produce.
    func testCaseNumberMixedParentheses() {
        let text = "详见(2021）浙0102执恢123号及（2022)川01行终9号。"
        let spans = engine.detect(text)

        assertHasSpan(spans, type: .caseNumber, text: "(2021）浙0102执恢123号")
        assertHasSpan(spans, type: .caseNumber, text: "（2022)川01行终9号")
        assertOffsetsSliceBack(spans, in: text)
    }

    /// Enforcement, bankruptcy, preservation, and jurisdiction codes, plus the
    /// sub-case suffix 之二.
    func testCaseNumberSpecialtyCodesAndSubCaseSuffix() {
        let text = """
        执行案件（2020）京01执688号之二已终结。
        另有（2023）粤03破申56号、（2024）苏05财保102号、（2019）京民辖终23号在办。
        """
        let spans = engine.detect(text)

        assertHasSpan(spans, type: .caseNumber, text: "（2020）京01执688号之二")
        assertHasSpan(spans, type: .caseNumber, text: "（2023）粤03破申56号")
        assertHasSpan(spans, type: .caseNumber, text: "（2024）苏05财保102号")
        assertHasSpan(spans, type: .caseNumber, text: "（2019）京民辖终23号")
        assertOffsetsSliceBack(spans, in: text)
    }

    // MARK: - CASE_NUMBER near-miss guards

    /// A bare year, alone or in parentheses, is not a case number.
    func testBareYearIsNotACaseNumber() {
        for text in [
            "本合同于2026年签订。",
            "（2026）",
            "预算（2026）年度已批复。",
        ] {
            assertNoSpan(engine.detect(text), type: .caseNumber, in: text)
        }
    }

    /// Government document numbers share the （year）...号 silhouette but carry
    /// no court code plus case-type code between the year and the serial, so
    /// they must not match.
    func testGovernmentDocumentNumbersAreNotCaseNumbers() {
        for text in [
            "依据国办发（2016）12号文件执行。",
            "按沪府规（2020）12号的规定办理。",
            "上海市人民政府令第52号另有规定。",
        ] {
            assertNoSpan(engine.detect(text), type: .caseNumber, in: text)
        }
    }

    // MARK: - LICENSE_PLATE golden hits

    /// A standard blue plate, with and without the interpunct separator, and a
    /// driving-school plate with the trailing 学.
    func testStandardAndSchoolPlates() {
        let text = "肇事车辆京A12345与教练车川A·1234学发生碰撞。"
        let spans = engine.detect(text)

        assertHasSpan(spans, type: .licensePlate, text: "京A12345")
        assertHasSpan(spans, type: .licensePlate, text: "川A·1234学")
        assertOffsetsSliceBack(spans, in: text)
    }

    /// New-energy plates carry six tail characters that may include letters.
    func testNewEnergyPlates() {
        let text = "被告名下有粤B·AA0003号新能源汽车一辆，另租用沪AD12345。"
        let spans = engine.detect(text)

        assertHasSpan(spans, type: .licensePlate, text: "粤B·AA0003")
        assertHasSpan(spans, type: .licensePlate, text: "沪AD12345")
        assertOffsetsSliceBack(spans, in: text)
    }

    /// Police and trailer suffix characters.
    func testPoliceAndTrailerPlates() {
        let text = "警车京A1234警与挂车冀B5678挂均在现场。"
        let spans = engine.detect(text)

        assertHasSpan(spans, type: .licensePlate, text: "京A1234警")
        assertHasSpan(spans, type: .licensePlate, text: "冀B5678挂")
        assertOffsetsSliceBack(spans, in: text)
    }

    // MARK: - LICENSE_PLATE near-miss guards

    /// A province char plus a letter with no tail, or a too-short tail, is not
    /// a plate.
    func testTruncatedPlatesAreNotDetected() {
        for text in [
            "京A区域的车辆管理规定。",
            "京A12是内部编号。",
        ] {
            assertNoSpan(engine.detect(text), type: .licensePlate, in: text)
        }
    }

    /// GA36 excludes the letters I and O from the org letter, a 7-character
    /// tail is not a plate, and digit runs that are phone numbers or national
    /// IDs must not be claimed.
    func testPlateExclusionsAndEmbeddedRuns() {
        let excludedLetter = "京O12345专用号段另行管理。"
        assertNoSpan(engine.detect(excludedLetter), type: .licensePlate, in: excludedLetter)

        let tooLong = "编号京A1234567属于内部资产标签。"
        assertNoSpan(engine.detect(tooLong), type: .licensePlate, in: tooLong)

        let phone = "联系电话13812345678。"
        assertNoSpan(engine.detect(phone), type: .licensePlate, in: phone)

        let nationalID = "身份证号11010519491231002X。"
        assertNoSpan(engine.detect(nationalID), type: .licensePlate, in: nationalID)
    }

    // MARK: - WECHAT_ID golden hits

    /// Explicit label cues. Only the ID itself is captured, never the cue.
    func testWechatIDWithLabelCues() {
        let text = "原告微信号：zhang_san88，被告微信号为li4ye8888。"
        let spans = engine.detect(text)

        assertHasSpan(spans, type: .wechatID, text: "zhang_san88")
        assertHasSpan(spans, type: .wechatID, text: "li4ye8888")
        XCTAssertFalse(
            spans.contains { $0.type == .wechatID && $0.text.contains("微信") },
            "the cue must stay outside the captured span"
        )
        assertOffsetsSliceBack(spans, in: text)
    }

    /// Bare cues: 微信 with a colon, 微信 with no separator at all, and V信.
    func testWechatIDWithBareCues() {
        let text = "证人称加微信lawyer2026联系，亦可加V信:kk99aa88。"
        let spans = engine.detect(text)

        assertHasSpan(spans, type: .wechatID, text: "lawyer2026")
        assertHasSpan(spans, type: .wechatID, text: "kk99aa88")
        assertOffsetsSliceBack(spans, in: text)
    }

    /// Latin cues require a separator between the cue and the ID.
    func testWechatIDWithLatinCues() {
        let text = "Contact via WeChat: john-doe99 or vx：fa20260501 or weixin wangwu_666."
        let spans = engine.detect(text)

        assertHasSpan(spans, type: .wechatID, text: "john-doe99")
        assertHasSpan(spans, type: .wechatID, text: "fa20260501")
        assertHasSpan(spans, type: .wechatID, text: "wangwu_666")
        assertOffsetsSliceBack(spans, in: text)
    }

    /// The auto-generated wxid_ form is self-identifying and needs no cue.
    func testWxidFormNeedsNoCue() {
        let text = "该账户wxid_h7t3kq9p2f于2026年注册。"
        let spans = engine.detect(text)

        assertHasSpan(spans, type: .wechatID, text: "wxid_h7t3kq9p2f")
        assertOffsetsSliceBack(spans, in: text)
    }

    // MARK: - WECHAT_ID near-miss guards

    /// The bare ID shape is far too generic to match without a cue: an
    /// ordinary word that happens to be 6 to 20 chars must never be flagged.
    func testUncuedWordIsNotAWechatID() {
        for text in [
            "The herewith clause survives termination.",
            "本协议the parties另有约定。",
            "password字段另行加密存储。",
        ] {
            assertNoSpan(engine.detect(text), type: .wechatID, in: text)
        }
    }

    /// A Latin cue glued directly to a word is one token, not a cue plus an
    /// ID, and 微信 in a product-name compound must not fire either.
    func testGluedLatinCueAndProductNamesAreNotWechatIDs() {
        for text in [
            "VXSeries2000产品手册第3页。",
            "微信支付服务协议适用之。",
            "wechatpay相关条款见附件。",
        ] {
            assertNoSpan(engine.detect(text), type: .wechatID, in: text)
        }
    }

    /// IDs are 6 to 20 characters: a 5-character candidate and a 25-character
    /// run must both be rejected even when cued.
    func testWechatIDLengthBounds() {
        for text in [
            "微信：abc12短号无效。",
            "微信：abcdefghij0123456789abcde超长无效。",
        ] {
            assertNoSpan(engine.detect(text), type: .wechatID, in: text)
        }
    }

    // MARK: - URL golden hits

    /// Scheme-prefixed URLs with paths and queries.
    func testSchemeURLs() {
        let text = "判决书见https://www.court.gov.cn/zgcpwsw，附件在http://example.com/path?q=1&t=2下载。"
        let spans = engine.detect(text)

        assertHasSpan(spans, type: .url, text: "https://www.court.gov.cn/zgcpwsw")
        assertHasSpan(spans, type: .url, text: "http://example.com/path?q=1&t=2")
        assertOffsetsSliceBack(spans, in: text)
    }

    /// www-prefixed hosts and bare domains with supported TLDs, including
    /// multi-label endings like .com.cn and .gov.cn.
    func testWwwAndBareDomains() {
        let text = "详情见www.lawfirm.com.cn或example.org，备案信息载于beian.miit.gov.cn网站。"
        let spans = engine.detect(text)

        assertHasSpan(spans, type: .url, text: "www.lawfirm.com.cn")
        assertHasSpan(spans, type: .url, text: "example.org")
        assertHasSpan(spans, type: .url, text: "beian.miit.gov.cn")
        assertOffsetsSliceBack(spans, in: text)
    }

    /// Sentence punctuation right after a URL stays outside the span, for both
    /// path-bearing and bare forms.
    func testTrailingPunctuationStaysOutsideURL() {
        let text = "See https://example.com/page. Also (www.example.com) applies."
        let spans = engine.detect(text)

        assertHasSpan(spans, type: .url, text: "https://example.com/page")
        assertHasSpan(spans, type: .url, text: "www.example.com")
        assertOffsetsSliceBack(spans, in: text)
    }

    // MARK: - URL near-miss guards

    /// File names, version strings, clause references, and phone numbers do
    /// not become URLs. The TLD allowlist is the guard: .docx and .pdf are
    /// not TLDs, and numeric labels never end a domain.
    func testFileNamesAndVersionsAreNotURLs() {
        for text in [
            "附件example.docx已送达。",
            "The report.pdf was attached.",
            "升级到v2.5.1版本。",
            "依据合同第5.2条处理。",
            "电话13812345678接洽。",
            "See the http://. prefix convention.",
        ] {
            assertNoSpan(engine.detect(text), type: .url, in: text)
        }
    }

    // MARK: - Overlap and precedence through SpanMerger

    /// An email address must stay EMAIL and never be double-reported as a URL:
    /// the bare-domain pattern must not fire inside user@example.com, and the
    /// merged output keeps exactly the EMAIL span. A www host in the same
    /// sentence still becomes URL.
    func testEmailStaysEmailAndWwwBecomesURL() {
        let text = "请发送至user@example.com或访问www.example.com查询。"
        let raw = engine.detect(text)

        // Raw candidates: no URL span may overlap the email's range.
        let email = assertHasSpan(raw, type: .email, text: "user@example.com")
        let overlappingURL = raw.filter {
            $0.type == .url && $0.start < email.end && $0.end > email.start
        }
        XCTAssertTrue(
            overlappingURL.isEmpty,
            "no URL candidate may bite into an email; got \(overlappingURL.map { $0.text })"
        )

        // Merged output: the email survives as EMAIL, the www host as URL.
        let merged = SpanMerger.merge(deterministic: raw, llm: [])
        assertHasSpan(merged, type: .email, text: "user@example.com")
        assertHasSpan(merged, type: .url, text: "www.example.com")
        assertNoSpan(
            merged.filter { $0.start < email.end && $0.end > email.start && $0.type == .url },
            type: .url,
            in: text
        )
    }

    /// Precedence documentation: a case number wins any DATE or AMOUNT
    /// candidate inside its range after the merge, and a URL whose path
    /// contains a phone-shaped digit run wins the PHONE candidate. Real dates
    /// outside the case number are still reported.
    func testCaseNumberAndURLWinOverlapsAfterMerge() {
        let text = "（2026）粤03民初12345号立案于2026年3月5日，材料见https://example.com/13812345678。"
        let merged = SpanMerger.merge(deterministic: engine.detect(text), llm: [])

        let caseSpan = assertHasSpan(merged, type: .caseNumber, text: "（2026）粤03民初12345号")
        let insideCase = merged.filter {
            $0.start < caseSpan.end && $0.end > caseSpan.start && $0.type != .caseNumber
        }
        XCTAssertTrue(
            insideCase.isEmpty,
            "no other span may survive inside a case number; got \(insideCase.map { ($0.type.rawValue, $0.text) })"
        )

        assertHasSpan(merged, type: .date, text: "2026年3月5日")

        let urlSpan = assertHasSpan(merged, type: .url, text: "https://example.com/13812345678")
        let insideURL = merged.filter {
            $0.start < urlSpan.end && $0.end > urlSpan.start && $0.type != .url
        }
        XCTAssertTrue(
            insideURL.isEmpty,
            "the URL must win the phone candidate in its path; got \(insideURL.map { ($0.type.rawValue, $0.text) })"
        )
        assertOffsetsSliceBack(merged, in: text)
    }

    // MARK: - Tokenize and restore round trip

    /// Each new type mints its own token family and restores byte-identically.
    /// Token TYPE strings drop the underscore per TokenGrammar.sanitizeType,
    /// matching the existing NATIONAL_ID convention ({NATIONALID_N}).
    func testNewTypesTokenizeAndRestoreByteIdentically() {
        let text = """
        案号（2026）粤03民初12345号，肇事车辆京A12345。
        微信号：zhang_san88，证据发布于www.example.com。
        """
        let merged = SpanMerger.merge(deterministic: engine.detect(text), llm: [])
        let result = Tokenizer.tokenize(
            text: text,
            spans: merged,
            sourceFile: "fixture.txt",
            createdAtISO8601: "2026-01-01T00:00:00Z"
        )

        XCTAssertTrue(result.tokenizedText.contains("{CASENUMBER_1}"))
        XCTAssertTrue(result.tokenizedText.contains("{LICENSEPLATE_1}"))
        XCTAssertTrue(result.tokenizedText.contains("{WECHATID_1}"))
        XCTAssertTrue(result.tokenizedText.contains("{URL_1}"))

        for surface in ["（2026）粤03民初12345号", "京A12345", "zhang_san88", "www.example.com"] {
            XCTAssertFalse(
                result.tokenizedText.contains(surface),
                "surface \"\(surface)\" leaked into the tokenized text"
            )
        }

        let restored = Restorer.restore(text: result.tokenizedText, mapping: result.mapping)
        XCTAssertEqual(restored.text, text, "restore must be byte-identical")
        XCTAssertTrue(restored.orphanTokens.isEmpty)
    }

    // MARK: - Pathological inputs stay linear

    /// Adversarial repeated-char runs per detector must complete in well under
    /// the timeout. The budget is deliberately loose (five seconds for inputs
    /// that must take microseconds) so this fails only on a true blowup.
    func testPathologicalInputsCompleteFast() {
        let inputs = [
            // CASE_NUMBER: year followed by a long run of case-type chars, a
            // court code followed by digits with no terminal, repeated openers.
            "（2026）" + String(repeating: "民", count: 300),
            "（2026）粤03民初" + String(repeating: "9", count: 400),
            String(repeating: "（2026）粤03民初", count: 60),
            String(repeating: "（", count: 400),
            // LICENSE_PLATE: long digit tails and repeated province prefixes.
            "京A" + String(repeating: "1", count: 400),
            String(repeating: "京A1234", count: 80),
            // WECHAT_ID: cue followed by an over-long candidate, repeated cues,
            // and repeated separator characters.
            "微信：" + String(repeating: "a", count: 400),
            String(repeating: "微信：", count: 150),
            "微信" + String(repeating: "：", count: 300) + "abc123ok",
            String(repeating: "wxid_", count: 120),
            // URL: long label chains, dot runs, and an unbounded path.
            "www." + String(repeating: "a.", count: 300) + "com",
            String(repeating: ".", count: 500),
            String(repeating: "a.a", count: 200),
            "http://" + String(repeating: "a", count: 1000) + "/" + String(repeating: "b", count: 1000),
        ]

        for input in inputs {
            let finished = expectation(description: "detect returns for a \(input.count) char input")
            DispatchQueue.global().async {
                _ = self.engine.detect(input)
                finished.fulfill()
            }
            wait(for: [finished], timeout: 5.0)
        }
    }

    // MARK: - End-to-end through the public detect path

    /// A small mixed Chinese legal fixture through LDAService.detect with no
    /// model finds all four new types at offsets that slice back exactly.
    func testMixedFixtureThroughPublicDetectPath() throws {
        let text = """
        深圳市中级人民法院（2026）粤03民初12345号案件卷宗记载：
        被告驾驶粤B·AA0003经过现场，其微信号：zhang_san88曾发布信息，
        相关证据存档于https://www.court.gov.cn/zgcpwsw，联系邮箱user@example.com。
        """
        let inputURL = workDir.appendingPathComponent("mixed.txt")
        try Data(text.utf8).write(to: inputURL)

        let spans = try LDAService.detect(input: inputURL)

        assertHasSpan(spans, type: .caseNumber, text: "（2026）粤03民初12345号")
        assertHasSpan(spans, type: .licensePlate, text: "粤B·AA0003")
        assertHasSpan(spans, type: .wechatID, text: "zhang_san88")
        assertHasSpan(spans, type: .url, text: "https://www.court.gov.cn/zgcpwsw")
        assertHasSpan(spans, type: .email, text: "user@example.com")

        for span in spans {
            XCTAssertEqual(span.source, .deterministic)
        }
        assertOffsetsSliceBack(spans, in: text)
    }

    // MARK: - UI registration guard

    /// Every EntityType must appear in the sidebar's fixed group ordering, or
    /// detections of a missing type silently vanish from review.
    @MainActor
    func testEveryEntityTypeAppearsInSidebarGroupOrder() {
        for type in EntityType.allCases {
            XCTAssertTrue(
                ReviewModel.groupTypeOrder.contains(type),
                "EntityType.\(type.rawValue) is missing from ReviewModel.groupTypeOrder"
            )
        }
    }
}
