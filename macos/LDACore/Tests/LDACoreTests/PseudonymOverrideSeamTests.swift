//
//  PseudonymOverrideSeamTests.swift
//  LDACoreTests
//
//  Minted pseudonyms are kept clear of seams by PseudonymSeamGuard: a
//  candidate that the redacted document would spell where it was never
//  emitted, or that the text next to its own sites completes into a longer
//  replacement, is skipped for the next candidate. User-supplied overrides
//  used to reach the mint path without any of that. The override validator
//  only compared replacement STRINGS to each other (a strict prefix relation),
//  and two overrides can be seam partners without being prefixes of one
//  another when the completing text comes from the document BEFORE the site.
//
//  The shape: 代理人 and 甲方代理人 are neither prefix nor suffix relations the
//  string check catches, and neither occurs in the corpus. Emitting 代理人 for
//  a company that the document introduces as "甲方<company>" makes the redacted
//  text read 甲方代理人, which the longest-match restore scan attributes to the
//  other entity, erasing the company and naming the wrong party.
//
//  Overrides are finite and user-supplied, so the fix is to reject them. The
//  rule is keyed on what the document actually spells at actual emission
//  sites, so it never feeds back into the unbounded mint loop.
//
//  House rules: all comments and strings in English. Fixture values may be
//  Chinese. No em-dash and no en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class PseudonymOverrideSeamTests: XCTestCase {

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

    private let seamDocument =
        "本案由甲方北京华辰科技有限公司承办，另由上海云图律师事务所协办。"

    private var seamOverrides: [String: String] {
        [
            "北京华辰科技有限公司": "代理人",
            "上海云图律师事务所": "甲方代理人"
        ]
    }

    // MARK: - The preceding-text seam

    /// The reported shape. The document's own 甲方 completes the emitted 代理人
    /// into the other override's 甲方代理人, so the site is not attributable and
    /// the override set must be refused up front.
    func testPrecedingTextSeamBetweenTwoOverridesIsRejected() {
        XCTAssertThrowsError(
            try PseudonymOverrideValidator.validate(
                overrides: seamOverrides,
                style: .pseudonym,
                corpus: [seamDocument]
            )
        ) { error in
            XCTAssertEqual(
                error as? PseudonymOverrideError,
                .seamSpellsAnotherReplacement(
                    surface: "北京华辰科技有限公司",
                    replacement: "代理人",
                    other: "甲方代理人"
                )
            )
        }
    }

    /// The same set reaching Tokenizer must be refused there too: the public
    /// throwing entry point is the only door overrides come through.
    func testTokenizeRefusesThePrecedingTextSeamOverrideSet() {
        XCTAssertThrowsError(
            try Tokenizer.tokenize(
                text: seamDocument,
                spans: [
                    span("北京华辰科技有限公司", in: seamDocument, type: .company),
                    span("上海云图律师事务所", in: seamDocument, type: .company)
                ],
                sourceFile: "doc.txt",
                createdAtISO8601: stamp,
                style: .pseudonym,
                overrides: seamOverrides
            )
        ) { error in
            XCTAssertTrue(error is PseudonymOverrideError, "got \(error)")
        }
    }

    /// The seam partner may equally be a seed mapping entry rather than
    /// another override: the same document text completes the forced 代理人
    /// into a replacement an earlier document already spent.
    func testPrecedingTextSeamAgainstASeedEntryIsRejected() {
        let seed: [String: MappingEntry] = [
            "甲方代理人": MappingEntry(
                token: "甲方代理人",
                value: "上海云图律师事务所",
                type: .company,
                surfaceText: "上海云图律师事务所",
                aliases: []
            )
        ]

        XCTAssertThrowsError(
            try PseudonymOverrideValidator.validate(
                overrides: ["北京华辰科技有限公司": "代理人"],
                style: .pseudonym,
                corpus: [seamDocument],
                existingEntries: seed
            )
        ) { error in
            XCTAssertEqual(
                error as? PseudonymOverrideError,
                .seamSpellsAnotherReplacement(
                    surface: "北京华辰科技有限公司",
                    replacement: "代理人",
                    other: "甲方代理人"
                )
            )
        }
    }

    /// The stealing replacement can be the override's OWN text, spelled early
    /// across the left seam. 甲乙甲乙 repeats with period two, so a document
    /// whose preceding word ends in 甲乙 already spells the replacement two
    /// characters before the site. The scan takes the early match, and the
    /// real site restores nothing. The corpus check cannot see this: the
    /// ORIGINAL text does not contain 甲乙甲乙 anywhere.
    func testSeamSpellingTheOverrideItselfBeforeItsSiteIsRejected() {
        let document = "由甲乙北京华辰科技有限公司承办。"
        XCTAssertFalse(
            document.contains("甲乙甲乙"),
            "fixture: only the redacted rendering may spell the replacement"
        )

        XCTAssertThrowsError(
            try PseudonymOverrideValidator.validate(
                overrides: ["北京华辰科技有限公司": "甲乙甲乙"],
                style: .pseudonym,
                corpus: [document]
            )
        ) { error in
            switch error as? PseudonymOverrideError {
            case .seamSpellsAnotherReplacement(let surface, let replacement, _):
                XCTAssertEqual(surface, "北京华辰科技有限公司")
                XCTAssertEqual(replacement, "甲乙甲乙")
            default:
                XCTFail("expected a seam rejection, got \(error)")
            }
        }
    }

    // MARK: - The following-text seam

    /// The mirror direction: the text AFTER the site completes the emitted
    /// replacement into a longer one. A strict prefix relation between two
    /// override strings is already refused by prefixOfAnotherReplacement, and
    /// that behavior must not regress.
    func testFollowingTextSeamKeepsThePrefixRejection() {
        XCTAssertThrowsError(
            try PseudonymOverrideValidator.validate(
                overrides: ["北京华辰科技有限公司": "代理", "上海云图律师事务所": "代理人"],
                style: .pseudonym,
                corpus: ["本案由北京华辰科技有限公司人承办，另由上海云图律师事务所协办。"]
            )
        ) { error in
            XCTAssertEqual(
                error as? PseudonymOverrideError,
                .prefixOfAnotherReplacement(
                    surface: "北京华辰科技有限公司",
                    replacement: "代理",
                    other: "代理人"
                )
            )
        }
    }

    // MARK: - No over-rejection

    /// An override set with no seam must still pass. The rule keys on what the
    /// document spells at emission sites, so unrelated text sharing characters
    /// with a replacement is not a conflict.
    func testCleanOverrideSetIsStillAccepted() throws {
        let document = "本案由甲方北京华辰科技有限公司承办，另由上海云图律师事务所协办。"
        try PseudonymOverrideValidator.validate(
            overrides: [
                "北京华辰科技有限公司": "承办单位",
                "上海云图律师事务所": "协办单位"
            ],
            style: .pseudonym,
            corpus: [document]
        )
    }

    /// A clean override set still round-trips through tokenize and restore.
    func testCleanOverrideSetRoundTrips() throws {
        let document = "本案由甲方北京华辰科技有限公司承办。"
        let tokenized = try Tokenizer.tokenize(
            text: document,
            spans: [span("北京华辰科技有限公司", in: document, type: .company)],
            sourceFile: "doc.txt",
            createdAtISO8601: stamp,
            style: .pseudonym,
            overrides: ["北京华辰科技有限公司": "承办单位"]
        )
        XCTAssertEqual(tokenized.tokenizedText, "本案由甲方承办单位承办。")

        let restored = Restorer.restore(
            text: tokenized.tokenizedText,
            mapping: tokenized.mapping
        )
        XCTAssertEqual(restored.text, document)
        XCTAssertTrue(restored.orphanTokens.isEmpty)
    }

    /// The same replacement forced for the same surface twice over is reuse,
    /// not a self-seam: an override must never conflict with itself.
    func testAnOverrideDoesNotConflictWithItsOwnSites() throws {
        let document = "北京华辰科技有限公司与北京华辰科技有限公司签署。"
        try PseudonymOverrideValidator.validate(
            overrides: ["北京华辰科技有限公司": "承办单位"],
            style: .pseudonym,
            corpus: [document]
        )
    }

    // MARK: - Minting still terminates

    /// The guard added for overrides must never become a mint-time rule. A
    /// rule keyed on the prefix RELATION between replacement strings blocks
    /// every longer candidate once the short ones are spent, and the mint loop
    /// spins forever. Minting many same-type entities next to text that
    /// completes each candidate is the shape that would hang; it must finish
    /// and produce distinct replacements.
    func testMintingManySimilarEntitiesStillTerminates() {
        var document = ""
        for index in 1...60 {
            document += "第\(index)承办方上海云图第\(index)号有限公司甲。"
        }
        let spans = (1...60).map {
            span("上海云图第\($0)号有限公司", in: document, type: .company)
        }

        let tokenized = Tokenizer.tokenize(
            text: document,
            spans: spans,
            sourceFile: "doc.txt",
            createdAtISO8601: stamp,
            style: .pseudonym
        )

        let replacements = Set(tokenized.mapping.entries.values.map(\.token))
        XCTAssertEqual(replacements.count, 60, "each entity needs its own pseudonym")

        let restored = Restorer.restore(
            text: tokenized.tokenizedText,
            mapping: tokenized.mapping
        )
        XCTAssertEqual(restored.text, document)
    }
}
