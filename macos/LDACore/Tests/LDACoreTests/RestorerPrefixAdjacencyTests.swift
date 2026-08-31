//
//  RestorerPrefixAdjacencyTests.swift
//  LDACoreTests
//
//  Literal-style restore reads the REDACTED text, but the pseudonym
//  uniqueness machinery only ever checked candidates against the ORIGINAL
//  corpus. At the seam where an emitted replacement meets the document text
//  that follows it, those two views disagree: an emitted replacement that is
//  a strict prefix of another replacement, followed by text that completes
//  the longer one, spells that longer replacement in the redacted text. The
//  longest-match-wins literal scan then restores the wrong entity over the
//  site and swallows the adjacent document characters.
//
//  These tests pin the fixed shapes and, at the end, the two related shapes
//  the seam guard cannot reach. Those last two are labelled KNOWN GAP and
//  assert today's wrong output on purpose, so the residue stays visible and
//  a future fix trips them loudly rather than passing silently.
//
//  House rules: all comments and strings in English. Fixture strings and
//  generated pseudonyms may be Chinese. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class RestorerPrefixAdjacencyTests: XCTestCase {

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

    // MARK: - Minted pseudonyms: the longer replacement minted second

    /// Twenty seven distinct addresses exhaust the single-letter pseudonym
    /// sequence, so the first address mints 某地址A and the last would mint
    /// 某地址AA. The first address is immediately followed by a building
    /// letter ("A座"), which is exactly the tail that turns the emitted
    /// 某地址A into 某地址AA in the redacted text. Before the seam guard the
    /// first address restored to the twenty seventh address's value and ate
    /// the building letter.
    func testLongerPseudonymNeverLandsOnASeamTheDocumentAlreadySpells() {
        var document = "第一送达地址：北京市朝阳区建国路1号A座。"
        for index in 2...27 {
            document += "第\(index)送达地址：上海市浦东新区世纪大道\(index)号。"
        }

        var spans = [span("北京市朝阳区建国路1号", in: document, type: .address)]
        for index in 2...27 {
            spans.append(
                span("上海市浦东新区世纪大道\(index)号", in: document, type: .address)
            )
        }

        let tokenized = Tokenizer.tokenize(
            text: document,
            spans: spans,
            sourceFile: "doc.txt",
            createdAtISO8601: "2026-08-31T00:00:00Z",
            style: .pseudonym
        )

        // The seam 某地址A + "A座" is skipped, so 某地址AA is never minted.
        XCTAssertFalse(tokenized.mapping.entries.keys.contains("某地址AA"))

        let restored = Restorer.restore(
            text: tokenized.tokenizedText,
            mapping: tokenized.mapping
        )
        XCTAssertEqual(restored.text, document)
        XCTAssertEqual(restored.restoredCount, 27)
        XCTAssertTrue(restored.orphanTokens.isEmpty)
    }

    // MARK: - Minted pseudonyms: the longer replacement already in use

    /// The mirror mint order. A seed mapping already spends 某地址AB on a
    /// surface that does not appear in this document, so that replacement is
    /// taken but never emitted here and the redacted text does not spell it.
    /// The address in this document is followed by "B座", so minting 某地址A
    /// for it would let 某地址AB match at the site and win.
    func testShorterPseudonymNeverLandsWhereALongerReplacementCanCompleteIt() {
        let document = "送达地址：北京市朝阳区建国路1号B座。"
        let seeded = entry(
            replacement: "某地址AB",
            value: "广州市天河区天河路2号",
            type: .address
        )
        let seedMapping = Mapping(
            entries: [seeded.token: seeded],
            createdAtISO8601: "2026-08-31T00:00:00Z",
            sourceFile: "prior.txt",
            style: .pseudonym
        )

        let tokenized = Tokenizer.tokenize(
            text: document,
            spans: [span("北京市朝阳区建国路1号", in: document, type: .address)],
            sourceFile: "doc.txt",
            createdAtISO8601: "2026-08-31T00:00:00Z",
            seedMapping: seedMapping,
            style: .pseudonym
        )

        XCTAssertFalse(tokenized.tokenizedText.contains("某地址AB"))

        let restored = Restorer.restore(
            text: tokenized.tokenizedText,
            mapping: tokenized.mapping
        )
        XCTAssertEqual(restored.text, document)
        XCTAssertEqual(restored.restoredCount, 1)
    }

    /// The same rule holds against a forced replacement: an override is
    /// reserved before minting, and the seam it leaves in the redacted text
    /// must not steer a minted pseudonym onto it. Here 甲公司 is forced to
    /// 某地址 and is followed by "A座", so 某地址A is off limits.
    func testMintedPseudonymAvoidsASeamLeftByAnOverride() throws {
        let document = "受托方甲公司A座办公。送达地：北京市朝阳区建国路1号。"

        let tokenized = try Tokenizer.tokenize(
            text: document,
            spans: [
                span("甲公司", in: document, type: .company),
                span("北京市朝阳区建国路1号", in: document, type: .address)
            ],
            sourceFile: "doc.txt",
            createdAtISO8601: "2026-08-31T00:00:00Z",
            style: .pseudonym,
            overrides: ["甲公司": "某地址"]
        )

        let restored = Restorer.restore(
            text: tokenized.tokenizedText,
            mapping: tokenized.mapping
        )
        XCTAssertEqual(restored.text, document)
        XCTAssertEqual(restored.restoredCount, 2)
    }

    /// The same seam matters when the override's span comes LATER in the
    /// document than the pseudonym being minted. Forced text is emitted at
    /// every one of its sites regardless of walk order, so the mint loop has
    /// to see those seams from the start.
    func testMintedPseudonymAvoidsAnOverrideSeamThatComesLaterInTheDocument() throws {
        let document = "送达地：北京市朝阳区建国路1号。受托方甲公司A座办公。"

        let tokenized = try Tokenizer.tokenize(
            text: document,
            spans: [
                span("北京市朝阳区建国路1号", in: document, type: .address),
                span("甲公司", in: document, type: .company)
            ],
            sourceFile: "doc.txt",
            createdAtISO8601: "2026-08-31T00:00:00Z",
            style: .pseudonym,
            overrides: ["甲公司": "某地址"]
        )

        let restored = Restorer.restore(
            text: tokenized.tokenizedText,
            mapping: tokenized.mapping
        )
        XCTAssertEqual(restored.text, document)
        XCTAssertEqual(restored.restoredCount, 2)
    }

    // MARK: - Minted pseudonyms: the preceding-text seam, fixable order

    /// The seam can also form to the LEFT of a site. A person pseudonym 张某
    /// and an address pseudonym 某地址A share the character 某, so a bare 张
    /// in the document immediately before an address site spells 张某 across
    /// the seam. When the address is minted first, the person mint sees that
    /// seam in the redacted document and skips 张某.
    func testPersonPseudonymAvoidsASeamLeftByAnEarlierAddressSite() {
        let document = "扩张北京市朝阳区建国路1号。经办人王小明。"

        let tokenized = Tokenizer.tokenize(
            text: document,
            spans: [
                span("北京市朝阳区建国路1号", in: document, type: .address),
                span("王小明", in: document, type: .person)
            ],
            sourceFile: "doc.txt",
            createdAtISO8601: "2026-08-31T00:00:00Z",
            style: .pseudonym
        )

        let restored = Restorer.restore(
            text: tokenized.tokenizedText,
            mapping: tokenized.mapping
        )
        XCTAssertEqual(restored.text, document)
        XCTAssertEqual(restored.restoredCount, 2)
    }

    // MARK: - Overrides

    /// The user forces 甲方 for one company and 甲方代理人 for another. The
    /// first company is followed in the document by the literal word 代理人,
    /// so the emitted 甲方 plus that text spells the second override. Neither
    /// replacement occurs naturally in the corpus, so the containment check
    /// clears both and only the prefix rule catches it. Forced text has no
    /// next candidate to advance to, so it is rejected rather than adjusted.
    func testOverrideInAPrefixRelationWithAnotherOverrideIsRejected() {
        let document = "北京华辰科技有限公司代理人到庭。上海远东贸易有限公司另行委托。"

        XCTAssertThrowsError(
            try Tokenizer.tokenize(
                text: document,
                spans: [
                    span("北京华辰科技有限公司", in: document, type: .company),
                    span("上海远东贸易有限公司", in: document, type: .company)
                ],
                sourceFile: "doc.txt",
                createdAtISO8601: "2026-08-31T00:00:00Z",
                style: .pseudonym,
                overrides: [
                    "北京华辰科技有限公司": "甲方",
                    "上海远东贸易有限公司": "甲方代理人"
                ]
            )
        ) { error in
            // Overrides are visited in sorted-surface order, so 上海... claims
            // 甲方代理人 first and 北京... is the pair reported.
            XCTAssertEqual(
                error as? PseudonymOverrideError,
                .prefixOfAnotherReplacement(
                    surface: "北京华辰科技有限公司",
                    replacement: "甲方",
                    other: "甲方代理人"
                )
            )
        }
    }

    /// The same rule against a replacement a seed mapping already spent.
    func testOverrideInAPrefixRelationWithASeedReplacementIsRejected() {
        let seeded = entry(replacement: "买受人", value: "杭州西子科技有限公司", type: .company)

        XCTAssertThrowsError(
            try PseudonymOverrideValidator.validate(
                overrides: ["王小明": "买受人代表"],
                style: .pseudonym,
                corpus: ["杭州西子科技有限公司委托王小明办理。"],
                existingEntries: [seeded.token: seeded]
            )
        ) { error in
            XCTAssertEqual(
                error as? PseudonymOverrideError,
                .prefixOfAnotherReplacement(
                    surface: "王小明",
                    replacement: "买受人代表",
                    other: "买受人"
                )
            )
        }
    }

    /// Reusing the same forced text for the same surface is not a prefix
    /// relation, so re-running a build with unchanged overrides stays valid.
    func testUnchangedOverrideAgainstItsOwnSeedEntryStillPasses() {
        let seeded = entry(replacement: "买受人", value: "杭州西子科技有限公司", type: .company)

        XCTAssertNoThrow(
            try PseudonymOverrideValidator.validate(
                overrides: ["杭州西子科技有限公司": "买受人"],
                style: .pseudonym,
                corpus: ["杭州西子科技有限公司委托王小明办理。"],
                existingEntries: [seeded.token: seeded]
            )
        )
    }

    // MARK: - Seam guard rules

    /// The rendering the guard reasons over must be the document the restore
    /// scan will actually read. With every surface assigned it has to equal
    /// the tokenized output byte for byte, or every rule above is reasoning
    /// about the wrong string.
    func testProvisionalRenderingOfAFullAssignmentEqualsTheTokenizedText() {
        let document = "出卖人：深圳创新科技有限公司。买受人：王小明，电话13812345678。"
        let spans = [
            span("深圳创新科技有限公司", in: document, type: .company),
            span("王小明", in: document, type: .person),
            span("13812345678", in: document, type: .phone)
        ]
        let tokenized = Tokenizer.tokenize(
            text: document,
            spans: spans,
            sourceFile: "doc.txt",
            createdAtISO8601: "2026-08-31T00:00:00Z",
            style: .pseudonym
        )

        var replacementBySurface: [String: String] = [:]
        for entry in tokenized.mapping.entries.values {
            replacementBySurface[entry.value] = entry.token
        }
        let rendered = PseudonymSeamGuard.renderProvisional(
            text: document,
            spans: spans.sorted { $0.start < $1.start },
            replacementBySurface: replacementBySurface
        )
        XCTAssertEqual(rendered.text, tokenized.tokenizedText)
    }

    /// Only a replacement that STARTS with the candidate can outrank it at
    /// the candidate's own site, because the scan takes the earliest start
    /// and then the longest match. This is also what keeps minting
    /// terminating: if mere containment counted, "Company A" would block
    /// every "Company A?" candidate once the single letters ran out and the
    /// generator could never escape.
    func testSeamGuardIgnoresAReplacementThatOnlyContainsTheCandidate() {
        let document = "Notice to Acme Corp at the site."
        let spans = [span("Acme Corp", in: document, type: .company)]
        let rendered = PseudonymSeamGuard.renderProvisional(
            text: document,
            spans: spans,
            replacementBySurface: [:]
        )
        XCTAssertFalse(
            PseudonymSeamGuard.completesLongerReplacement(
                candidate: "Company A",
                surface: "Acme Corp",
                spans: spans,
                document: rendered,
                replacements: ["The Company A Ltd", "Company"]
            )
        )
    }

    /// The positive half of the same rule: the replacement starts with the
    /// candidate AND the text after the site supplies the rest of it.
    func testSeamGuardCatchesALongerReplacementTheFollowingTextCompletes() {
        let document = "Notice to Acme Corp at the site."
        let spans = [span("Acme Corp", in: document, type: .company)]
        let rendered = PseudonymSeamGuard.renderProvisional(
            text: document,
            spans: spans,
            replacementBySurface: [:]
        )
        XCTAssertTrue(
            PseudonymSeamGuard.completesLongerReplacement(
                candidate: "Company A",
                surface: "Acme Corp",
                spans: spans,
                document: rendered,
                replacements: ["Company A at"]
            )
        )
    }

    /// The guard renders the document once per minted surface, so a document
    /// with many distinct entities must not turn tokenization quadratic in
    /// wall-clock terms. Measured at roughly 0.9s for this fixture against
    /// 0.35s without the guard, so the bound below is a blowup smoke guard,
    /// not a tight budget.
    func testPseudonymMintingStaysFastOnManyDistinctEntities() {
        var document = "送达清单。"
        for index in 1...300 {
            document += "第\(index)项：上海市浦东新区世纪大道\(index)号，联系人王小明\(index)。"
        }
        var spans: [Span] = []
        for index in 1...300 {
            spans.append(span("上海市浦东新区世纪大道\(index)号", in: document, type: .address))
            spans.append(span("王小明\(index)", in: document, type: .person))
        }

        let started = Date()
        let tokenized = Tokenizer.tokenize(
            text: document,
            spans: spans,
            sourceFile: "doc.txt",
            createdAtISO8601: "2026-08-31T00:00:00Z",
            style: .pseudonym
        )
        let elapsed = Date().timeIntervalSince(started)

        let restored = Restorer.restore(
            text: tokenized.tokenizedText,
            mapping: tokenized.mapping
        )
        XCTAssertEqual(restored.text, document)
        XCTAssertLessThan(elapsed, 5.0)
    }

    // MARK: - KNOWN GAPS (asserting today's wrong output on purpose)

    /// KNOWN GAP, asterisk style. Masks are a pure function of the surface, so
    /// the tokenizer has no second candidate to advance to and the seam guard
    /// has no lever: a two character CJK name always masks to a strict prefix
    /// of a three character name sharing its surname (张三 masks to 张*, 张伟明
    /// masks to 张*明). Where 张三 is followed by 明, the redacted text spells
    /// 张*明 and restore silently swaps one real person for another.
    ///
    /// Closing this needs a restore-side decision (refuse and flag a prefix
    /// conflict, the way asterisk collisions are already refused), which
    /// would also make every 张*/张*明 pair unrestorable. That trade is not
    /// this change's to make.
    func testKnownGapAsteriskMaskPrefixIsCompletedByAdjacentText() {
        let document = "张三明确表示同意，张伟明另有说法。"
        let tokenized = Tokenizer.tokenize(
            text: document,
            spans: [
                span("张三", in: document, type: .person),
                span("张伟明", in: document, type: .person)
            ],
            sourceFile: "doc.txt",
            createdAtISO8601: "2026-08-31T00:00:00Z",
            style: .asterisk
        )
        XCTAssertEqual(tokenized.tokenizedText, "张*明确表示同意，张*明另有说法。")

        let restored = Restorer.restore(
            text: tokenized.tokenizedText,
            mapping: tokenized.mapping
        )
        // Wanted: the original document. 张三's site is swallowed by 张*明.
        XCTAssertEqual(restored.text, "张伟明确表示同意，张伟明另有说法。")
        XCTAssertNotEqual(restored.text, document)
    }

    /// KNOWN GAP, pseudonym style, preceding-text seam in the unfixable mint
    /// order. This is the mirror of
    /// testPersonPseudonymAvoidsASeamLeftByAnEarlierAddressSite with the
    /// person ahead of the address: 张某 is minted while the document still
    /// reads 扩张北京市..., so nothing is wrong yet, and the address emitted
    /// afterwards is what creates the 张某 seam.
    ///
    /// The guard cannot fix this by advancing the ADDRESS candidate: every
    /// Chinese address pseudonym starts with 某, so a left context ending in
    /// 张 blocks the entire sequence and minting would not terminate. The fix
    /// is to remint the earlier pseudonym, which needs a repair pass over the
    /// whole assignment rather than a mint-time filter.
    func testKnownGapPrecedingTextSeamSwallowsALaterAddressSite() {
        let document = "经办人王小明。扩张北京市朝阳区建国路1号。"
        let tokenized = Tokenizer.tokenize(
            text: document,
            spans: [
                span("王小明", in: document, type: .person),
                span("北京市朝阳区建国路1号", in: document, type: .address)
            ],
            sourceFile: "doc.txt",
            createdAtISO8601: "2026-08-31T00:00:00Z",
            style: .pseudonym
        )
        XCTAssertEqual(tokenized.tokenizedText, "经办人张某。扩张某地址A。")

        let restored = Restorer.restore(
            text: tokenized.tokenizedText,
            mapping: tokenized.mapping
        )
        // Wanted: the original document. 张某 matches across the 扩张 seam
        // first, which injects a real name and drops the address site.
        XCTAssertEqual(restored.text, "经办人王小明。扩王小明地址A。")
        XCTAssertNotEqual(restored.text, document)
    }
}
