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
        // PERSON, COMPANY, and ADDRESS are owned by the LLM, never by this engine.
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
