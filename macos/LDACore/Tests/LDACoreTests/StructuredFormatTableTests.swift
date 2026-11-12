//
//  StructuredFormatTableTests.swift
//  LDACoreTests
//
//  Review 2026-11-11, F7 and F8. The deterministic rules missed common
//  written forms of the values they exist to find: Chinese and French
//  amounts, amounts with the currency after the number or a magnitude word,
//  case numbers with spaces or in the pre-2016 form, foreign docket numbers,
//  several date, phone and identifier formats. Each was found by reading
//  real-world shapes against the patterns, one at a time. Neutral citations
//  of reported cases ([2024] HKCFI 1234) are left for the owner to decide.
//
//  This table states the formats instead: one row per type and locale, the
//  strings that must be found whole, and the near misses that must not be
//  found as that type. A missing format is a failing row.
//
//  Each string is checked inside a sentence of its locale, so the boundary
//  rules are exercised too, and must be covered end to end by one span of the
//  row's type (a span that leaves "US" or "million" visible fails).
//
//  Every value is invented.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class StructuredFormatTableTests: XCTestCase {

    struct Row {
        let type: EntityType
        let locale: String
        let mustMatch: [String]
        let nearMisses: [String]
    }

    /// The sentence each string is tested in, per locale.
    static func sentence(_ value: String, locale: String) -> String {
        switch locale {
        case "zh": return "根据约定，\(value)，双方确认。"
        case "fr": return "Selon le contrat, \(value), les parties confirment."
        default: return "Under the agreement, \(value), the parties confirm."
        }
    }

    static let rows: [Row] = [
        // MARK: AMOUNT (F7)
        Row(type: .amount, locale: "zh", mustMatch: [
            "8000元", "50000元", "100,000元整", "3000 元", "1,250,000.00 元", "5000万元", "12000万",
            "伍佰万元整", "壹拾贰万叁仟肆佰元", "五十万元", "100美元", "港币20,000元", "500万美元",
            "人民币伍佰万元整", "欧元1,500元", "人民币24,000元",
            // Full-width commas and full stops as separators (independent
            // review of F7, probe p09_amount_comma).
            "人民币5，000元整", "1，250，000.00元", "人民币50，000元", "￥12，000元",
            "人民币５，０００元整", "１，２５０，０００．００元", "RMB 5，000，000元", "USD 3，000，000",
            "港币20，000元", "5，000万元",
        ], nearMisses: ["第3条", "15%", "三元组", "一元化管理", "万元户", "第3，4条"]),
        Row(type: .amount, locale: "en", mustMatch: [
            "500,000 USD", "1,000 euros", "2.5 million dollars", "12,500 U.S. dollars", "US$1.2 million",
            "USD 3 billion", "EUR 3m", "RMB 5mn", "HK$3,500,000", "CAD$75,000", "$1.2 million", "A$20,000",
            "GBP 45,000.00",
        ], nearMisses: ["TRY 3 times", "PHP 8.1", "Section 3.1", "a 15% holdback", "version 2.5"]),
        Row(type: .amount, locale: "fr", mustMatch: [
            "12 500,00 €", "15 000 €", "1 250 000 euros", "12\u{00A0}500,00\u{00A0}€", "1\u{202F}250\u{202F}000 euros",
        ], nearMisses: ["article 12", "12 500 habitants"]),

        // MARK: CASE_NUMBER (F8). "cue|value": the cue stays visible.
        Row(type: .caseNumber, locale: "zh", mustMatch: [
            "(2023) 京0105民初1234号", "（2026）粤 03 民初 12345 号", "（2014）沪二中民二（民）终字第1234号",
            "(2012)民提字第123号", "（2023）京01民初123号",
        ], nearMisses: ["（2023）年度报告", "京政发（2023）12号", "(2023)第5号文件"]),
        Row(type: .caseNumber, locale: "en", mustMatch: [
            "No. |1:24-cv-01234", "Case |2:23-bk-12345", "Index No. |650123/2024", "Docket No. |A-1234-22",
            "HCA 1234/2023", "Case No. |1:24-cv-01234-ABC",
        ], nearMisses: ["Rule 12(b)(6)", "at 2:30 pm", "page 1/2", "No. 5", "Section 1:2"]),

        // MARK: DATE (F8)
        Row(type: .date, locale: "zh", mustMatch: [
            "2026.11.03", "2026年11月", "2026年11月3号", "二〇二七年十一月二日", "民國115年11月3日", "民国115年11月3日",
        ], nearMisses: ["第1.2.3条", "1.5.2版", "2026.13.45"]),
        Row(type: .date, locale: "en", mustMatch: ["03-07-1990"], nearMisses: ["1-2-3", "v2.10.3", "12-34-5678"]),
        Row(type: .date, locale: "fr", mustMatch: ["3 novembre 2026", "1er janvier 1985", "15 décembre 2026"],
            nearMisses: ["3 novembre", "article 3"]),

        // MARK: PHONE (F8)
        Row(type: .phone, locale: "zh", mustMatch: [
            "010-62551234", "(010)65551234", "0312-5551234", "（010）65551234",
            "\u{FF11}\u{FF13}\u{FF18}\u{FF10}\u{FF10}\u{FF11}\u{FF13}\u{FF18}\u{FF10}\u{FF10}\u{FF10}",
        ], nearMisses: ["2026-11-03", "1-2-3"]),
        Row(type: .phone, locale: "fr", mustMatch: ["01 42 68 53 00", "+33 6 12 34 56 78"],
            nearMisses: ["75002 Paris", "12 500 habitants"]),

        // MARK: NATIONAL_ID (F8)
        Row(type: .nationalID, locale: "zh", mustMatch: [
            "护照号码：|E12345678", "香港身份证：|A123456(7)", "台湾身分证：|A123456789", "港澳通行证：|C12345678",
            "旧身份证号：|110101900307451", "身份证号码：|110101199003074518",
            // A copula between label and value (independent review of F8).
            "护照号码为|E12345678", "护照号码是|E12345678",
        ], nearMisses: ["订单号：E12345678", "发票号码：110101900307451"]),
        Row(type: .nationalID, locale: "en", mustMatch: [
            "Passport No. |X12345678", "ITIN |912-34-5678", "SSN: |123 45 6789", "SSN |123456789",
            "passport number is |X12345678", "SSN was |123 45 6789",
        ], nearMisses: ["Order No. X12345678", "reference 912-34-5678", "order number is X12345678"]),

        // MARK: BANK_ACCOUNT (F8)
        Row(type: .bankAccount, locale: "en", mustMatch: [
            "IBAN |GB29 NWBK 6016 1331 9268 19", "IBAN |GB29NWBK60161331926819",
            "IBAN |FR76 3000 6000 0112 3456 7890 189", "Account no. |12345678",
            "account number is |12345678",
        ], nearMisses: ["invoice 12345678"]),
        Row(type: .bankAccount, locale: "zh", mustMatch: ["账号：|12345678", "银行账号：|6222020200012345678"],
            nearMisses: ["发票号码：12345678"]),
    ]

    // MARK: - The runner

    /// What the rules decide for `text`, overlaps resolved as the pipeline
    /// resolves them, so the TYPE a value ends up with is what is checked.
    static func detected(_ text: String) -> [Span] {
        SpanMerger.merge(deterministic: DeterministicEngine().detect(text), llm: [])
    }

    func testEveryRow() {
        for row in Self.rows {
            for item in row.mustMatch {
                // "cue|value": the cue is context, the value must be covered.
                let value = String(item.split(separator: "|").last ?? Substring(item))
                let text = Self.sentence(item.replacingOccurrences(of: "|", with: ""), locale: row.locale)
                let target = (text as NSString).range(of: value, options: .backwards)
                let covered = Self.detected(text).contains {
                    $0.type == row.type && $0.start <= target.location && $0.end >= NSMaxRange(target)
                }
                XCTAssertTrue(covered, "\(row.type.rawValue) [\(row.locale)] must find \(value.debugDescription) whole in: \(text) -> \(Self.detected(text).map { "\($0.type.rawValue):\($0.text)" })")
            }
            for value in row.nearMisses {
                let text = Self.sentence(value, locale: row.locale)
                let target = (text as NSString).range(of: value)
                let hit = Self.detected(text).contains {
                    $0.type == row.type && $0.start < NSMaxRange(target) && $0.end > target.location
                }
                XCTAssertFalse(hit, "\(row.type.rawValue) [\(row.locale)] must not find \(value.debugDescription) in: \(text)")
            }
        }
    }

    // MARK: - Enumerated amounts (second independent review of F7)

    /// The amounts detection finds in `text`, in order.
    static func amounts(in text: String) -> [String] {
        detected(text).filter { $0.type == .amount }.sorted { $0.start < $1.start }.map(\.text)
    }

    /// Probes t05 and q03: every full-width comma between digits was read as
    /// a thousands separator, so "1，000，2，000元" became the malformed
    /// "1,000,2,000元" no rule reads and stayed in clear, and "100，200，300元"
    /// became one amount. A full-width comma is a thousands separator only
    /// where it groups (three digits after it, one to three before, a first
    /// group of three only with a 000 group or a decimal part), and a currency
    /// written after the last of several enumerated numbers covers each of
    /// them.
    func testAmountsEnumeratedWithFullWidthCommasAreEachFound() {
        let cases: [(String, [String])] = [
            ("罚款分别为1，000，2，000元。", ["1，000", "2，000元"]),
            ("违约金为500，1，500元。", ["500", "1，500元"]),
            ("价格分别为100，200，300元。", ["100", "200", "300元"]),
            ("另付5，10，20元。", ["5", "10", "20元"]),
            ("费用为100、200、300元。", ["100", "200", "300元"]),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(Self.amounts(in: text), expected, text)
        }
    }

    func testThousandsGroupedWithFullWidthCommasStayOneAmount() {
        let cases: [(String, [String])] = [
            ("本合同涉及金额为1，250，000.00元；", ["1，250，000.00元"]),
            ("保证金为人民币50，000元整，", ["人民币50，000元整"]),
            ("赔偿100，000元。", ["100，000元"]),
            ("货款123，456．78元。", ["123，456．78元"]),
            ("共计１，２５０，０００元。", ["１，２５０，０００元"]),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(Self.amounts(in: text), expected, text)
        }
    }

    /// A long chain of three-digit runs is grouped in one pass: an
    /// adversarial document must not make detection quadratic.
    func testALongChainOfFullWidthCommasIsLinear() {
        let chain = Array(repeating: "100", count: 40_000).joined(separator: "，") + "元"
        let started = Date()
        _ = DeterministicEngine.patternView(of: chain)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the pattern view of a 40,000-run chain")
    }

    func testEnumeratedNumbersWithoutACurrencyAreNotAmounts() {
        for text in [
            "依据第1，2，3条，", "年度为2019，2020，2021年。", "编号1，2，3的附件共5，000页，",
            "面积1，200平方米，", "计12，500股，", "时间为2026年11月1，2日。",
        ] {
            XCTAssertEqual(Self.amounts(in: text), [], text)
        }
    }

    // MARK: - Beyond the table (F8)

    func testAModelReportedCaseNumberIsKept() {
        XCTAssertTrue(LLMExtractor.keptTypes.contains(.caseNumber),
                      "a case number the model reports is redacted, not discarded")
    }

    func testAnIdeographicSpaceInsideATwoCharacterNameStillAnchors() {
        let text = "甲方代表：张\u{3000}伟；乙方代表：张伟。"
        let spans = EntityLocator.spans(forValue: "张伟", type: .person, in: text)
        let padded = (text as NSString).range(of: "张\u{3000}伟")
        XCTAssertTrue(spans.contains { $0.start == padded.location && $0.end == NSMaxRange(padded) }, "\(spans.map(\.text))")
        XCTAssertEqual(spans.count, 2)
    }

    func testAnAddressRunsThroughALatinBuildingName() {
        let text = "房产地址：朝阳区建国路88号SOHO现代城A座1001；邮编100022。"
        let address = (text as NSString).range(of: "朝阳区建国路88号SOHO现代城A座1001")
        XCTAssertTrue(Self.detected(text).contains {
            $0.type == .address && $0.start <= address.location && $0.end >= NSMaxRange(address)
        }, "\(Self.detected(text).map { "\($0.type.rawValue):\($0.text)" })")
    }

    // MARK: - Amounts written twice

    func testAnAmountInWordsAndItsFigureAreBothFound() {
        let text = "转让价款为人民币伍佰万元整（¥5,000,000.00）。"
        let found = DeterministicEngine().detect(text).filter { $0.type == .amount }.map(\.text)
        XCTAssertTrue(found.contains("人民币伍佰万元整"), "\(found)")
        XCTAssertTrue(found.contains("¥5,000,000.00"), "\(found)")
    }
}
