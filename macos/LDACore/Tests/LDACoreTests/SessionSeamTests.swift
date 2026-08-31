//
//  SessionSeamTests.swift
//  LDACoreTests
//
//  The cross-document half of the literal-restore seam defect.
//
//  PseudonymSeamGuard closes the seam shapes inside the document being
//  tokenized, but SessionTokenizer folds document by document. A pseudonym
//  minted for document 1 is REUSED in document 2 straight out of the seed
//  mapping, which skips the mint loop and therefore every seam check. Where
//  that reused replacement meets document 2's own text, the join can spell a
//  DIFFERENT replacement of the shared mapping, and the longest-match-wins
//  literal scan then restores the wrong entity over the site.
//
//  It cannot be fixed by reminting inside document 2: the surface has to keep
//  one identity across every document of the session. The lever is a session
//  level verification pass over the committed assignment plus a coordinated
//  remint of the offending replacement in ALL documents.
//
//  House rules: all comments and strings in English. Fixture strings and
//  generated pseudonyms may be Chinese. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class SessionSeamTests: XCTestCase {

    private let timestamp = "2026-08-31T00:00:00Z"

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

    /// The shared address is the first entity of document 1, so it mints
    /// 某地址A, and twenty six more addresses in document 1 push the sequence
    /// all the way to 某地址AA. Document 1 has no seam: the shared address is
    /// followed by a full stop there, so every mint-time check passes.
    ///
    /// Document 2 names the same address and follows it with "A座". In the
    /// redacted document 2 the reused 某地址A therefore butts up against an
    /// "A", spelling 某地址AA, which belongs to document 1's twenty seventh
    /// address. Nothing in the fold ever looks at that seam: the surface is
    /// reused from the seed mapping, so document 2's mint loop skips it.
    private func exhaustingSessionFixture() -> (
        documents: [SessionDocument],
        sharedAddress: String
    ) {
        let sharedAddress = "北京市朝阳区建国路1号"

        var documentOne = "第一送达地址：\(sharedAddress)。"
        for index in 2...27 {
            documentOne += "第\(index)送达地址：上海市浦东新区世纪大道\(index)号。"
        }
        var spansOne = [span(sharedAddress, in: documentOne, type: .address)]
        for index in 2...27 {
            spansOne.append(
                span("上海市浦东新区世纪大道\(index)号", in: documentOne, type: .address)
            )
        }

        let documentTwo = "送达地址：\(sharedAddress)A座，请查收。"
        let spansTwo = [span(sharedAddress, in: documentTwo, type: .address)]

        return (
            [
                SessionDocument(name: "doc1.txt", text: documentOne, spans: spansOne),
                SessionDocument(name: "doc2.txt", text: documentTwo, spans: spansTwo)
            ],
            sharedAddress
        )
    }

    /// Every document of a pseudonym session must restore to itself byte for
    /// byte under the shared mapping. Before the session seam pass, document
    /// 2 restored its address site to document 1's twenty seventh address and
    /// swallowed the adjacent building letter.
    func testEveryDocumentOfASessionRestoresToItselfAcrossASeamOnlyDocumentTwoHas() {
        let fixture = exhaustingSessionFixture()

        let session = SessionTokenizer.tokenize(
            documents: fixture.documents,
            sourceLabel: "session",
            createdAtISO8601: timestamp,
            style: .pseudonym
        )

        for (index, document) in fixture.documents.enumerated() {
            let restored = Restorer.restore(
                text: session.documents[index].tokenizedText,
                mapping: session.mapping
            )
            XCTAssertEqual(
                restored.text,
                document.text,
                "document \(index + 1) did not restore to itself"
            )
        }
    }

    /// The repair must not be "give document 2 its own pseudonym": the whole
    /// point of a session is that one party reads the same in every document.
    /// The shared address must resolve to exactly one replacement, and that
    /// replacement must be what both tokenized documents actually carry.
    func testTheSharedPartyKeepsOneIdentityAcrossTheWholeSession() {
        let fixture = exhaustingSessionFixture()

        let session = SessionTokenizer.tokenize(
            documents: fixture.documents,
            sourceLabel: "session",
            createdAtISO8601: timestamp,
            style: .pseudonym
        )

        let sharedReplacements = Set(
            session.mapping.entries.values
                .filter { $0.value == fixture.sharedAddress }
                .map { $0.token }
        )
        XCTAssertEqual(sharedReplacements.count, 1)

        guard let shared = sharedReplacements.first else {
            return XCTFail("the shared address must have a replacement")
        }
        for document in session.documents {
            XCTAssertTrue(
                document.tokenizedText.contains(shared),
                "\(document.name) does not carry the shared replacement"
            )
        }
    }

    /// Nothing may be left un-redacted by the repair: the surface text of
    /// every tokenized entity must be gone from every tokenized document.
    func testTheRepairNeverLeavesASurfaceUnredacted() {
        let fixture = exhaustingSessionFixture()

        let session = SessionTokenizer.tokenize(
            documents: fixture.documents,
            sourceLabel: "session",
            createdAtISO8601: timestamp,
            style: .pseudonym
        )

        for (index, document) in fixture.documents.enumerated() {
            let tokenized = session.documents[index].tokenizedText
            for span in document.spans {
                XCTAssertFalse(
                    tokenized.contains(span.text),
                    "\(span.text) survived tokenization of document \(index + 1)"
                )
            }
        }
    }

    // MARK: - The retroactive shape: a later document gives an old seam meaning

    /// Document 1 emits its only address as 某地址A directly in front of an
    /// "A座", so the redacted document 1 spells 某地址AA from the moment it is
    /// written. That is harmless while nothing owns 某地址AA, and every mint
    /// time check in document 1 passes: the string is not in use yet.
    ///
    /// Document 2 then names twenty six more addresses, which walks the
    /// sequence to 某地址AA. Its mint time checks look at document 2's own
    /// seams and at the RAW text of document 1, and raw document 1 does not
    /// contain 某地址AA; only the redacted one does. So the pseudonym is
    /// minted and document 1, long since emitted, starts mis-restoring.
    private func retroactiveSessionFixture() -> [SessionDocument] {
        let seamAddress = "北京市朝阳区建国路1号"
        let documentOne = "送达地址：\(seamAddress)A座，请查收。"
        let spansOne = [span(seamAddress, in: documentOne, type: .address)]

        var documentTwo = "地址清单。"
        for index in 1...26 {
            documentTwo += "第\(index)项：上海市浦东新区世纪大道\(index)号。"
        }
        var spansTwo: [Span] = []
        for index in 1...26 {
            spansTwo.append(
                span("上海市浦东新区世纪大道\(index)号", in: documentTwo, type: .address)
            )
        }

        return [
            SessionDocument(name: "doc1.txt", text: documentOne, spans: spansOne),
            SessionDocument(name: "doc2.txt", text: documentTwo, spans: spansTwo)
        ]
    }

    func testALaterDocumentsMintNeverGivesMeaningToASeamAlreadyEmitted() {
        let documents = retroactiveSessionFixture()

        let session = SessionTokenizer.tokenize(
            documents: documents,
            sourceLabel: "session",
            createdAtISO8601: timestamp,
            style: .pseudonym
        )

        for (index, document) in documents.enumerated() {
            let restored = Restorer.restore(
                text: session.documents[index].tokenizedText,
                mapping: session.mapping
            )
            XCTAssertEqual(
                restored.text,
                document.text,
                "document \(index + 1) did not restore to itself"
            )
        }
        XCTAssertTrue(session.unresolvedSeams.isEmpty)
    }

    // MARK: - Contract of the repair pass itself

    /// A clean session must come back with no warning and, because the
    /// repair only ever fires on a detected disagreement, byte for byte what
    /// the plain fold produced before this pass existed.
    func testACleanSessionReportsNoUnresolvedSeams() {
        let documentOne = "出卖人：深圳创新科技有限公司。经办人：王小明。"
        let documentTwo = "买受人：杭州西子科技有限公司，联系王小明。"
        let documents = [
            SessionDocument(
                name: "doc1.txt",
                text: documentOne,
                spans: [
                    span("深圳创新科技有限公司", in: documentOne, type: .company),
                    span("王小明", in: documentOne, type: .person)
                ]
            ),
            SessionDocument(
                name: "doc2.txt",
                text: documentTwo,
                spans: [
                    span("杭州西子科技有限公司", in: documentTwo, type: .company),
                    span("王小明", in: documentTwo, type: .person)
                ]
            )
        ]

        let session = SessionTokenizer.tokenize(
            documents: documents,
            sourceLabel: "session",
            createdAtISO8601: timestamp,
            style: .pseudonym
        )

        XCTAssertTrue(session.unresolvedSeams.isEmpty)
        XCTAssertEqual(session.documents[0].tokenizedText, "出卖人：甲公司。经办人：张某。")
        XCTAssertEqual(session.documents[1].tokenizedText, "买受人：乙公司，联系张某。")
        for (index, document) in documents.enumerated() {
            let restored = Restorer.restore(
                text: session.documents[index].tokenizedText,
                mapping: session.mapping
            )
            XCTAssertEqual(restored.text, document.text)
        }
    }

    /// The repair must be a pure function of the input, or a rebuild of the
    /// same session would rename parties for no reason.
    func testRepairIsDeterministicAcrossRuns() {
        let fixture = exhaustingSessionFixture()

        let first = SessionTokenizer.tokenize(
            documents: fixture.documents,
            sourceLabel: "session",
            createdAtISO8601: timestamp,
            style: .pseudonym
        )
        let second = SessionTokenizer.tokenize(
            documents: fixture.documents,
            sourceLabel: "session",
            createdAtISO8601: timestamp,
            style: .pseudonym
        )

        XCTAssertEqual(
            first.documents.map { $0.tokenizedText },
            second.documents.map { $0.tokenizedText }
        )
        XCTAssertEqual(
            first.mapping.entries.mapValues { $0.token },
            second.mapping.entries.mapValues { $0.token }
        )
    }

    /// The verification pass is one render plus one restore scan per document
    /// per fold, and a clean session folds exactly once, so a session with
    /// many entities must not change complexity class. Sized to match the
    /// single document mint guard budget in RestorerPrefixAdjacencyTests
    /// (300 entities, measured at roughly 0.9s there), spread over six
    /// documents. The bound is a blowup smoke guard, not a tight budget.
    func testSeamVerificationStaysFastOnALargeSession() {
        var documents: [SessionDocument] = []
        for docIndex in 1...6 {
            var text = "第\(docIndex)号送达清单。"
            for index in 1...50 {
                let serial = docIndex * 100 + index
                text += "第\(serial)项：上海市浦东新区世纪大道\(serial)号，联系人王小明\(serial)。"
            }
            var spans: [Span] = []
            for index in 1...50 {
                let serial = docIndex * 100 + index
                spans.append(
                    span("上海市浦东新区世纪大道\(serial)号", in: text, type: .address)
                )
                spans.append(span("王小明\(serial)", in: text, type: .person))
            }
            documents.append(
                SessionDocument(name: "doc\(docIndex).txt", text: text, spans: spans)
            )
        }

        let started = Date()
        let session = SessionTokenizer.tokenize(
            documents: documents,
            sourceLabel: "session",
            createdAtISO8601: timestamp,
            style: .pseudonym
        )
        let elapsed = Date().timeIntervalSince(started)

        for (index, document) in documents.enumerated() {
            let restored = Restorer.restore(
                text: session.documents[index].tokenizedText,
                mapping: session.mapping
            )
            XCTAssertEqual(restored.text, document.text)
        }
        XCTAssertTrue(session.unresolvedSeams.isEmpty)
        XCTAssertLessThan(elapsed, 20.0)
    }
}
