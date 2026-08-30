//
//  EntityRescanTests.swift
//  LDACoreTests
//
//  Tests for the full-document literal rescan: repeat-mention recall, alias
//  binding and grouping, safety filters, overlap rules, and performance.
//
//  House rules: all comments and strings in English (fixtures may contain
//  Chinese). No em-dash and no en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class EntityRescanTests: XCTestCase {

    // MARK: - Helpers

    /// Build a span over the nth occurrence (0-based) of value in text.
    private func span(
        _ value: String,
        in text: String,
        occurrence: Int = 0,
        type: EntityType,
        source: DetectionSource = .llm,
        confidence: Double = 0.9,
        priority: Int = 30
    ) -> Span {
        let ns = text as NSString
        var searchStart = 0
        var found = NSRange(location: NSNotFound, length: 0)
        for _ in 0...occurrence {
            found = ns.range(
                of: value,
                range: NSRange(location: searchStart, length: ns.length - searchStart)
            )
            precondition(found.location != NSNotFound, "fixture must contain the value")
            searchStart = found.location + found.length
        }
        return Span(
            start: found.location,
            end: found.location + found.length,
            type: type,
            text: value,
            source: source,
            confidence: confidence,
            priority: priority
        )
    }

    private func texts(of spans: [Span]) -> [String] {
        spans.map { $0.text }
    }

    // MARK: - Repeat-mention recall

    func testRescanFindsRepeatMentionsOfConfirmedCompany() {
        let text = "Meridian Works signed. Later Meridian Works delivered, and Meridian Works was paid."
        let confirmed = [span("Meridian Works", in: text, type: .company)]

        let expanded = EntityRescan.expand(confirmed, in: text)

        XCTAssertEqual(expanded.count, 3)
        XCTAssertTrue(expanded.allSatisfy { $0.type == .company && $0.text == "Meridian Works" })
        // Sorted by start, overlap-free.
        for (lhs, rhs) in zip(expanded, expanded.dropFirst()) {
            XCTAssertLessThanOrEqual(lhs.end, rhs.start)
        }
    }

    func testRescanFindsCJKRepeatMentions() {
        let text = "张伟是甲方代表。张伟应当于每月十五日前付款，逾期张伟承担违约责任。"
        let confirmed = [span("张伟", in: text, type: .person)]

        let expanded = EntityRescan.expand(confirmed, in: text)

        XCTAssertEqual(expanded.filter { $0.text == "张伟" }.count, 3)
    }

    func testRescanSkipsOccurrencesOverlappingAnySpan() {
        // The second "Acme Corp" sits inside a confirmed ADDRESS span and must
        // not be double-detected.
        let text = "Acme Corp leases the premises at Acme Corp Tower, 5 Main Street."
        let address = span("Acme Corp Tower, 5 Main Street", in: text, type: .address)
        let company = span("Acme Corp", in: text, type: .company)

        let expanded = EntityRescan.expand([company, address], in: text)

        XCTAssertEqual(expanded.count, 2, "no rescan span may overlap the address span")
    }

    func testRescanResolvesOverlapsAmongHitsLongestFirst() {
        // Both needles hit at the tail mention; the longer one must win.
        let text = "Meridian Works Limited and Meridian Works are one entity: Meridian Works Limited."
        let confirmed = [
            span("Meridian Works Limited", in: text, type: .company),
            span("Meridian Works", in: text, occurrence: 1, type: .company)
        ]

        let expanded = EntityRescan.expand(confirmed, in: text)

        let tailSpans = expanded.filter { $0.start > confirmed[1].end }
        XCTAssertEqual(texts(of: tailSpans), ["Meridian Works Limited"])
    }

    func testLatinNeedleRespectsWordBoundaries() {
        let text = "King signed here. The Kingdom is not a person. King agreed."
        let confirmed = [span("King", in: text, type: .person)]

        let expanded = EntityRescan.expand(confirmed, in: text)

        XCTAssertEqual(expanded.count, 2)
        XCTAssertTrue(expanded.allSatisfy { $0.text == "King" })
    }

    // MARK: - Session known entities (cross-document needles)

    func testKnownEntitiesAreSweptWithoutAnyLocalConfirmation() {
        // The session-level recall gap: this document's own detection found
        // nothing, yet a party confirmed in a partner document must be swept.
        // The partner span's offsets belong to the partner's text and are
        // meaningless here (they may even exceed this text's length); only
        // the surface travels.
        let text = "快帆科技确认收到全部款项。"
        let partnerText = "本协议由杭州快帆科技有限公司（以下简称快帆科技）与张三签署。"
        let partner = span("快帆科技", in: partnerText, occurrence: 1, type: .company)

        let expanded = EntityRescan.expand([], in: text, knownEntities: [partner])

        XCTAssertEqual(texts(of: expanded), ["快帆科技"])
        XCTAssertEqual(expanded.first?.type, .company)
    }

    func testKnownEntityOffsetsNeverBlockLocalOccurrences() {
        // A partner span whose range happens to coincide with this document's
        // only mention of that surface must not block the sweep: blocking
        // uses only THIS document's confirmed spans.
        let text = "The annex names Meridian Works and the date 2026-01-01."
        let date = span("2026-01-01", in: text, type: .date)
        let foreign = span("Meridian Works", in: text, type: .company)

        let expanded = EntityRescan.expand([date], in: text, knownEntities: [foreign])

        XCTAssertEqual(expanded.filter { $0.text == "Meridian Works" }.count, 1)
        XCTAssertEqual(expanded.count, 2, "the date span plus the swept company mention")
    }

    // MARK: - Unswept surfaces (cross-document recall check)

    func testUnsweptSurfacesReportsAPartnerPartyTheDocumentStillCarries() {
        // The whole point of the check: this document confirmed nothing about
        // the party, and its text names them in the clear.
        let text = "The filing was prepared for Jordan Marlowe this week."
        let partnerText = "Witness statement: Jordan Marlowe attended the hearing."
        let partner = span("Jordan Marlowe", in: partnerText, type: .person)

        let unswept = EntityRescan.unsweptSurfaces(
            in: text,
            confirmed: [],
            knownEntities: [partner]
        )

        XCTAssertEqual(unswept, ["Jordan Marlowe"])
    }

    func testUnsweptSurfacesIgnoresPartnerOffsets() {
        // Only the surface crosses documents. A partner span whose range runs
        // past the end of THIS text must still be checked, not skipped or
        // trapped into an out-of-range read.
        let text = "Paid to Meridian Works."
        let partnerText = String(repeating: "padding ", count: 40) + "Meridian Works closed."
        let partner = span("Meridian Works", in: partnerText, type: .company)
        XCTAssertGreaterThan(partner.start, (text as NSString).length)

        let unswept = EntityRescan.unsweptSurfaces(
            in: text,
            confirmed: [],
            knownEntities: [partner]
        )

        XCTAssertEqual(unswept, ["Meridian Works"])
    }

    func testUnsweptSurfacesSkipsASurfaceTheDocumentAlreadyConfirmed() {
        let text = "Meridian Works signed, and Meridian Works was paid."
        let mine = span("Meridian Works", in: text, type: .company)

        let unswept = EntityRescan.unsweptSurfaces(
            in: text,
            confirmed: [mine],
            knownEntities: [mine]
        )

        XCTAssertTrue(unswept.isEmpty)
    }

    func testUnsweptSurfacesSkipsOccurrencesInsideAConfirmedSpan() {
        // The document confirmed the longer company name, so its only mention
        // of the partner's person surface is already covered.
        let text = "The filing was prepared by Jordan Marlowe Holdings this week."
        let mine = span("Jordan Marlowe Holdings", in: text, type: .company)
        let partnerText = "Witness statement: Jordan Marlowe attended."
        let partner = span("Jordan Marlowe", in: partnerText, type: .person)

        let unswept = EntityRescan.unsweptSurfaces(
            in: text,
            confirmed: [mine],
            knownEntities: [partner]
        )

        XCTAssertTrue(unswept.isEmpty)
    }

    func testUnsweptSurfacesSkipsNeedlesTooShortToRescan() {
        let text = "Li reviewed the filing this week."
        let partnerText = "Witness statement: Li attended the hearing."
        let partner = span("Li", in: partnerText, type: .person)

        let unswept = EntityRescan.unsweptSurfaces(
            in: text,
            confirmed: [],
            knownEntities: [partner]
        )

        XCTAssertTrue(unswept.isEmpty)
    }

    func testUnsweptSurfacesReportsATwoCharacterCJKShortName() {
        // Two CJK characters clear the needle threshold, so a PRC short name
        // is reportable where a two-letter Latin fragment is not.
        let text = "快帆科技确认收到全部款项。"
        let partnerText = "本协议由杭州快帆科技有限公司（以下简称快帆科技）签署。"
        let partner = span("快帆科技", in: partnerText, occurrence: 1, type: .company)

        let unswept = EntityRescan.unsweptSurfaces(
            in: text,
            confirmed: [],
            knownEntities: [partner]
        )

        XCTAssertEqual(unswept, ["快帆科技"])
    }

    func testUnsweptSurfacesAgreesWithWhatExpandWouldSweep() {
        // The contract that makes the warning trustworthy: every surface
        // reported here is a surface expand() actually sweeps in, and nothing
        // else is reported. A check that drifted from the sweep would send the
        // user back to re-scan for something the re-scan refuses to find.
        let text = "Li and Jordan Marlowe met at Jordan Marlowe Holdings about Meridian Works."
        let holdings = span("Jordan Marlowe Holdings", in: text, type: .company)
        let partnerText = "Li, Jordan Marlowe, Meridian Works and Wu were all named."
        let partners = [
            span("Li", in: partnerText, type: .person),
            span("Jordan Marlowe", in: partnerText, type: .person),
            span("Meridian Works", in: partnerText, type: .company),
            span("Wu", in: partnerText, type: .person)
        ]

        let unswept = EntityRescan.unsweptSurfaces(
            in: text,
            confirmed: [holdings],
            knownEntities: partners
        )
        let before = EntityRescan.expand([holdings], in: text)
        let after = EntityRescan.expand([holdings], in: text, knownEntities: partners)
        let swept = Set(after.map { $0.text }).subtracting(before.map { $0.text })

        XCTAssertEqual(Set(unswept), swept)
        XCTAssertEqual(
            Set(unswept),
            ["Jordan Marlowe", "Meridian Works"],
            "the two-letter names stay out, and the mention outside the confirmed span counts"
        )
    }

    // MARK: - Needle safety

    func testShortLatinNeedleIsSkipped() {
        let text = "Li signed. Li paid. Li left."
        let confirmed = [span("Li", in: text, type: .person)]
        XCTAssertEqual(EntityRescan.expand(confirmed, in: text).count, 1)
    }

    func testSingleCJKCharacterNeedleIsSkipped() {
        let text = "王先生到场。王某某未到场。王气愤离去。"
        let confirmed = [span("王", in: text, type: .person)]
        XCTAssertEqual(EntityRescan.expand(confirmed, in: text).count, 1)
    }

    func testTwoCJKCharacterNeedleIsRescanned() {
        let text = "张三到场。张三未付款。"
        let confirmed = [span("张三", in: text, type: .person)]
        XCTAssertEqual(EntityRescan.expand(confirmed, in: text).count, 2)
    }

    func testRoleLabelNeedleIsSkipped() {
        // A user-confirmed span whose surface is a role label must never seed
        // a document-wide rescan.
        let text = "甲方同意付款。甲方并且承诺按期交付。甲方违约时应赔偿。"
        let confirmed = [span("甲方", in: text, type: .company, source: .manual)]
        XCTAssertEqual(EntityRescan.expand(confirmed, in: text).count, 1)
    }

    func testRescanPropagatesSeedSource() {
        let text = "Meridian Works signed. Meridian Works paid."
        let confirmed = [span("Meridian Works", in: text, type: .company, source: .manual)]

        let expanded = EntityRescan.expand(confirmed, in: text)

        XCTAssertEqual(expanded.count, 2)
        XCTAssertTrue(expanded.allSatisfy { $0.source == .manual })
    }

    // MARK: - Alias pairs

    private let cjkContract = """
    股权转让协议

    甲方：杭州快帆科技有限公司（以下简称"快帆科技"）
    乙方：张三

    快帆科技应当在本协议签署后十日内办理变更登记。张三应当配合快帆科技提交材料。
    """

    func testAliasPairBindsShortNameToPrecedingCompany() {
        let confirmed = [
            span("杭州快帆科技有限公司", in: cjkContract, type: .company),
            span("张三", in: cjkContract, type: .person)
        ]

        let pairs = EntityRescan.aliasPairs(in: cjkContract, confirmed: confirmed)

        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.canonical, "杭州快帆科技有限公司")
        XCTAssertEqual(pairs.first?.alias, "快帆科技")
        XCTAssertEqual(pairs.first?.type, .company)
    }

    func testExpandCoversEveryAliasOccurrenceIncludingTheDefinition() {
        let confirmed = [
            span("杭州快帆科技有限公司", in: cjkContract, type: .company),
            span("张三", in: cjkContract, type: .person)
        ]

        let expanded = EntityRescan.expand(confirmed, in: cjkContract)

        // 1 full name + 3 short names (definition site + 2 body mentions)
        // + 2 张三 mentions.
        XCTAssertEqual(expanded.filter { $0.text == "快帆科技" }.count, 3)
        XCTAssertEqual(expanded.filter { $0.text == "张三" }.count, 2)
        XCTAssertEqual(expanded.filter { $0.text == "杭州快帆科技有限公司" }.count, 1)
    }

    func testUnboundAliasIsNotANeedle() {
        // 本协议 is defined for a document title, not for a confirmed entity,
        // so it never becomes a needle.
        let text = "本《股权转让协议》（以下简称\"本协议\"）由张三签署。本协议一式两份，张三执一份。"
        let confirmed = [span("张三", in: text, type: .person)]

        let pairs = EntityRescan.aliasPairs(in: text, confirmed: confirmed)
        let expanded = EntityRescan.expand(confirmed, in: text)

        XCTAssertTrue(pairs.isEmpty)
        XCTAssertFalse(expanded.contains { $0.text == "本协议" })
        XCTAssertEqual(expanded.filter { $0.text == "张三" }.count, 2)
    }

    func testNonDerivedAliasIsSkipped() {
        // 目标公司 is a generic defined term, not derived from the name, and
        // stays unredacted per the DefinedTermScanner philosophy.
        let text = "深圳绿洲实业有限公司（以下简称\"目标公司\"）。目标公司应当配合。"
        let confirmed = [span("深圳绿洲实业有限公司", in: text, type: .company)]

        let pairs = EntityRescan.aliasPairs(in: text, confirmed: confirmed)
        let expanded = EntityRescan.expand(confirmed, in: text)

        XCTAssertTrue(pairs.isEmpty)
        XCTAssertFalse(expanded.contains { $0.text == "目标公司" })
    }

    func testRoleLabelAliasIsSkippedButRealAliasKept() {
        let text = "杭州快帆科技有限公司（以下简称\"快帆科技\"或\"甲方\"）。甲方与快帆科技均指同一主体。"
        let confirmed = [span("杭州快帆科技有限公司", in: text, type: .company)]

        let pairs = EntityRescan.aliasPairs(in: text, confirmed: confirmed)

        XCTAssertEqual(pairs.map { $0.alias }, ["快帆科技"])
    }

    func testEnglishAcronymAliasBindsAndExpands() {
        let text = "International Business Machines (\"IBM\") merged. IBM paid IBM's dues."
        let confirmed = [span("International Business Machines", in: text, type: .company)]

        let pairs = EntityRescan.aliasPairs(in: text, confirmed: confirmed)
        let expanded = EntityRescan.expand(confirmed, in: text)

        XCTAssertEqual(pairs.first?.alias, "IBM")
        XCTAssertEqual(expanded.filter { $0.text == "IBM" }.count, 3)
    }

    func testBindingGapMustBeCleanAndSmall() {
        // A full sentence between the entity and the parenthetical means no
        // binding.
        let text = "杭州快帆科技有限公司是出让方。其他各方（以下简称\"快帆科技\"）不适用。"
        let confirmed = [span("杭州快帆科技有限公司", in: text, type: .company)]

        XCTAssertTrue(EntityRescan.aliasPairs(in: text, confirmed: confirmed).isEmpty)
    }

    func testBindingAllowsClosingQuoteInGap() {
        let text = "甲方：\u{201C}杭州快帆科技有限公司\u{201D}（以下简称\"快帆科技\"）。快帆科技同意。"
        let confirmed = [span("杭州快帆科技有限公司", in: text, type: .company)]

        let pairs = EntityRescan.aliasPairs(in: text, confirmed: confirmed)

        XCTAssertEqual(pairs.first?.alias, "快帆科技")
    }

    // MARK: - Mapping linkage

    private func entry(
        token: String,
        value: String,
        type: EntityType = .company
    ) -> MappingEntry {
        MappingEntry(token: token, value: value, type: type, surfaceText: value, aliases: [])
    }

    func testLinkAliasesStampsCanonicalTokenOnAliasEntry() {
        let mapping = Mapping(
            entries: [
                "{COMPANY_1}": entry(token: "{COMPANY_1}", value: "杭州快帆科技有限公司"),
                "{COMPANY_2}": entry(token: "{COMPANY_2}", value: "快帆科技")
            ],
            createdAtISO8601: "2026-08-30T00:00:00Z",
            sourceFile: "contract.txt"
        )
        let pairs = [AliasPair(canonical: "杭州快帆科技有限公司", alias: "快帆科技", type: .company)]

        let linked = EntityRescan.linkAliases(in: mapping, pairs: pairs)

        XCTAssertEqual(linked.entries["{COMPANY_2}"]?.canonicalToken, "{COMPANY_1}")
        XCTAssertNil(linked.entries["{COMPANY_1}"]?.canonicalToken)
        // Values and tokens untouched: restore semantics unchanged.
        XCTAssertEqual(linked.entries["{COMPANY_2}"]?.value, "快帆科技")
        // The input mapping is not mutated.
        XCTAssertNil(mapping.entries["{COMPANY_2}"]?.canonicalToken)
    }

    func testLinkAliasesLeavesUnrelatedEntriesAlone() {
        let mapping = Mapping(
            entries: [
                "{COMPANY_1}": entry(token: "{COMPANY_1}", value: "Meridian Works, LLC"),
                "{PERSON_1}": entry(token: "{PERSON_1}", value: "Jane Roe", type: .person)
            ],
            createdAtISO8601: "2026-08-30T00:00:00Z",
            sourceFile: "contract.txt"
        )
        let pairs = [AliasPair(canonical: "Meridian Works, LLC", alias: "Meridian Works", type: .company)]

        let linked = EntityRescan.linkAliases(in: mapping, pairs: pairs)

        XCTAssertEqual(linked, mapping, "no alias entry exists, so nothing changes")
    }

    // MARK: - Performance

    func testRescanStaysFastOnALargeDocument() {
        // 120 distinct company names, each mentioned once per block, over 400
        // blocks: roughly 460 KB of text with 120 needles scanned document-wide.
        var names: [String] = []
        for index in 0..<120 {
            names.append("Company Alpha\(index) Beta\(index) Holdings")
        }
        var blocks: [String] = []
        for blockIndex in 0..<400 {
            let name = names[blockIndex % names.count]
            blocks.append(
                "Section \(blockIndex). \(name) shall deliver the goods to the "
                + "warehouse described in Schedule 3 and invoice the buyer within "
                + "thirty days of acceptance, failing which penalties accrue daily."
            )
        }
        let text = blocks.joined(separator: "\n")
        let confirmed = names.map { span($0, in: text, type: .company) }

        let started = Date()
        let expanded = EntityRescan.expand(confirmed, in: text)
        let elapsed = Date().timeIntervalSince(started)

        // Each name occurs at least 3 times (400 blocks over 120 names).
        XCTAssertGreaterThan(expanded.count, confirmed.count * 2)
        // Generous budget: the pass must stay interactive on large documents.
        // Typical wall time on Apple Silicon is well under a second.
        XCTAssertLessThan(elapsed, 5.0, "rescan took \(elapsed)s on a 460 KB document")
    }

    func testUnsweptSurfacesStaysFastAcrossALargeSession() {
        // The handoff runs this check once per ready document against the
        // union of every OTHER document's parties, so the per-call cost is
        // multiplied by the tray size and it runs on the main actor at a
        // button press. This is an extreme single call: a 460 KB document
        // against 600 partner surfaces, 120 of which it actually contains.
        // Cost is one literal scan per distinct surface, so it grows with
        // (document size x distinct parties in the session); a realistic tray
        // of tens-of-KB documents and a few dozen parties lands two orders of
        // magnitude below this. Typical wall time here on Apple Silicon is
        // around 0.3s, so a tray of such documents is the case to watch.
        var names: [String] = []
        for index in 0..<120 {
            names.append("Company Alpha\(index) Beta\(index) Holdings")
        }
        var blocks: [String] = []
        for blockIndex in 0..<400 {
            let name = names[blockIndex % names.count]
            blocks.append(
                "Section \(blockIndex). \(name) shall deliver the goods to the "
                + "warehouse described in Schedule 3 and invoice the buyer within "
                + "thirty days of acceptance, failing which penalties accrue daily."
            )
        }
        let text = blocks.joined(separator: "\n")

        // Partners from the rest of the tray: the 120 the document names, plus
        // 480 parties that appear only in other documents.
        var partners = names.map { span($0, in: text, type: .company) }
        let absentText = (0..<480)
            .map { "Absent Party Gamma\($0) Delta\($0) Limited" }
            .joined(separator: ". ")
        for index in 0..<480 {
            partners.append(
                span("Absent Party Gamma\(index) Delta\(index) Limited", in: absentText, type: .company)
            )
        }

        let started = Date()
        let unswept = EntityRescan.unsweptSurfaces(
            in: text,
            confirmed: [],
            knownEntities: partners
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(unswept.count, 120, "only the parties the document names are reported")
        XCTAssertLessThan(
            elapsed,
            1.0,
            "cross-document check took \(elapsed)s for one document against 600 partner surfaces"
        )
    }
}
