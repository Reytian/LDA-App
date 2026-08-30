//
//  RestorerStyleTests.swift
//  LDACoreTests
//
//  Tests for style-aware restore: the pseudonym byte-identical round trip,
//  the per-style report semantics (orphans are mapping replacements missing
//  from the text), asterisk ambiguity refusal, and the headline AI-rewrite
//  robustness comparison against the token baseline.
//
//  House rules: all comments and strings in English. Fixture strings and
//  generated pseudonyms may be Chinese. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class RestorerStyleTests: XCTestCase {

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

    private func entry(
        replacement: String,
        value: String,
        type: EntityType
    ) -> MappingEntry {
        MappingEntry(
            token: replacement,
            value: value,
            type: type,
            surfaceText: value,
            aliases: []
        )
    }

    // MARK: - Pseudonym round trip

    func testPseudonymRoundTripIsByteIdentical() {
        let document = "出卖人：深圳创新科技有限公司（下称卖方）。买受人：王小明，电话13812345678，于2026年3月18日签署。"
        let spans = [
            span("深圳创新科技有限公司", in: document, type: .company),
            span("王小明", in: document, type: .person),
            span("13812345678", in: document, type: .phone),
            span("2026年3月18日", in: document, type: .date)
        ]

        let tokenized = Tokenizer.tokenize(
            text: document,
            spans: spans,
            sourceFile: "doc.txt",
            createdAtISO8601: "2026-08-30T00:00:00Z",
            style: .pseudonym
        )
        XCTAssertFalse(tokenized.tokenizedText.contains("深圳创新科技有限公司"))
        XCTAssertFalse(tokenized.tokenizedText.contains("王小明"))

        let restored = Restorer.restore(text: tokenized.tokenizedText, mapping: tokenized.mapping)
        XCTAssertEqual(restored.text, document)
        XCTAssertEqual(restored.restoredCount, 4)
        XCTAssertTrue(restored.orphanTokens.isEmpty)
        XCTAssertTrue(restored.ambiguousReplacements.isEmpty)
        XCTAssertTrue(restored.suspectPlaceholders.isEmpty)
    }

    func testTokenRoundTripStillByteIdenticalViaStyleDispatch() {
        let document = "Seller: Acme Corp. Buyer: John Smith."
        let spans = [
            span("Acme Corp", in: document, type: .company),
            span("John Smith", in: document, type: .person)
        ]
        let tokenized = Tokenizer.tokenize(
            text: document,
            spans: spans,
            sourceFile: "doc.txt",
            createdAtISO8601: "2026-08-30T00:00:00Z",
            style: .token
        )
        let restored = Restorer.restore(text: tokenized.tokenizedText, mapping: tokenized.mapping)
        XCTAssertEqual(restored.text, document)
        XCTAssertEqual(restored.restoredCount, 2)
    }

    // MARK: - Pseudonym report semantics

    func testPseudonymOrphanIsAMappingReplacementMissingFromText() {
        // The AI dropped the sentence containing 张某 entirely. That
        // replacement is now unrecoverable from this text, and the report
        // must say so.
        let kept = entry(replacement: "甲公司", value: "Acme Corp", type: .company)
        let dropped = entry(replacement: "张某", value: "王小明", type: .person)
        let mapping = Mapping(
            entries: [kept.token: kept, dropped.token: dropped],
            createdAtISO8601: "2026-08-30T00:00:00Z",
            sourceFile: "doc.txt",
            style: .pseudonym
        )

        let restored = Restorer.restore(text: "合同方：甲公司。", mapping: mapping)
        XCTAssertEqual(restored.text, "合同方：Acme Corp。")
        XCTAssertEqual(restored.restoredCount, 1)
        XCTAssertEqual(restored.orphanTokens, ["张某"])
    }

    func testPseudonymLongestReplacementWinsAtSamePosition() {
        // 某地址A is a prefix of 某地址AA. The scan must prefer the longest
        // replacement at a position so nested pseudonyms restore correctly.
        let short = entry(replacement: "某地址A", value: "1 Main St", type: .address)
        let long = entry(replacement: "某地址AA", value: "27 Long Rd", type: .address)
        let mapping = Mapping(
            entries: [short.token: short, long.token: long],
            createdAtISO8601: "2026-08-30T00:00:00Z",
            sourceFile: "doc.txt",
            style: .pseudonym
        )

        let restored = Restorer.restore(text: "送达：某地址AA；抄送：某地址A。", mapping: mapping)
        XCTAssertEqual(restored.text, "送达：27 Long Rd；抄送：1 Main St。")
        XCTAssertEqual(restored.restoredCount, 2)
        XCTAssertTrue(restored.orphanTokens.isEmpty)
    }

    func testPseudonymRestoreSurvivesReorderingAndDuplication() {
        // An AI rewrite may move and repeat pseudonyms. Every occurrence
        // restores because the scan is a literal scan over the whole text.
        let company = entry(replacement: "甲公司", value: "Acme Corp", type: .company)
        let mapping = Mapping(
            entries: [company.token: company],
            createdAtISO8601: "2026-08-30T00:00:00Z",
            sourceFile: "doc.txt",
            style: .pseudonym
        )
        let restored = Restorer.restore(
            text: "甲公司应赔偿。若甲公司迟延，则甲公司承担利息。",
            mapping: mapping
        )
        XCTAssertEqual(restored.text, "Acme Corp应赔偿。若Acme Corp迟延，则Acme Corp承担利息。")
        XCTAssertEqual(restored.restoredCount, 3)
    }

    // MARK: - Asterisk restore semantics

    func testAsteriskUniqueMaskRestores() {
        let document = "联系人张伟明，电话13812345678。"
        let spans = [
            span("张伟明", in: document, type: .person),
            span("13812345678", in: document, type: .phone)
        ]
        let tokenized = Tokenizer.tokenize(
            text: document,
            spans: spans,
            sourceFile: "doc.txt",
            createdAtISO8601: "2026-08-30T00:00:00Z",
            style: .asterisk
        )
        let restored = Restorer.restore(text: tokenized.tokenizedText, mapping: tokenized.mapping)
        XCTAssertEqual(restored.text, document)
        XCTAssertEqual(restored.restoredCount, 2)
        XCTAssertTrue(restored.ambiguousReplacements.isEmpty)
    }

    func testAsteriskAmbiguousMaskIsRefusedNeverGuessed() {
        // 张三 and 张万 both masked to 张*. Restoring 张* would be a guess,
        // so the site stays masked and the report flags the ambiguity.
        let document = "证人张三与证人张万到场，电话13812345678。"
        let spans = [
            span("张三", in: document, type: .person),
            span("张万", in: document, type: .person),
            span("13812345678", in: document, type: .phone)
        ]
        let tokenized = Tokenizer.tokenize(
            text: document,
            spans: spans,
            sourceFile: "doc.txt",
            createdAtISO8601: "2026-08-30T00:00:00Z",
            style: .asterisk
        )
        XCTAssertEqual(tokenized.tokenizedText, "证人张*与证人张*到场，电话138****5678。")

        let restored = Restorer.restore(text: tokenized.tokenizedText, mapping: tokenized.mapping)
        // The phone is unique and restores; the colliding person mask does not.
        XCTAssertEqual(restored.text, "证人张*与证人张*到场，电话13812345678。")
        XCTAssertEqual(restored.restoredCount, 1)
        XCTAssertEqual(restored.ambiguousReplacements, ["张*"])
        XCTAssertFalse(restored.text.contains("张三"))
        XCTAssertFalse(restored.text.contains("张万"))
    }

    // MARK: - Headline: AI-rewrite robustness, token vs pseudonym

    func testPseudonymSurvivesTheAIRewriteThatBreaksTokens() {
        let document = "By 王小明 of Acme Holdings Ltd, at 12 Harbour Road, on 2026年3月18日."
        let spans = [
            span("王小明", in: document, type: .person),
            span("Acme Holdings Ltd", in: document, type: .company),
            span("12 Harbour Road", in: document, type: .address),
            span("2026年3月18日", in: document, type: .date)
        ]

        // Token style: the AI rewrites every brace token, and restore
        // recovers NOTHING (the characterization baseline).
        let tokenRun = Tokenizer.tokenize(
            text: document,
            spans: spans,
            sourceFile: "doc.txt",
            createdAtISO8601: "2026-08-30T00:00:00Z",
            style: .token
        )
        let tokenAfterAI = AIRewriteSimulator.rewriteTokens(in: tokenRun.tokenizedText)
        XCTAssertNotEqual(tokenAfterAI, tokenRun.tokenizedText, "the simulator must have rewritten the tokens")
        let tokenRestore = Restorer.restore(text: tokenAfterAI, mapping: tokenRun.mapping)
        XCTAssertEqual(tokenRestore.restoredCount, 0)
        XCTAssertFalse(tokenRestore.text.contains("王小明"))
        XCTAssertFalse(tokenRestore.text.contains("Acme Holdings Ltd"))

        // Pseudonym style: the same rewriter finds no brace tokens to mangle
        // (natural names pass through), and restore is byte-identical.
        let pseudonymRun = Tokenizer.tokenize(
            text: document,
            spans: spans,
            sourceFile: "doc.txt",
            createdAtISO8601: "2026-08-30T00:00:00Z",
            style: .pseudonym
        )
        let pseudonymAfterAI = AIRewriteSimulator.rewriteTokens(in: pseudonymRun.tokenizedText)
        XCTAssertEqual(
            pseudonymAfterAI,
            pseudonymRun.tokenizedText,
            "natural-language pseudonyms give the rewriter nothing to mangle"
        )
        let pseudonymRestore = Restorer.restore(text: pseudonymAfterAI, mapping: pseudonymRun.mapping)
        XCTAssertEqual(pseudonymRestore.text, document)
        XCTAssertEqual(pseudonymRestore.restoredCount, 4)
        XCTAssertTrue(pseudonymRestore.orphanTokens.isEmpty)
    }

    func testPseudonymSurvivesARewriteThatEditsSurroundingProse() {
        // A harsher rewriter: it mangles tokens AND rewrites the prose around
        // the names, the way a real model paraphrases. The pseudonyms are
        // moved into a new sentence and still restore.
        let document = "卖方为深圳创新科技有限公司，买方为王小明。"
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
        XCTAssertEqual(result.tokenizedText, "卖方为甲公司，买方为张某。")

        // Simulated AI answer: paraphrased prose, same pseudonyms.
        let aiAnswer = "经审查，本合同的出卖人是甲公司；张某作为买受人应按期付款。"
        let restored = Restorer.restore(text: aiAnswer, mapping: result.mapping)
        XCTAssertEqual(restored.text, "经审查，本合同的出卖人是深圳创新科技有限公司；王小明作为买受人应按期付款。")
        XCTAssertEqual(restored.restoredCount, 2)
    }
}

