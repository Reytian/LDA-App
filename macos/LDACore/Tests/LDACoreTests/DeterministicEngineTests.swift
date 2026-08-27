//
//  DeterministicEngineTests.swift
//  LDACoreTests
//
//  Tests for DeterministicEngine. They assert detected entity types, exact
//  surface text, and that the UTF-16 offsets in every returned span slice back to
//  precisely that surface text out of the original string (as NSString).
//
//  The task mandates XCTest for this file, so this uses XCTest rather than the
//  Swift Testing framework.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class DeterministicEngineTests: XCTestCase {

    private let engine = DeterministicEngine()

    // MARK: - Helpers

    /// Assert that every span's UTF-16 [start, end) range slices back to exactly
    /// span.text out of the original text. This is the offset-integrity contract.
    private func assertOffsetsSliceBack(
        _ spans: [Span],
        in text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let ns = text as NSString
        for span in spans {
            XCTAssertGreaterThanOrEqual(span.start, 0, "start in range", file: file, line: line)
            XCTAssertLessThanOrEqual(
                span.end,
                ns.length,
                "end in range",
                file: file,
                line: line
            )
            XCTAssertLessThanOrEqual(
                span.start,
                span.end,
                "start before end",
                file: file,
                line: line
            )
            let sliced = ns.substring(with: NSRange(location: span.start, length: span.end - span.start))
            XCTAssertEqual(
                sliced,
                span.text,
                "Offsets must slice back to the span surface text",
                file: file,
                line: line
            )
        }
    }

    /// Find the first span of a given type whose surface text equals expected.
    private func firstSpan(
        _ spans: [Span],
        type: EntityType,
        text expected: String
    ) -> Span? {
        return spans.first { $0.type == type && $0.text == expected }
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
        let match = firstSpan(spans, type: type, text: expected)
        XCTAssertNotNil(
            match,
            "Expected a \(type.rawValue) span with text \"\(expected)\"; got \(spans.map { "\($0.type.rawValue):\($0.text)" })",
            file: file,
            line: line
        )
        return match ?? Span(
            start: 0,
            end: 0,
            type: .unknown,
            text: "",
            source: .deterministic,
            confidence: 0,
            priority: 0
        )
    }

    // MARK: - EMAIL

    func testEmailDetection() {
        let text = "Contact john.doe+legal@example.co.uk for the engagement letter."
        let spans = engine.detect(text)

        let span = assertHasSpan(spans, type: .email, text: "john.doe+legal@example.co.uk")
        XCTAssertEqual(span.source, .deterministic)
        XCTAssertEqual(span.priority, 80)
        XCTAssertEqual(span.confidence, 0.99, accuracy: 1e-9)
        assertOffsetsSliceBack(spans, in: text)
    }

    // MARK: - PHONE (Chinese mobile)

    func testChineseMobileDetection() {
        let text = "Reach the client at 13912345678 any time."
        let spans = engine.detect(text)

        let span = assertHasSpan(spans, type: .phone, text: "13912345678")
        XCTAssertEqual(span.priority, 60)
        XCTAssertEqual(span.confidence, 0.9, accuracy: 1e-9)
        assertOffsetsSliceBack(spans, in: text)
    }

    func testInternationalPhoneDetection() {
        let text = "Call +1 212 555 0147 to confirm."
        let spans = engine.detect(text)

        let phones = spans.filter { $0.type == .phone }
        XCTAssertFalse(phones.isEmpty, "Expected an international phone match")
        // The full international number should be one of the matches.
        XCTAssertTrue(
            phones.contains { $0.text == "+1 212 555 0147" },
            "Expected the full +CC grouped number; got \(phones.map { $0.text })"
        )
        assertOffsetsSliceBack(spans, in: text)
    }

    // MARK: - PHONE (broadened separators, LDA-SDS-03)

    /// Dotted separators (for example 212.555.1234) must be detected, not left in
    /// cleartext.
    func testDottedPhoneDetection() {
        let text = "Call me at 212.555.0147."
        let spans = engine.detect(text)

        let phones = spans.filter { $0.type == .phone }
        XCTAssertTrue(
            phones.contains { $0.text == "212.555.0147" },
            "Expected the dotted phone; got \(phones.map { $0.text })"
        )
        assertOffsetsSliceBack(spans, in: text)
    }

    /// A parenthesized area code with NO separator before the next group (for
    /// example (212)555-0147) must be detected.
    func testParenthesizedAreaCodeNoSeparatorPhoneDetection() {
        let text = "Call me at (212)555-0147."
        let spans = engine.detect(text)

        let phones = spans.filter { $0.type == .phone }
        XCTAssertTrue(
            phones.contains { $0.text == "(212)555-0147" },
            "Expected the parenthesized no-separator phone; got \(phones.map { $0.text })"
        )
        assertOffsetsSliceBack(spans, in: text)
    }

    /// An international number with a parenthesized area code must keep its +CC and
    /// be captured whole as one of the matches.
    func testInternationalParenthesizedPhoneKeepsCountryCode() {
        let text = "Reach +1 (212) 555-0147 now."
        let spans = engine.detect(text)

        let phones = spans.filter { $0.type == .phone }
        XCTAssertTrue(
            phones.contains { $0.text == "+1 (212) 555-0147" },
            "Expected the +CC parenthesized number whole; got \(phones.map { $0.text })"
        )
        assertOffsetsSliceBack(spans, in: text)
    }

    /// A fully dotted international number, e.g. 1.212.555.0147, must produce a
    /// phone match (the dotted body is captured).
    func testDottedInternationalPhoneDetection() {
        let text = "Dial 1.212.555.0147 to reach us."
        let spans = engine.detect(text)

        let phones = spans.filter { $0.type == .phone }
        XCTAssertFalse(phones.isEmpty, "Expected a phone match for a dotted number")
        assertOffsetsSliceBack(spans, in: text)
    }

    /// Section, version, date, and ratio strings must NOT be detected as phones.
    func testPhonePatternRejectsSectionVersionDateRatio() {
        for text in [
            "See section 5.1.2 of the agreement.",
            "Released as Version 1.2.3 today.",
            "Dated 2026-01-15 for the parties.",
            "The ratio was 3.14 overall.",
        ] {
            let spans = engine.detect(text)
            let phones = spans.filter { $0.type == .phone }
            XCTAssertTrue(
                phones.isEmpty,
                "Expected no phone match in \"\(text)\"; got \(phones.map { $0.text })"
            )
        }
    }

    // MARK: - NATIONAL_ID (身份证)

    func testValidNationalIDIsEmitted() {
        // 110101199003071233 is a checksum-valid Chinese resident ID.
        let text = "身份证号码：110101199003071233。"
        let spans = engine.detect(text)

        let span = assertHasSpan(spans, type: .nationalID, text: "110101199003071233")
        XCTAssertEqual(span.priority, 100, "National ID must carry the highest priority")
        XCTAssertEqual(span.confidence, 1.0, accuracy: 1e-9)
        XCTAssertEqual(span.source, .deterministic)
        assertOffsetsSliceBack(spans, in: text)
    }

    func testInvalidNationalIDIsNotEmitted() {
        // 110101199003071230 flips the final check digit from 3 to 0, breaking the
        // ISO-7064 mod-11-2 checksum. It must NOT be emitted as a NATIONAL_ID.
        let text = "身份证号码：110101199003071230。"
        let spans = engine.detect(text)

        XCTAssertFalse(
            spans.contains { $0.type == .nationalID },
            "A checksum-invalid 身份证 must not be emitted as NATIONAL_ID"
        )
        assertOffsetsSliceBack(spans, in: text)
    }

    func testNationalIDChecksumUnit() {
        XCTAssertTrue(DeterministicEngine.isValidChineseID("110101199003071233"))
        XCTAssertFalse(DeterministicEngine.isValidChineseID("110101199003071230"))
        // X check character (case-insensitive) and wrong length.
        XCTAssertFalse(DeterministicEngine.isValidChineseID("12345"))
    }

    func testNationalIDWinsOverDate() {
        // The valid ID contains the substring 19900307 which the DATE engine could
        // otherwise read as a slashed or ISO-ish date. The ID span at priority 100
        // must be present so SpanMerger can prefer it over any DATE candidate.
        let text = "ID 110101199003071233 on file."
        let spans = engine.detect(text)

        let idSpan = assertHasSpan(spans, type: .nationalID, text: "110101199003071233")
        // If any DATE span overlaps the ID, the ID priority must strictly dominate.
        let overlappingDates = spans.filter {
            $0.type == .date && $0.start < idSpan.end && $0.end > idSpan.start
        }
        for dateSpan in overlappingDates {
            XCTAssertGreaterThan(
                idSpan.priority,
                dateSpan.priority,
                "National ID priority must beat any overlapping DATE"
            )
        }
        assertOffsetsSliceBack(spans, in: text)
    }

    // MARK: - USCC

    func testUSCCStructureDetection() {
        // 91110108MA01C2K3X1 is a structurally valid (and checksum-valid) USCC.
        let text = "统一社会信用代码 91110108MA01C2K3X1 已登记。"
        let spans = engine.detect(text)

        let span = assertHasSpan(spans, type: .uscc, text: "91110108MA01C2K3X1")
        XCTAssertEqual(span.priority, 95)
        XCTAssertEqual(span.source, .deterministic)
        assertOffsetsSliceBack(spans, in: text)
    }

    func testUSCCChecksumUnit() {
        XCTAssertTrue(DeterministicEngine.isValidUSCC("91110108MA01C2K3X1"))
        XCTAssertTrue(DeterministicEngine.isValidUSCC("91350100M000100Y43"))
        XCTAssertTrue(DeterministicEngine.isValidUSCC("9144030071526726XG"))
    }

    // MARK: - BANK_ACCOUNT

    func testBankAccountRun() {
        let text = "Wire to account 6225880137766291 at the bank."
        let spans = engine.detect(text)

        let span = assertHasSpan(spans, type: .bankAccount, text: "6225880137766291")
        XCTAssertEqual(span.priority, 50)
        XCTAssertEqual(span.confidence, 0.85, accuracy: 1e-9)
        assertOffsetsSliceBack(spans, in: text)
    }

    // MARK: - DATE (ISO and Chinese)

    func testISODateDetection() {
        let text = "Effective 2024-01-01 per the contract."
        let spans = engine.detect(text)

        let span = assertHasSpan(spans, type: .date, text: "2024-01-01")
        XCTAssertEqual(span.priority, 40)
        XCTAssertEqual(span.confidence, 0.8, accuracy: 1e-9)
        assertOffsetsSliceBack(spans, in: text)
    }

    func testChineseDateDetection() {
        let text = "合同自2024年1月1日起生效。"
        let spans = engine.detect(text)

        let span = assertHasSpan(spans, type: .date, text: "2024年1月1日")
        XCTAssertEqual(span.type, .date)
        assertOffsetsSliceBack(spans, in: text)
    }

    // MARK: - DATE (English month names)

    func testLongFormMonthFirstDate() {
        // Exact reproduction of the reported bug: a written-out US long-form date
        // went undetected because detectDate carried only numeric and Chinese
        // shapes. DATE is deterministic-only (the LLM never emits it), so this
        // gap meant the date was never redacted.
        let text = "This Agreement is dated January 5, 2026 by the parties."
        let spans = engine.detect(text)

        let span = assertHasSpan(spans, type: .date, text: "January 5, 2026")
        XCTAssertEqual(span.priority, 40)
        XCTAssertEqual(span.confidence, 0.8, accuracy: 1e-9)
        XCTAssertEqual(span.source, .deterministic)
        assertOffsetsSliceBack(spans, in: text)
    }

    func testAbbreviatedMonthDate() {
        // Abbreviated month name with a trailing period.
        let text = "Closing occurred on Sept. 30, 2025 in New York."
        let spans = engine.detect(text)

        assertHasSpan(spans, type: .date, text: "Sept. 30, 2025")
        assertOffsetsSliceBack(spans, in: text)
    }

    func testMonthFirstDateWithOrdinalSuffix() {
        let text = "Delivered January 5th, 2026 to counsel."
        let spans = engine.detect(text)

        assertHasSpan(spans, type: .date, text: "January 5th, 2026")
        assertOffsetsSliceBack(spans, in: text)
    }

    func testDayFirstLongFormDate() {
        // European day-first order, no comma.
        let text = "Executed on 5 January 2026 in London."
        let spans = engine.detect(text)

        assertHasSpan(spans, type: .date, text: "5 January 2026")
        assertOffsetsSliceBack(spans, in: text)
    }

    func testBareMonthWordIsNotADate() {
        // Guard against over-redaction: a month word with no day and no
        // four-digit year must NOT be a DATE, or common prose (including the
        // verb "may") would be redacted. This passes before and after the fix.
        let text = "The parties may close in March of next year."
        let spans = engine.detect(text)

        XCTAssertFalse(
            spans.contains { $0.type == .date },
            "A bare month word must not be a DATE; got \(spans.filter { $0.type == .date }.map { $0.text })"
        )
        assertOffsetsSliceBack(spans, in: text)
    }

    // MARK: - DATE (month + year, legal "day of", European dotted)

    func testMonthAndYearOnlyDate() {
        // "Effective as of" clauses commonly carry a month and year with no day.
        let text = "The lease is effective as of January 2026 for all parties."
        let spans = engine.detect(text)

        assertHasSpan(spans, type: .date, text: "January 2026")
        assertOffsetsSliceBack(spans, in: text)
    }

    func testAbbreviatedMonthAndYearOnlyDate() {
        let text = "Renewal begins Sep. 2027 absent notice."
        let spans = engine.detect(text)

        assertHasSpan(spans, type: .date, text: "Sep. 2027")
        assertOffsetsSliceBack(spans, in: text)
    }

    func testLegalDayOfDate() {
        // The execution-block recital form, e.g. "this 5th day of January, 2026".
        let text = "Executed this 5th day of January, 2026 in New York."
        let spans = engine.detect(text)

        assertHasSpan(spans, type: .date, text: "5th day of January, 2026")
        assertOffsetsSliceBack(spans, in: text)
    }

    func testOfConnectorDate() {
        // The shorter "Day of Month Year" connector form.
        let text = "Dated the 5th of January 2026 by counsel."
        let spans = engine.detect(text)

        assertHasSpan(spans, type: .date, text: "5th of January 2026")
        assertOffsetsSliceBack(spans, in: text)
    }

    func testEuropeanDottedDate() {
        let text = "Signed 05.01.2026 in Frankfurt."
        let spans = engine.detect(text)

        assertHasSpan(spans, type: .date, text: "05.01.2026")
        assertOffsetsSliceBack(spans, in: text)
    }

    func testDottedReferenceWithoutYearIsNotADate() {
        // Guard: the dotted form requires a four-digit year, so a clause reference
        // like "Section 5.1.2" must NOT be read as a date.
        let text = "See Section 5.1.2 of the agreement."
        let spans = engine.detect(text)

        XCTAssertFalse(
            spans.contains { $0.type == .date },
            "A dotted reference without a four-digit year must not be a DATE; got \(spans.filter { $0.type == .date }.map { $0.text })"
        )
        assertOffsetsSliceBack(spans, in: text)
    }

    // MARK: - AMOUNT (RMB with 万)

    func testRMBAmountWithWan() {
        let text = "对价为人民币500万元整。"
        let spans = engine.detect(text)

        let amounts = spans.filter { $0.type == .amount }
        XCTAssertFalse(amounts.isEmpty, "Expected an AMOUNT match for the RMB value")
        // The matched amount must include the 万 magnitude unit.
        XCTAssertTrue(
            amounts.contains { $0.text.contains("万") },
            "Expected an amount carrying the 万 unit; got \(amounts.map { $0.text })"
        )
        let span = amounts.first { $0.text.contains("万") }!
        XCTAssertEqual(span.priority, 45)
        XCTAssertEqual(span.confidence, 0.8, accuracy: 1e-9)
        assertOffsetsSliceBack(spans, in: text)
    }

    func testPrefixedAmountWithThousands() {
        let text = "The fee is $1,250,000.50 upon closing."
        let spans = engine.detect(text)

        let span = assertHasSpan(spans, type: .amount, text: "$1,250,000.50")
        XCTAssertEqual(span.priority, 45)
        assertOffsetsSliceBack(spans, in: text)
    }

    // MARK: - AMOUNT (ISO currency codes, live recall gap 2026-08-27)

    /// Exact reproduction of the live-model recall gap: a code-prefixed amount
    /// like "GBP 45,000.00" stayed in cleartext because the AMOUNT pattern knew
    /// only ¥ $ € RMB USD 人民币. AMOUNT is deterministic-only (the LLM never
    /// emits it), so this gap meant the retainer leaked through anonymization.
    func testISOCurrencyCodeAmountDetection() {
        let text = "Signed on 2024-01-15 for a retainer of GBP 45,000.00."
        let spans = engine.detect(text)

        let span = assertHasSpan(spans, type: .amount, text: "GBP 45,000.00")
        XCTAssertEqual(span.priority, 45)
        XCTAssertEqual(span.confidence, 0.8, accuracy: 1e-9)
        XCTAssertEqual(span.source, .deterministic)
        assertOffsetsSliceBack(spans, in: text)
    }

    func testEuroCodePlainNumberAmount() {
        let text = "A filing fee of EUR 500 applies to the registration."
        let spans = engine.detect(text)

        assertHasSpan(spans, type: .amount, text: "EUR 500")
        assertOffsetsSliceBack(spans, in: text)
    }

    func testPoundSymbolAmount() {
        let text = "The deposit of £45,000 is due on signing."
        let spans = engine.detect(text)

        assertHasSpan(spans, type: .amount, text: "£45,000")
        assertOffsetsSliceBack(spans, in: text)
    }

    func testFullWidthYenSymbolAmount() {
        let text = "合同金额￥380,000.00已经支付。"
        let spans = engine.detect(text)

        assertHasSpan(spans, type: .amount, text: "￥380,000.00")
        assertOffsetsSliceBack(spans, in: text)
    }

    /// A plain ungrouped digit run after a code must be captured whole, not cut
    /// after three digits by the thousands-group shape.
    func testCodeAmountWithPlainDigitRun() {
        let text = "The fee of USD 45000 is payable at closing."
        let spans = engine.detect(text)

        assertHasSpan(spans, type: .amount, text: "USD 45000")
        assertOffsetsSliceBack(spans, in: text)
    }

    /// European formatting: dot-grouped thousands with a decimal comma.
    func testEuropeanFormattedAmount() {
        let text = "A purchase price of EUR 45.000,00 was agreed."
        let spans = engine.detect(text)

        assertHasSpan(spans, type: .amount, text: "EUR 45.000,00")
        assertOffsetsSliceBack(spans, in: text)
    }

    /// Guard against over-redaction: ISO codes that read as English words in
    /// prose (TRY, ALL, PHP, RON, TOP, PEN) are deliberately not currency
    /// prefixes, and a bare formatted number is never an AMOUNT.
    func testCurrencyCodeWordCollisionsAreNotAmounts() {
        for text in [
            "The parties shall TRY 3 times before termination.",
            "ALL 45,000 shares transfer at closing.",
            "The system requires PHP 8.1 or newer.",
            "Give Ron 500 of the documents.",
            "She placed in the TOP 10 of her class.",
            "Use PEN 2 for the signature page.",
        ] {
            let spans = engine.detect(text)
            let amounts = spans.filter { $0.type == .amount }
            XCTAssertTrue(
                amounts.isEmpty,
                "Expected no AMOUNT in \"\(text)\"; got \(amounts.map { $0.text })"
            )
        }
    }

    /// Guard: a code embedded in a longer token (BUSD, USDT) is not a currency
    /// prefix.
    func testCurrencyCodeInsideLongerTokenIsNotAnAmount() {
        let text = "Transfer 100 BUSD 200 tokens to the wallet."
        let spans = engine.detect(text)

        XCTAssertFalse(
            spans.contains { $0.type == .amount && $0.text.hasPrefix("USD") },
            "A code inside a longer token must not anchor an amount; got \(spans.filter { $0.type == .amount }.map { $0.text })"
        )
        assertOffsetsSliceBack(spans, in: text)
    }

    // MARK: - ADDRESS (Chinese street addresses, live recall gap 2026-08-27)

    /// Exact reproduction of the live-model recall gap: the v2 model does not
    /// extract Chinese street addresses, so 注册地址为上海市... stayed in
    /// cleartext. The deterministic engine now owns the high-precision Chinese
    /// street-address shape (admin division + road + number); fuzzy and
    /// non-Chinese addresses remain LLM territory.
    func testChineseRegisteredAddressDetection() {
        let text = "甲方：上海明川科技有限公司，注册地址为上海市浦东新区张江高科技园区碧波路690号。"
        let spans = engine.detect(text)

        let span = assertHasSpan(
            spans,
            type: .address,
            text: "上海市浦东新区张江高科技园区碧波路690号"
        )
        XCTAssertEqual(span.priority, 55)
        XCTAssertEqual(span.confidence, 0.9, accuracy: 1e-9)
        XCTAssertEqual(span.source, .deterministic)
        assertOffsetsSliceBack(spans, in: text)
    }

    /// The label 注册地址为 and 住址为 must NOT be absorbed into the span: the
    /// match starts at the place name, not at the prose connector.
    func testChineseAddressExcludesTheLeadingLabel() {
        let text = "乙方：王雨桐，身份证号 110101199003071233，住址为北京市朝阳区建国路88号。"
        let spans = engine.detect(text)

        assertHasSpan(spans, type: .address, text: "北京市朝阳区建国路88号")
        XCTAssertFalse(
            spans.contains { $0.type == .address && $0.text.contains("住址") },
            "The prose label must stay outside the address span"
        )
        // The national ID next to it must still be detected.
        assertHasSpan(spans, type: .nationalID, text: "110101199003071233")
        assertOffsetsSliceBack(spans, in: text)
    }

    /// Shanghai lane addresses: 路 N 弄 M 号.
    func testChineseAddressWithLane() {
        let text = "公司位于上海市静安区南京西路1266弄15号。"
        let spans = engine.detect(text)

        assertHasSpan(spans, type: .address, text: "上海市静安区南京西路1266弄15号")
        assertOffsetsSliceBack(spans, in: text)
    }

    /// Building, unit, and room suffixes after the street number are captured.
    func testChineseAddressWithBuildingUnits() {
        let text = "住所：北京市海淀区中关村南大街5号3号楼2单元801室，邮编100081。"
        let spans = engine.detect(text)

        assertHasSpan(spans, type: .address, text: "北京市海淀区中关村南大街5号3号楼2单元801室")
        assertOffsetsSliceBack(spans, in: text)
    }

    /// An area segment ending in 街道 sits between the administrative segments
    /// and the road. Two boundary characters then abut (外街道建国路), which a
    /// walk that demands a name character before every boundary dead-ends on,
    /// losing the whole address.
    func testChineseAddressWithJiedaoArea() {
        let text = "北京市朝阳区建国门外街道建国路88号"
        let spans = engine.detect(text)

        assertHasSpan(spans, type: .address, text: "北京市朝阳区建国门外街道建国路88号")
        assertOffsetsSliceBack(spans, in: text)
    }

    /// A village road puts a boundary character immediately before the road
    /// marker (小湾村路), leaving no room for a road name.
    func testChineseAddressWithVillageRoad() {
        let text = "上海市浦东新区唐镇小湾村路100号"
        let spans = engine.detect(text)

        assertHasSpan(spans, type: .address, text: "上海市浦东新区唐镇小湾村路100号")
        assertOffsetsSliceBack(spans, in: text)
    }

    /// Qingdao's 市南区 puts 市 directly before 市南区, so two boundary
    /// characters abut inside the administrative prefix.
    func testChineseAddressWithRepeatedBoundaryCharacters() {
        let text = "青岛市市南区香港中路12号"
        let spans = engine.detect(text)

        assertHasSpan(spans, type: .address, text: "青岛市市南区香港中路12号")
        assertOffsetsSliceBack(spans, in: text)
    }

    /// Administrative names run well past eight characters in practice, and a
    /// per-segment cap that short starts the span mid-name.
    func testChineseAddressWithLongAdministrativeName() {
        let text = "地址：郑州航空港经济综合实验区华夏大道1号。"
        let spans = engine.detect(text)

        assertHasSpan(spans, type: .address, text: "郑州航空港经济综合实验区华夏大道1号")
        assertOffsetsSliceBack(spans, in: text)
    }

    /// A Shanghai lane number is a complete address without a 号 at all.
    func testChineseAddressWithLaneAndNoStreetNumber() {
        let text = "注册地址为上海市静安区南京西路1266弄。"
        let spans = engine.detect(text)

        assertHasSpan(spans, type: .address, text: "上海市静安区南京西路1266弄")
        assertOffsetsSliceBack(spans, in: text)
    }

    /// Common road names may contain characters the first segment must exclude
    /// as prose connectors (和平路 carries 和).
    func testChineseAddressRoadNameWithConnectorCharacter() {
        let text = "地址：天津市和平区和平路120号。"
        let spans = engine.detect(text)

        assertHasSpan(spans, type: .address, text: "天津市和平区和平路120号")
        assertOffsetsSliceBack(spans, in: text)
    }

    /// An autonomous region carries the longest administrative prefixes.
    func testChineseAddressWithAutonomousRegion() {
        let text = "内蒙古自治区呼和浩特市赛罕区大学东街5号"
        let spans = engine.detect(text)

        assertHasSpan(spans, type: .address, text: "内蒙古自治区呼和浩特市赛罕区大学东街5号")
        assertOffsetsSliceBack(spans, in: text)
    }

    /// Without a lexicon the walk cannot tell where a place name starts, so
    /// prose that runs straight into an address with no punctuation and no
    /// connector is absorbed. That is accepted (over-redaction is cosmetic
    /// where a miss would be a leak), but it must stay BOUNDED so a whole
    /// paragraph is never swallowed by one address.
    func testAddressPrefixAbsorptionIsBounded() {
        let prose = String(repeating: "甲", count: 200)
        let text = prose + "上海市浦东新区碧波路690号"
        let spans = engine.detect(text)

        let addresses = spans.filter { $0.type == .address }
        XCTAssertEqual(addresses.count, 1, "expected exactly one address span")
        let span = addresses[0]
        XCTAssertTrue(
            span.text.hasSuffix("上海市浦东新区碧波路690号"),
            "the address itself must still be covered; got \(span.text)"
        )
        XCTAssertLessThanOrEqual(
            span.text.count,
            30 + "上海市浦东新区碧波路690号".count,
            "absorption must stay within the prefix bound; got \(span.text.count) characters"
        )
        assertOffsetsSliceBack(spans, in: text)
    }

    /// Guard against over-redaction: city mentions without a road and street
    /// number, and regulation numbers, are not addresses.
    func testChineseProseWithCityButNoStreetIsNotAnAddress() {
        for text in [
            "本协议适用上海市有关法规。",
            "合同在北京市签署。",
            "依据上海市人民政府令第52号执行。",
            "上海市市场监督管理局第9号文件另有规定。",
        ] {
            let spans = engine.detect(text)
            let addresses = spans.filter { $0.type == .address }
            XCTAssertTrue(
                addresses.isEmpty,
                "Expected no ADDRESS in \"\(text)\"; got \(addresses.map { $0.text })"
            )
        }
    }

    /// The backward walk does raw UTF-16 index arithmetic, so a surrogate pair
    /// next to an address must never leave a span boundary inside the pair.
    /// Splitting one would break the offset-integrity contract that the rest of
    /// the pipeline relies on, and a supplementary-plane CJK character
    /// (U+20BB7) is a real thing to find in a Chinese document.
    func testSupplementaryPlaneCharacterKeepsOffsetsIntact() {
        for text in [
            "\u{20BB7}市浦东新区碧波路690号",
            "住址为\u{20BB7}\u{20BB7}北京市朝阳区建国路88号。",
            "上海市浦东新区碧波路690号\u{20BB7}",
        ] {
            let spans = engine.detect(text)
            // The contract: whatever is detected, its offsets slice back
            // exactly, which cannot hold if a boundary lands mid-pair.
            assertOffsetsSliceBack(spans, in: text)
        }
    }

    /// Detection must stay linear on adversarial CJK input. The first version of
    /// the Chinese-address matcher nested a quantified name run inside a
    /// quantified segment chain, so a run of characters that can serve as both a
    /// name character and an administrative suffix (市) partitioned
    /// exponentially many ways and every partition failed at the road. A
    /// 20-character run did not finish in three minutes, which on an untrusted
    /// document is a hang rather than a slow scan.
    ///
    /// The budget is deliberately loose (five seconds for inputs that must take
    /// microseconds) so this fails only on a true blowup, never on a slow CI
    /// machine.
    func testAdversarialCJKRunsDoNotBlowUpDetection() {
        let inputs = [
            String(repeating: "市", count: 200),
            String(repeating: "市", count: 200) + "路",
            String(repeating: "区", count: 120) + "路号",
            String(repeating: "上海市浦东新区", count: 60),
            String(repeating: "省市区县镇乡村", count: 60),
            String(repeating: "北京市朝阳区建国路88号", count: 60),
            String(repeating: "9", count: 400),
            "北京市朝阳区建国路88号" + String(repeating: "1", count: 300),
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

    /// Guard: a bare road + number with no administrative segment stays LLM
    /// territory; the deterministic shape requires 省/市/区/县 context.
    func testBareRoadWithoutAdminSegmentIsNotDetected() {
        let text = "沿建国路88号方向前进。"
        let spans = engine.detect(text)

        XCTAssertFalse(
            spans.contains { $0.type == .address },
            "A road with no admin division must not match deterministically"
        )
        assertOffsetsSliceBack(spans, in: text)
    }

    // MARK: - Role-label suppression

    func testRoleLabelSuppression() {
        // "Buyer" is a role label. Even if some engine could surface it, the engine
        // drops any candidate whose trimmed text is a known role label. No
        // deterministic engine actually emits "Buyer", so the assertion is simply
        // that no span equals a role label.
        let text = "The Buyer shall pay the Seller. 甲方与乙方签署本协议。"
        let spans = engine.detect(text)

        for span in spans {
            XCTAssertFalse(
                RoleLabels.isRoleLabel(span.text),
                "No emitted span may be a role label; found \(span.text)"
            )
        }
        assertOffsetsSliceBack(spans, in: text)
    }

    func testPersonCompanyAddressNotDetected() {
        // PERSON and COMPANY are owned by the LLM, never by this engine. For
        // ADDRESS the engine owns only the Chinese street-address shape, so an
        // English address must still produce no deterministic span.
        let text = "John Smith of Acme Corporation at 100 Main Street, New York."
        let spans = engine.detect(text)

        for forbidden in [EntityType.person, .company, .address] {
            XCTAssertFalse(
                spans.contains { $0.type == forbidden },
                "Deterministic engine must not detect \(forbidden.rawValue)"
            )
        }
    }

    // MARK: - Bilingual EN + ZH snippet

    func testBilingualSnippet() {
        let text = """
        Engagement Letter. Client email: alice@law-firm.com, mobile 13800138000. \
        甲方身份证号码 110101199003071233，统一社会信用代码 91110108MA01C2K3X1。 \
        合同金额人民币200万元，签署日期 2024-03-15（2024年3月15日）。
        """
        let spans = engine.detect(text)

        // Every offset must slice back exactly, even across mixed-width characters.
        assertOffsetsSliceBack(spans, in: text)

        // The full bilingual mix of expected types should appear.
        assertHasSpan(spans, type: .email, text: "alice@law-firm.com")
        assertHasSpan(spans, type: .phone, text: "13800138000")
        assertHasSpan(spans, type: .nationalID, text: "110101199003071233")
        assertHasSpan(spans, type: .uscc, text: "91110108MA01C2K3X1")
        assertHasSpan(spans, type: .date, text: "2024-03-15")
        assertHasSpan(spans, type: .date, text: "2024年3月15日")

        XCTAssertTrue(
            spans.contains { $0.type == .amount && $0.text.contains("万") },
            "Expected an RMB amount with 万 in the bilingual snippet"
        )

        // The national ID priority must remain the maximum among emitted spans.
        let maxPriority = spans.map { $0.priority }.max() ?? 0
        let idSpan = firstSpan(spans, type: .nationalID, text: "110101199003071233")
        XCTAssertEqual(idSpan?.priority, maxPriority, "National ID must hold top priority")
    }

    // MARK: - Empty and no-match inputs

    func testEmptyTextYieldsNoSpans() {
        XCTAssertTrue(engine.detect("").isEmpty)
    }

    func testPlainProseYieldsNoStructuredPII() {
        let text = "This agreement sets out the obligations of the parties hereto."
        let spans = engine.detect(text)
        XCTAssertTrue(
            spans.allSatisfy { $0.type != .email && $0.type != .nationalID },
            "Plain prose should not yield email or national ID spans"
        )
        assertOffsetsSliceBack(spans, in: text)
    }
}
