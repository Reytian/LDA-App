//
//  TokenizerStyleTests.swift
//  LDACoreTests
//
//  Tests for style-aware tokenization: the .token default stays byte-identical
//  to the historical behavior, .pseudonym emits unique natural-language
//  stand-ins, and .asterisk emits per-type masked forms whose collisions are
//  preserved as distinct mapping entries.
//
//  House rules: all comments and strings in English. Fixture strings and
//  generated pseudonyms may be Chinese. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class TokenizerStyleTests: XCTestCase {

    private func span(
        _ text: String,
        in document: String,
        type: EntityType
    ) -> Span {
        let ns = document as NSString
        let range = ns.range(of: text)
        precondition(range.location != NSNotFound, "fixture span must exist")
        return Span(
            start: range.location,
            end: range.location + range.length,
            type: type,
            text: text,
            source: .manual,
            confidence: 1.0,
            priority: 10
        )
    }

    // MARK: - .token stays byte-identical

    func testTokenStyleMatchesHistoricalOutputByteForByte() {
        let document = "Seller: Acme Corp. Buyer: John Smith."
        let spans = [
            span("Acme Corp", in: document, type: .company),
            span("John Smith", in: document, type: .person)
        ]

        let historical = Tokenizer.tokenize(
            text: document,
            spans: spans,
            sourceFile: "doc.txt",
            createdAtISO8601: "2026-08-30T00:00:00Z"
        )
        let explicit = Tokenizer.tokenize(
            text: document,
            spans: spans,
            sourceFile: "doc.txt",
            createdAtISO8601: "2026-08-30T00:00:00Z",
            style: .token
        )

        XCTAssertEqual(historical.tokenizedText, "Seller: {COMPANY_1}. Buyer: {PERSON_1}.")
        XCTAssertEqual(explicit.tokenizedText, historical.tokenizedText)
        XCTAssertEqual(explicit.mapping, historical.mapping)
        XCTAssertEqual(explicit.mapping.style, .token)
    }

    // MARK: - .pseudonym

    func testPseudonymStyleEmitsNaturalLanguageStandIns() {
        let document = "出卖人：深圳创新科技有限公司。买受人：王小明。"
        let spans = [
            span("深圳创新科技有限公司", in: document, type: .company),
            span("王小明", in: document, type: .person)
        ]

        let result = Tokenizer.tokenize(
            text: document,
            spans: spans,
            sourceFile: "doc.txt",
            createdAtISO8601: "2026-08-30T00:00:00Z",
            style: .pseudonym
        )

        XCTAssertEqual(result.tokenizedText, "出卖人：甲公司。买受人：张某。")
        XCTAssertEqual(result.mapping.style, .pseudonym)

        // The mapping stores the emitted replacement per entity so restore
        // stays a deterministic literal scan.
        let byReplacement = Dictionary(
            uniqueKeysWithValues: result.mapping.entries.values.map { ($0.token, $0.value) }
        )
        XCTAssertEqual(byReplacement["甲公司"], "深圳创新科技有限公司")
        XCTAssertEqual(byReplacement["张某"], "王小明")
    }

    func testPseudonymNeverCollidesWithDocumentText() {
        // The document already contains the literal 甲公司 (a role reference),
        // so the company pseudonym must skip to 乙公司.
        let document = "甲公司条款适用。合同方：深圳创新科技有限公司。"
        let spans = [span("深圳创新科技有限公司", in: document, type: .company)]

        let result = Tokenizer.tokenize(
            text: document,
            spans: spans,
            sourceFile: "doc.txt",
            createdAtISO8601: "2026-08-30T00:00:00Z",
            style: .pseudonym
        )

        XCTAssertEqual(result.tokenizedText, "甲公司条款适用。合同方：乙公司。")
    }

    func testPseudonymsAreUniqueAcrossEntities() {
        let document = "买方 Acme Corp 与卖方 Beta LLC 及 王小明、李小红 签约。"
        let spans = [
            span("Acme Corp", in: document, type: .company),
            span("Beta LLC", in: document, type: .company),
            span("王小明", in: document, type: .person),
            span("李小红", in: document, type: .person)
        ]

        let result = Tokenizer.tokenize(
            text: document,
            spans: spans,
            sourceFile: "doc.txt",
            createdAtISO8601: "2026-08-30T00:00:00Z",
            style: .pseudonym
        )

        let replacements = result.mapping.entries.values.map { $0.token }
        XCTAssertEqual(Set(replacements).count, replacements.count, "every entity gets a distinct pseudonym")
        XCTAssertEqual(result.tokenizedText, "买方 Company A 与卖方 Company B 及 张某、李某 签约。")
    }

    func testPseudonymRepeatedSurfaceReusesOnePseudonym() {
        let document = "王小明签字。王小明确认。"
        let ns = document as NSString
        let first = ns.range(of: "王小明")
        let second = ns.range(of: "王小明", options: [], range: NSRange(location: first.location + first.length, length: ns.length - first.location - first.length))
        let spans = [
            Span(start: first.location, end: first.location + first.length, type: .person, text: "王小明", source: .manual, confidence: 1, priority: 10),
            Span(start: second.location, end: second.location + second.length, type: .person, text: "王小明", source: .manual, confidence: 1, priority: 10)
        ]

        let result = Tokenizer.tokenize(
            text: document,
            spans: spans,
            sourceFile: "doc.txt",
            createdAtISO8601: "2026-08-30T00:00:00Z",
            style: .pseudonym
        )

        XCTAssertEqual(result.tokenizedText, "张某签字。张某确认。")
        XCTAssertEqual(result.mapping.entries.count, 1)
    }

    func testPseudonymSeedOfSameStyleIsReused() {
        let seedEntry = MappingEntry(
            token: "张某",
            value: "王小明",
            type: .person,
            surfaceText: "王小明",
            aliases: []
        )
        let seed = Mapping(
            entries: [seedEntry.token: seedEntry],
            createdAtISO8601: "2026-08-29T00:00:00Z",
            sourceFile: "prior.txt",
            style: .pseudonym
        )

        let document = "由王小明与李小红共同签署。"
        let spans = [
            span("王小明", in: document, type: .person),
            span("李小红", in: document, type: .person)
        ]

        let result = Tokenizer.tokenize(
            text: document,
            spans: spans,
            sourceFile: "doc.txt",
            createdAtISO8601: "2026-08-30T00:00:00Z",
            seedMapping: seed,
            style: .pseudonym
        )

        // The known surface keeps its pseudonym; the new one avoids it.
        XCTAssertEqual(result.tokenizedText, "由张某与李某共同签署。")
        XCTAssertEqual(result.mapping.entries.count, 2)
    }

    func testTokenStyleSeedIsNotReusedInPseudonymDocument() {
        // A client mapping built in token style seeds a pseudonym session:
        // the brace token must NOT leak into the pseudonym document. A fresh
        // pseudonym is minted for the known surface, and the seed entry is
        // still carried in the union so earlier documents keep restoring.
        let seedEntry = MappingEntry(
            token: "{PERSON_1}",
            value: "王小明",
            type: .person,
            surfaceText: "王小明",
            aliases: []
        )
        let seed = Mapping(
            entries: [seedEntry.token: seedEntry],
            createdAtISO8601: "2026-08-29T00:00:00Z",
            sourceFile: "prior.txt",
            style: .token
        )

        let document = "由王小明签署。"
        let spans = [span("王小明", in: document, type: .person)]

        let result = Tokenizer.tokenize(
            text: document,
            spans: spans,
            sourceFile: "doc.txt",
            createdAtISO8601: "2026-08-30T00:00:00Z",
            seedMapping: seed,
            style: .pseudonym
        )

        XCTAssertEqual(result.tokenizedText, "由张某签署。")
        XCTAssertFalse(result.tokenizedText.contains("{PERSON_1}"))
        // Union carries both the old token entry and the new pseudonym entry.
        XCTAssertEqual(result.mapping.entries.count, 2)
        XCTAssertNotNil(result.mapping.entries["{PERSON_1}"])
        let pseudonymEntry = result.mapping.entries.values.first { $0.token == "张某" }
        XCTAssertEqual(pseudonymEntry?.value, "王小明")
    }

    // MARK: - .asterisk

    func testAsteriskStyleEmitsMaskedForms() {
        let document = "联系人张伟明，电话13812345678。"
        let spans = [
            span("张伟明", in: document, type: .person),
            span("13812345678", in: document, type: .phone)
        ]

        let result = Tokenizer.tokenize(
            text: document,
            spans: spans,
            sourceFile: "doc.txt",
            createdAtISO8601: "2026-08-30T00:00:00Z",
            style: .asterisk
        )

        XCTAssertEqual(result.tokenizedText, "联系人张*明，电话138****5678。")
        XCTAssertEqual(result.mapping.style, .asterisk)
    }

    func testAsteriskCollisionKeepsBothEntriesDistinctlyKeyed() {
        // 张三 and 张万 both mask to 张*. Both entities must be recorded, so
        // the mapping keeps two entries whose replacement strings are equal
        // but whose keys differ.
        let document = "证人张三与证人张万到场。"
        let spans = [
            span("张三", in: document, type: .person),
            span("张万", in: document, type: .person)
        ]

        let result = Tokenizer.tokenize(
            text: document,
            spans: spans,
            sourceFile: "doc.txt",
            createdAtISO8601: "2026-08-30T00:00:00Z",
            style: .asterisk
        )

        XCTAssertEqual(result.tokenizedText, "证人张*与证人张*到场。")
        XCTAssertEqual(result.mapping.entries.count, 2)
        let values = Set(result.mapping.entries.values.map { $0.value })
        XCTAssertEqual(values, ["张三", "张万"])
        let replacements = Set(result.mapping.entries.values.map { $0.token })
        XCTAssertEqual(replacements, ["张*"])
    }
}
