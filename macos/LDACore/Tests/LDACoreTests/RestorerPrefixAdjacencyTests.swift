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
//  Asterisk masks are a pure function of the surface, so the mint-time guard
//  has no second candidate to offer there and the conflict has to be settled
//  at restore time: a site the redacted text spells with two different masks
//  is refused and flagged rather than guessed.
//
//  These tests pin the fixed shapes, the refusal and its blast radius, and
//  the whole-assignment repair required when a later replacement gives an
//  earlier pseudonym a new seam meaning.
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

    /// Builds the release-scale fixture without repeatedly searching the
    /// growing document for each span. Fixture construction is intentionally
    /// outside the timed region.
    private func pseudonymPerformanceFixture(
        entityCount: Int
    ) -> (document: String, spans: [Span]) {
        precondition(entityCount.isMultiple(of: 2))

        var document = "送达清单。"
        var spans: [Span] = []
        spans.reserveCapacity(entityCount)

        for index in 1...(entityCount / 2) {
            let address = "上海市浦东新区世纪大道\(index)号"
            let person = "王小明\(index)"
            document += "第\(index)项："

            let addressStart = document.utf16.count
            document += address
            spans.append(
                Span(
                    start: addressStart,
                    end: addressStart + address.utf16.count,
                    type: .address,
                    text: address,
                    source: .manual,
                    confidence: 1.0,
                    priority: 10
                )
            )

            document += "，联系人"
            let personStart = document.utf16.count
            document += person
            spans.append(
                Span(
                    start: personStart,
                    end: personStart + person.utf16.count,
                    type: .person,
                    text: person,
                    source: .manual,
                    confidence: 1.0,
                    priority: 10
                )
            )
            document += "。"
        }

        return (document, spans)
    }

    private func timedPseudonymTokenization(
        _ fixture: (document: String, spans: [Span])
    ) throws -> (seconds: Double, result: TokenizeResult) {
        var tokenized: TokenizeResult?
        let elapsed = ContinuousClock().measure {
            tokenized = Tokenizer.tokenize(
                text: fixture.document,
                spans: fixture.spans,
                sourceFile: "doc.txt",
                createdAtISO8601: "2026-08-31T00:00:00Z",
                style: .pseudonym
            )
        }
        let result = try XCTUnwrap(tokenized)
        XCTAssertEqual(result.mapping.entries.count, fixture.spans.count)
        XCTAssertTrue(result.unresolvedSeams.isEmpty)
        let components = elapsed.components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        return (seconds, result)
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// Tripling the number of distinct entities must not make pseudonym
    /// tokenization more than six times slower. The regression implementation
    /// rendered the full document once per minted surface and was measured at
    /// 6.3 seconds for 1,500 entities versus 55.1 seconds for 4,500, a ratio
    /// of 8.7. Local seam windows should keep the same correctness contract
    /// while bringing that growth below this deliberately loose ceiling.
    func testPseudonymMintingDoesNotScaleWithAFullDocumentRenderPerEntity() throws {
        _ = try timedPseudonymTokenization(pseudonymPerformanceFixture(entityCount: 20))

        let small = pseudonymPerformanceFixture(entityCount: 1_500)
        let large = pseudonymPerformanceFixture(entityCount: 4_500)
        var smallSamples: [Double] = []
        var largeSamples: [Double] = []
        var smallResult: TokenizeResult?

        // Alternate sizes so thermal or background-load drift cannot favor
        // every sample of one fixture. The median rejects one noisy outlier.
        for _ in 0..<3 {
            let measuredSmall = try timedPseudonymTokenization(small)
            smallSamples.append(measuredSmall.seconds)
            smallResult = measuredSmall.result

            let measuredLarge = try timedPseudonymTokenization(large)
            largeSamples.append(measuredLarge.seconds)
        }

        let smallElapsed = median(smallSamples)
        let largeElapsed = median(largeSamples)

        XCTAssertLessThan(
            largeElapsed,
            smallElapsed * 6.0,
            "tripling entities took \(largeElapsed / smallElapsed)x longer"
        )
        XCTAssertLessThan(
            largeElapsed,
            15.0,
            "4,500 entities took \(largeElapsed)s"
        )

        // Restoration is deliberately outside every timed region. It proves
        // the faster assignment still preserves the literal round trip.
        let result = try XCTUnwrap(smallResult)
        let restored = Restorer.restore(text: result.tokenizedText, mapping: result.mapping)
        XCTAssertEqual(restored.text, small.document)
    }

    // MARK: - Asterisk prefix conflicts: refuse and flag

    private func literalMapping(
        _ entries: [MappingEntry],
        style: SubstitutionStyle
    ) -> Mapping {
        Mapping(
            entries: Dictionary(uniqueKeysWithValues: entries.map { ($0.token, $0) }),
            createdAtISO8601: "2026-08-31T00:00:00Z",
            sourceFile: "doc.txt",
            style: style
        )
    }

    /// The asterisk mask is a pure function of the surface, so a two
    /// character CJK name always masks to a strict prefix of a three
    /// character name sharing its surname (张三 masks to 张*, 张伟明 masks to
    /// 张*明). Where 张三 is followed by 明 the redacted text spells 张*明 at
    /// that site, and longest-match-wins used to restore a DIFFERENT real
    /// person over it. The site is now refused: the bytes stay verbatim and
    /// the mask is flagged, the same treatment exact mask collisions already
    /// get. This test replaces the known-gap pin that asserted the old wrong
    /// output.
    func testAsteriskMaskCompletedByAdjacentTextIsRefusedNeverGuessed() {
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
        // Both sites read 张*明, which either name could have produced, so
        // neither is restored and the text comes back unchanged.
        XCTAssertEqual(restored.text, tokenized.tokenizedText)
        XCTAssertEqual(restored.restoredCount, 0)
        XCTAssertEqual(restored.ambiguousReplacements, ["张*明"])
        XCTAssertFalse(restored.text.contains("张三"), "a refused site must never name a person")
        XCTAssertFalse(restored.text.contains("张伟明"), "a refused site must never name a person")
        // 张* never substituted: the longer mask shadowed both of its sites,
        // which the orphan report already covers.
        XCTAssertEqual(restored.orphanTokens, ["张*"])
    }

    /// The blast radius of the refusal, pinned. Refusing is per POSITION:
    /// every site whose text spells the longer mask is refused (whichever
    /// name produced it), and every other site of the shorter mask restores
    /// normally. The shorter mask is NOT disabled document wide.
    func testAsteriskPrefixRefusalIsPerPositionNotPerReplacement() {
        let mapping = literalMapping(
            [
                entry(replacement: "张*", value: "张三", type: .person),
                entry(replacement: "张*明", value: "张伟明", type: .person)
            ],
            style: .asterisk
        )

        // Site one is 张三 followed by 到 and is unambiguous. Site two is
        // 张伟明. Site three is 张三 followed by 明, which spells the longer
        // mask at that position.
        let restored = Restorer.restore(
            text: "张*到场。张*明另有说法。张*明确表示同意。",
            mapping: mapping
        )
        XCTAssertEqual(restored.text, "张三到场。张*明另有说法。张*明确表示同意。")
        XCTAssertEqual(restored.restoredCount, 1)
        XCTAssertEqual(restored.ambiguousReplacements, ["张*明"])
        XCTAssertTrue(restored.orphanTokens.isEmpty)
        XCTAssertFalse(restored.text.contains("张伟明"), "the longer name must not reach a refused site")
    }

    /// No false refusals: the longer mask is in the mapping, but no site in
    /// this text spells it, so every shorter-mask site restores.
    func testAsteriskShortMaskRestoresWhereTheLongMaskIsNotSpelled() {
        let mapping = literalMapping(
            [
                entry(replacement: "张*", value: "张三", type: .person),
                entry(replacement: "张*明", value: "张伟明", type: .person)
            ],
            style: .asterisk
        )

        let restored = Restorer.restore(text: "张*到场，张*未签字。", mapping: mapping)
        XCTAssertEqual(restored.text, "张三到场，张三未签字。")
        XCTAssertEqual(restored.restoredCount, 2)
        XCTAssertTrue(restored.ambiguousReplacements.isEmpty)
        XCTAssertEqual(restored.orphanTokens, ["张*明"], "the absent mask is an orphan, not an ambiguity")
    }

    /// No collision in the mapping, no refusal. Only 张三 is an entity here,
    /// so 明 is ordinary document text and 张*明 is not a mask at all.
    func testAsteriskRestoreIsNormalWhenOnlyOneCollidingNameIsMapped() {
        let mapping = literalMapping(
            [entry(replacement: "张*", value: "张三", type: .person)],
            style: .asterisk
        )

        let restored = Restorer.restore(
            text: "张*明确表示同意，张*到场。",
            mapping: mapping
        )
        XCTAssertEqual(restored.text, "张三明确表示同意，张三到场。")
        XCTAssertEqual(restored.restoredCount, 2)
        XCTAssertTrue(restored.ambiguousReplacements.isEmpty)
        XCTAssertTrue(restored.orphanTokens.isEmpty)
    }

    // MARK: - The other styles are untouched by the refusal

    /// Pseudonym uniqueness is established at mint time by
    /// PseudonymSeamGuard, so longest-match-wins stays correct there and the
    /// refusal must not reach the style.
    func testPseudonymPrefixCollisionStillTakesTheLongestMatch() {
        let mapping = literalMapping(
            [
                entry(replacement: "某地址A", value: "1 Main St", type: .address),
                entry(replacement: "某地址AA", value: "27 Long Rd", type: .address)
            ],
            style: .pseudonym
        )

        let restored = Restorer.restore(text: "送达：某地址AA；抄送：某地址A。", mapping: mapping)
        XCTAssertEqual(restored.text, "送达：27 Long Rd；抄送：1 Main St。")
        XCTAssertEqual(restored.restoredCount, 2)
        XCTAssertTrue(restored.ambiguousReplacements.isEmpty)
        XCTAssertTrue(restored.orphanTokens.isEmpty)
    }

    /// Token style scans the brace grammar, which matches a whole token, so
    /// one token being a prefix of another is not a conflict there either.
    func testTokenStyleWithPrefixSharingTokensIsUntouched() {
        let mapping = literalMapping(
            [
                entry(replacement: "{PERSON_1}", value: "张三", type: .person),
                entry(replacement: "{PERSON_12}", value: "张伟明", type: .person)
            ],
            style: .token
        )

        let restored = Restorer.restore(text: "{PERSON_12}与{PERSON_1}到场。", mapping: mapping)
        XCTAssertEqual(restored.text, "张伟明与张三到场。")
        XCTAssertEqual(restored.restoredCount, 2)
        XCTAssertTrue(restored.ambiguousReplacements.isEmpty)
    }

    /// The style gate itself. Only the asterisk style refuses prefix
    /// conflicts; the other two keep longest-match-wins.
    func testOnlyTheAsteriskStyleRefusesPrefixConflicts() {
        XCTAssertTrue(Restorer.refusesPrefixConflicts(literalMapping([], style: .asterisk)))
        XCTAssertFalse(Restorer.refusesPrefixConflicts(literalMapping([], style: .pseudonym)))
        XCTAssertFalse(Restorer.refusesPrefixConflicts(literalMapping([], style: .token)))
    }

    // MARK: - The docx run surface refuses the same sites

    /// The docx restore substitutes run by run through this helper rather
    /// than through the reporting scan, so it has to refuse the same sites.
    /// Otherwise the report would say a site was left verbatim while the
    /// written document had already named the wrong person there.
    func testDocxRunSubstitutionRefusesAsteriskPrefixConflicts() {
        let mapping = literalMapping(
            [
                entry(replacement: "张*", value: "张三", type: .person),
                entry(replacement: "张*明", value: "张伟明", type: .person)
            ],
            style: .asterisk
        )

        let restored = Restorer.substituteLiteralReplacements(
            in: "张*到场。张*明另有说法。",
            plan: Restorer.literalRestorePlan(for: mapping)
        )
        XCTAssertEqual(restored, "张三到场。张*明另有说法。")
    }

    func testDocxRunSubstitutionKeepsLongestMatchWinsForPseudonyms() {
        let mapping = literalMapping(
            [
                entry(replacement: "某地址A", value: "1 Main St", type: .address),
                entry(replacement: "某地址AA", value: "27 Long Rd", type: .address)
            ],
            style: .pseudonym
        )

        let restored = Restorer.substituteLiteralReplacements(
            in: "送达：某地址AA；抄送：某地址A。",
            plan: Restorer.literalRestorePlan(for: mapping)
        )
        XCTAssertEqual(restored, "送达：27 Long Rd；抄送：1 Main St。")
    }

    /// The run surface has to scan the masks it may NOT substitute too. Two
    /// people share 张* outright here, so it is never substituted, but
    /// dropping it from the scan would leave 张*明 looking unambiguous and the
    /// walker would write 张伟明 over a site the text may have meant as 张三
    /// or 张万 followed by an ordinary 明.
    func testDocxRunSubstitutionScansTheMasksItCannotSubstitute() {
        let mapping = sharedMaskMapping()

        let restored = Restorer.substituteLiteralReplacements(
            in: "张*到场。张*明另有说法。",
            plan: Restorer.literalRestorePlan(for: mapping)
        )
        XCTAssertEqual(restored, "张*到场。张*明另有说法。")
    }

    /// The two refusal reasons coexist in one report: 张* is shared outright,
    /// 张*明 is spelled by two different masks at its site.
    func testSharedMaskAndPrefixConflictAreBothFlagged() {
        let restored = Restorer.restore(
            text: "张*到场。张*明另有说法。",
            mapping: sharedMaskMapping()
        )
        XCTAssertEqual(restored.text, "张*到场。张*明另有说法。")
        XCTAssertEqual(restored.restoredCount, 0)
        XCTAssertEqual(restored.ambiguousReplacements, ["张*", "张*明"])
        XCTAssertTrue(restored.orphanTokens.isEmpty)
    }

    /// Two people sharing 张* plus a third whose mask 张*明 extends it. The
    /// colliding pair is keyed the way Tokenizer keys an asterisk collision:
    /// a disambiguated KEY, with the shared mask kept in the entry's token.
    private func sharedMaskMapping() -> Mapping {
        Mapping(
            entries: [
                "张*": entry(replacement: "张*", value: "张三", type: .person),
                "张*#2": entry(replacement: "张*", value: "张万", type: .person),
                "张*明": entry(replacement: "张*明", value: "张伟明", type: .person)
            ],
            createdAtISO8601: "2026-08-31T00:00:00Z",
            sourceFile: "doc.txt",
            style: .asterisk
        )
    }

    // MARK: - Whole-assignment repair for a preceding-text seam

    /// Pseudonym style, preceding-text seam in the unfixable mint order. This
    /// is the mirror of
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
    func testDirectTokenizerRepairsPrecedingTextSeamByRemintingEarlierPerson() {
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

        let restored = Restorer.restore(
            text: tokenized.tokenizedText,
            mapping: tokenized.mapping
        )
        XCTAssertEqual(restored.text, document)
        XCTAssertEqual(restored.restoredCount, 2)
        XCTAssertTrue(restored.orphanTokens.isEmpty)
        XCTAssertTrue(tokenized.unresolvedSeams.isEmpty)
        XCTAssertFalse(tokenized.tokenizedText.contains("王小明"))
        XCTAssertFalse(tokenized.tokenizedText.contains("北京市朝阳区建国路1号"))
    }

    /// A mapping carried from another matter may contain a pseudonym that is
    /// ordinary boilerplate in this document. Nothing here emits 甲公司, so
    /// no remint can move the collision. Direct tokenization must preserve the
    /// session verifier's warning instead of returning a falsely safe result.
    func testDirectTokenizerReportsAnUnrepairableCarriedSeedCollision() throws {
        let document = "本合同由甲公司与丙方签署。"
        let seeded = entry(
            replacement: "甲公司",
            value: "北京鼎盛科技有限公司",
            type: .company
        )
        let seed = Mapping(
            entries: [seeded.token: seeded],
            createdAtISO8601: "2026-08-31T00:00:00Z",
            sourceFile: "earlier matter",
            style: .pseudonym
        )

        let tokenized = Tokenizer.tokenize(
            text: document,
            spans: [],
            sourceFile: "contract.txt",
            createdAtISO8601: "2026-08-31T00:00:00Z",
            seedMapping: seed,
            style: .pseudonym
        )

        XCTAssertFalse(tokenized.unresolvedSeams.isEmpty)
        XCTAssertThrowsError(try Tokenizer.requireSafeForRelease(tokenized)) { error in
            guard case TokenizationSafetyError.unresolvedSeams(let seams) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(seams, tokenized.unresolvedSeams)
        }
    }
}