// MARK: - Mixed-style mappings (merge-seam review finding 2)

extension RestorerStyleTests {

    /// A client mapping seeded under one style and extended under another
    /// carries both replacement shapes. A token-style mapping must restore
    /// its carried literal (pseudonym-shaped) seed entries too: an OLD
    /// pseudonym intermediate restored against the updated mapping used to
    /// come back with zero replacements and no warning at all.
    func testTokenStyleMappingAlsoRestoresCarriedLiteralSeedEntries() {
        let document = "本协议由{PERSON_1}签署。"
        let spans = [span("{PERSON_1}", in: document, type: .person)]
        _ = spans
        var mapping = Tokenizer.tokenize(
            text: "张三签署。",
            spans: [span("张三", in: "张三签署。", type: .person)],
            sourceFile: "doc.txt",
            createdAtISO8601: "2026-08-30T00:00:00Z",
            style: .token
        ).mapping
        // A pseudonym-shaped seed carried across styles: the replacement is a
        // natural-language stand-in, not a brace token.
        mapping.entries["甲公司"] = entry(
            replacement: "甲公司",
            value: "杭州快帆科技有限公司",
            type: .company
        )

        let mixed = "本协议由甲公司与{PERSON_1}签署。"
        let restored = Restorer.restore(text: mixed, mapping: mapping)

        XCTAssertEqual(restored.text, "本协议由杭州快帆科技有限公司与张三签署。")
        XCTAssertEqual(restored.restoredCount, 2)
        XCTAssertTrue(restored.orphanTokens.isEmpty, "both shapes restored: \(restored.orphanTokens)")
    }

    /// The supplement must not pollute the report: a carried literal entry
    /// that simply does not occur in a token-style document is EXPECTED (the
    /// document uses braces), not an orphan.
    func testAbsentCarriedLiteralEntryIsNotReportedAsOrphan() {
        var mapping = Tokenizer.tokenize(
            text: "张三签署。",
            spans: [span("张三", in: "张三签署。", type: .person)],
            sourceFile: "doc.txt",
            createdAtISO8601: "2026-08-30T00:00:00Z",
            style: .token
        ).mapping
        mapping.entries["甲公司"] = entry(
            replacement: "甲公司",
            value: "杭州快帆科技有限公司",
            type: .company
        )

        let restored = Restorer.restore(text: "{PERSON_1}到场。", mapping: mapping)

        XCTAssertEqual(restored.text, "张三到场。")
        XCTAssertEqual(restored.restoredCount, 1)
        XCTAssertTrue(restored.orphanTokens.isEmpty, "an absent carried literal is not an orphan")
    }
}
