//
//  PseudonymOverrideTests.swift
//  LDACoreTests
//
//  User-supplied pseudonym replacement text: a caller forces the replacement
//  string for specific surfaces in a pseudonym-style run. The forced text is
//  applied everywhere the surface is tokenized, recorded verbatim in the
//  mapping entry, restored byte-identically by the UNCHANGED Restorer, kept
//  stable across re-runs and park/unpark cycles, and rejected with a typed
//  error whenever emitting it could make the literal restore scan ambiguous.
//
//  House rules: all comments and strings in English. Fixture values may be
//  Chinese. No em-dash and no en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class PseudonymOverrideTests: XCTestCase {

    private let stamp = "2026-08-31T00:00:00Z"

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

    // MARK: - Forced text applies everywhere and restores byte-identically

    func testSessionOverrideAppliesEverywhereAndRestoresByteIdentically() throws {
        let doc1 = "出卖人：杭州西子科技有限公司。经办人：王小明。"
        let doc2 = "杭州西子科技有限公司确认收讫。王小明签字。"
        let documents = [
            SessionDocument(name: "a.txt", text: doc1, spans: [
                span("杭州西子科技有限公司", in: doc1, type: .company),
                span("王小明", in: doc1, type: .person)
            ]),
            SessionDocument(name: "b.txt", text: doc2, spans: [
                span("杭州西子科技有限公司", in: doc2, type: .company),
                span("王小明", in: doc2, type: .person)
            ])
        ]

        let result = try SessionTokenizer.tokenize(
            documents: documents,
            sourceLabel: "session",
            createdAtISO8601: stamp,
            style: .pseudonym,
            overrides: ["杭州西子科技有限公司": "买受人"]
        )

        // The forced text replaces the surface at every site in every
        // document; the unoverridden person still gets a minted pseudonym.
        XCTAssertEqual(result.documents[0].tokenizedText, "出卖人：买受人。经办人：张某。")
        XCTAssertEqual(result.documents[1].tokenizedText, "买受人确认收讫。张某签字。")
        XCTAssertEqual(result.mapping.style, .pseudonym)
        XCTAssertEqual(result.mapping.entries.count, 2)

        // The mapping entry records the forced text verbatim in its
        // token/replacement field, so parked sessions and archives carry it.
        let entry = result.mapping.entries["买受人"]
        XCTAssertEqual(entry?.token, "买受人")
        XCTAssertEqual(entry?.value, "杭州西子科技有限公司")
        XCTAssertEqual(entry?.surfaceText, "杭州西子科技有限公司")

        // The UNCHANGED Restorer round-trips every document byte-identically.
        for (index, original) in [doc1, doc2].enumerated() {
            let restored = Restorer.restore(
                text: result.documents[index].tokenizedText,
                mapping: result.mapping
            )
            XCTAssertEqual(restored.text, original)
            XCTAssertTrue(restored.orphanTokens.isEmpty)
            XCTAssertTrue(restored.ambiguousReplacements.isEmpty)
        }
    }

    func testPersonOverrideRecordsForcedTextVerbatimAndRestores() throws {
        // The acceptance scenario verbatim: a PERSON surface forced to
        // 借款人 is used everywhere the entity was replaced, the mapping
        // entry records exactly that text, and restore is byte-identical.
        let doc = "由王小明提出，王小明确认。"
        let ns = doc as NSString
        let first = ns.range(of: "王小明")
        let second = ns.range(
            of: "王小明",
            options: [],
            range: NSRange(
                location: first.location + first.length,
                length: ns.length - first.location - first.length
            )
        )
        let documents = [
            SessionDocument(name: "a.txt", text: doc, spans: [
                Span(
                    start: first.location,
                    end: first.location + first.length,
                    type: .person,
                    text: "王小明",
                    source: .manual,
                    confidence: 1.0,
                    priority: 10
                ),
                Span(
                    start: second.location,
                    end: second.location + second.length,
                    type: .person,
                    text: "王小明",
                    source: .manual,
                    confidence: 1.0,
                    priority: 10
                )
            ])
        ]

        let result = try SessionTokenizer.tokenize(
            documents: documents,
            sourceLabel: "session",
            createdAtISO8601: stamp,
            style: .pseudonym,
            overrides: ["王小明": "借款人"]
        )

        XCTAssertEqual(result.documents[0].tokenizedText, "由借款人提出，借款人确认。")
        XCTAssertEqual(result.mapping.entries["借款人"]?.token, "借款人")
        XCTAssertEqual(result.mapping.entries["借款人"]?.value, "王小明")

        let restored = Restorer.restore(
            text: result.documents[0].tokenizedText,
            mapping: result.mapping
        )
        XCTAssertEqual(restored.text, doc)
        XCTAssertTrue(restored.orphanTokens.isEmpty)
    }

    func testSingleDocumentOverrideRoundTrip() throws {
        let document = "合同方：杭州西子科技有限公司。"
        let spans = [span("杭州西子科技有限公司", in: document, type: .company)]

        let result = try Tokenizer.tokenize(
            text: document,
            spans: spans,
            sourceFile: "doc.txt",
            createdAtISO8601: stamp,
            style: .pseudonym,
            overrides: ["杭州西子科技有限公司": "买受人"]
        )

        XCTAssertEqual(result.tokenizedText, "合同方：买受人。")
        XCTAssertEqual(result.mapping.entries["买受人"]?.value, "杭州西子科技有限公司")

        let restored = Restorer.restore(text: result.tokenizedText, mapping: result.mapping)
        XCTAssertEqual(restored.text, document)
        XCTAssertTrue(restored.orphanTokens.isEmpty)
    }

    // MARK: - Reservation against the minting sequence

    func testMintedPseudonymsAvoidOverrideReplacementsAcrossDocuments() throws {
        // The override claims 甲公司, the FIRST candidate of the Chinese
        // company sequence, but its surface appears only in document 2. The
        // company minted in document 1 must still skip 甲公司: overrides are
        // reserved before any minting in every document of the session.
        let doc1 = "出卖人：深圳创新科技有限公司。"
        let doc2 = "买受人：杭州西子科技有限公司。"
        let documents = [
            SessionDocument(name: "a.txt", text: doc1, spans: [
                span("深圳创新科技有限公司", in: doc1, type: .company)
            ]),
            SessionDocument(name: "b.txt", text: doc2, spans: [
                span("杭州西子科技有限公司", in: doc2, type: .company)
            ])
        ]

        let result = try SessionTokenizer.tokenize(
            documents: documents,
            sourceLabel: "session",
            createdAtISO8601: stamp,
            style: .pseudonym,
            overrides: ["杭州西子科技有限公司": "甲公司"]
        )

        XCTAssertEqual(result.documents[0].tokenizedText, "出卖人：乙公司。")
        XCTAssertEqual(result.documents[1].tokenizedText, "买受人：甲公司。")

        // Both documents restore byte-identically from the one union mapping.
        for (index, original) in [doc1, doc2].enumerated() {
            let restored = Restorer.restore(
                text: result.documents[index].tokenizedText,
                mapping: result.mapping
            )
            XCTAssertEqual(restored.text, original)
        }
    }

    // MARK: - Typed rejections

    func testOverrideEqualToAnotherEntityReplacementIsRejected() {
        // The seed already uses 张某 for 王小明; forcing 张某 onto a different
        // surface would make two entities share one replacement.
        let seedEntry = MappingEntry(
            token: "张某",
            value: "王小明",
            type: .person,
            surfaceText: "王小明",
            aliases: []
        )
        let seed = Mapping(
            entries: [seedEntry.token: seedEntry],
            createdAtISO8601: stamp,
            sourceFile: "prior.txt",
            style: .pseudonym
        )
        let document = "由李小红签署。"
        let documents = [
            SessionDocument(name: "a.txt", text: document, spans: [
                span("李小红", in: document, type: .person)
            ])
        ]

        XCTAssertThrowsError(
            try SessionTokenizer.tokenize(
                documents: documents,
                sourceLabel: "session",
                createdAtISO8601: stamp,
                seedMapping: seed,
                style: .pseudonym,
                overrides: ["李小红": "张某"]
            )
        ) { error in
            XCTAssertEqual(
                error as? PseudonymOverrideError,
                .collidesWithExistingReplacement(surface: "李小红", replacement: "张某")
            )
        }
    }

    func testOverrideOccurringInCompanionDocumentIsRejected() {
        // The forced text occurs naturally in document 2 (not document 1
        // where the surface lives), so the shared-mapping restore scan could
        // not tell the natural occurrence from a substitution site.
        let doc1 = "由王小明签署。"
        let doc2 = "借款人应当按期还款。"
        let documents = [
            SessionDocument(name: "a.txt", text: doc1, spans: [
                span("王小明", in: doc1, type: .person)
            ]),
            SessionDocument(name: "b.txt", text: doc2, spans: [])
        ]

        XCTAssertThrowsError(
            try SessionTokenizer.tokenize(
                documents: documents,
                sourceLabel: "session",
                createdAtISO8601: stamp,
                style: .pseudonym,
                overrides: ["王小明": "借款人"]
            )
        ) { error in
            XCTAssertEqual(
                error as? PseudonymOverrideError,
                .occursNaturallyInCorpus(surface: "王小明", replacement: "借款人")
            )
        }
    }

    func testEmptyAndBraceOverridesAreRejected() {
        let document = "由王小明签署。"
        let spans = [span("王小明", in: document, type: .person)]

        XCTAssertThrowsError(
            try Tokenizer.tokenize(
                text: document,
                spans: spans,
                sourceFile: "doc.txt",
                createdAtISO8601: stamp,
                style: .pseudonym,
                overrides: ["王小明": ""]
            )
        ) { error in
            XCTAssertEqual(error as? PseudonymOverrideError, .empty(surface: "王小明"))
        }

        XCTAssertThrowsError(
            try Tokenizer.tokenize(
                text: document,
                spans: spans,
                sourceFile: "doc.txt",
                createdAtISO8601: stamp,
                style: .pseudonym,
                overrides: ["王小明": "{借款人}"]
            )
        ) { error in
            XCTAssertEqual(
                error as? PseudonymOverrideError,
                .containsBraces(surface: "王小明", replacement: "{借款人}")
            )
        }
    }

    func testTokenStyleWithOverridesThrowsStyleNotPseudonym() {
        let document = "由王小明签署。"
        let documents = [
            SessionDocument(name: "a.txt", text: document, spans: [
                span("王小明", in: document, type: .person)
            ])
        ]

        XCTAssertThrowsError(
            try SessionTokenizer.tokenize(
                documents: documents,
                sourceLabel: "session",
                createdAtISO8601: stamp,
                style: .token,
                overrides: ["王小明": "借款人"]
            )
        ) { error in
            XCTAssertEqual(
                error as? PseudonymOverrideError,
                .styleNotPseudonym(.token)
            )
        }

        XCTAssertThrowsError(
            try Tokenizer.tokenize(
                text: document,
                spans: [span("王小明", in: document, type: .person)],
                sourceFile: "doc.txt",
                createdAtISO8601: stamp,
                style: .asterisk,
                overrides: ["王小明": "借款人"]
            )
        ) { error in
            XCTAssertEqual(
                error as? PseudonymOverrideError,
                .styleNotPseudonym(.asterisk)
            )
        }
    }

    func testEmptyOverridesUnderTokenStyleMatchPlainTokenize() throws {
        // The throwing entry point with an empty override set is a superset
        // of the plain one: same bytes out, so one call site can serve every
        // style and only constrain itself when overrides are present.
        let document = "Seller: Acme Corp."
        let spans = [span("Acme Corp", in: document, type: .company)]

        let plain = Tokenizer.tokenize(
            text: document,
            spans: spans,
            sourceFile: "doc.txt",
            createdAtISO8601: stamp,
            style: .token
        )
        let viaOverrides = try Tokenizer.tokenize(
            text: document,
            spans: spans,
            sourceFile: "doc.txt",
            createdAtISO8601: stamp,
            style: .token,
            overrides: [:]
        )

        XCTAssertEqual(viaOverrides.tokenizedText, plain.tokenizedText)
        XCTAssertEqual(viaOverrides.mapping, plain.mapping)
    }

    // MARK: - Idempotent re-run

    func testRerunWithSameOverridesIsIdempotent() throws {
        let doc = "出卖人：杭州西子科技有限公司。经办人：王小明。"
        let documents = [
            SessionDocument(name: "a.txt", text: doc, spans: [
                span("杭州西子科技有限公司", in: doc, type: .company),
                span("王小明", in: doc, type: .person)
            ])
        ]
        let overrides = ["杭州西子科技有限公司": "买受人"]

        let first = try SessionTokenizer.tokenize(
            documents: documents,
            sourceLabel: "session",
            createdAtISO8601: stamp,
            style: .pseudonym,
            overrides: overrides
        )
        let second = try SessionTokenizer.tokenize(
            documents: documents,
            sourceLabel: "session",
            createdAtISO8601: stamp,
            seedMapping: first.mapping,
            style: .pseudonym,
            overrides: overrides
        )

        // No re-mint and no duplicate entries: the seeded re-run reuses the
        // override binding and the minted pseudonym as they stand.
        XCTAssertEqual(second.documents[0].tokenizedText, first.documents[0].tokenizedText)
        XCTAssertEqual(second.mapping.entries, first.mapping.entries)
    }

    // MARK: - Park and unpark

    func testOverrideMappingSurvivesParkAndUnpark() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PseudonymOverrideTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("parked.ldaparked")

        let doc = "合同方：杭州西子科技有限公司。"
        let documents = [
            SessionDocument(name: "a.txt", text: doc, spans: [
                span("杭州西子科技有限公司", in: doc, type: .company)
            ])
        ]
        let result = try SessionTokenizer.tokenize(
            documents: documents,
            sourceLabel: "session",
            createdAtISO8601: stamp,
            style: .pseudonym,
            overrides: ["杭州西子科技有限公司": "买受人"]
        )

        let state = ParkedSessionState(mapping: result.mapping, clientLabel: "matter")
        try ParkedSessionStore.save(state, to: url, protection: .passphrase("pw"))
        let loaded = try ParkedSessionStore.load(from: url, protection: .passphrase("pw"))

        // The parked payload carries the mapping entries as they are, so the
        // forced replacement survives verbatim and still restores.
        XCTAssertEqual(loaded, state)
        XCTAssertEqual(loaded.mapping.entries["买受人"]?.value, "杭州西子科技有限公司")

        let restored = Restorer.restore(
            text: result.documents[0].tokenizedText,
            mapping: loaded.mapping
        )
        XCTAssertEqual(restored.text, doc)
        XCTAssertTrue(restored.orphanTokens.isEmpty)
    }
}
