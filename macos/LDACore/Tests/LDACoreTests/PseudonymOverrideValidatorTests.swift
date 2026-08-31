//
//  PseudonymOverrideValidatorTests.swift
//  LDACoreTests
//
//  Unit tests for the pure override validator: user-supplied pseudonym
//  replacement text is accepted only when emitting it verbatim cannot break
//  the literal restore scan, and every rejection carries a typed reason the
//  UI can surface per row.
//
//  House rules: all comments and strings in English. Fixture values may be
//  Chinese. No em-dash and no en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class PseudonymOverrideValidatorTests: XCTestCase {

    private func entry(
        token: String,
        value: String,
        aliases: [String] = []
    ) -> MappingEntry {
        MappingEntry(
            token: token,
            value: value,
            type: .person,
            surfaceText: value,
            aliases: aliases
        )
    }

    // MARK: - Style gate

    func testEmptyOverrideSetPassesUnderEveryStyle() {
        for style in SubstitutionStyle.allCases {
            XCTAssertNoThrow(
                try PseudonymOverrideValidator.validate(
                    overrides: [:],
                    style: style,
                    corpus: ["any natural text"]
                ),
                "an empty override set constrains nothing"
            )
        }
    }

    func testNonPseudonymStylesWithOverridesAreRejected() {
        for style in [SubstitutionStyle.token, .asterisk] {
            XCTAssertThrowsError(
                try PseudonymOverrideValidator.validate(
                    overrides: ["王小明": "借款人"],
                    style: style,
                    corpus: []
                )
            ) { error in
                XCTAssertEqual(
                    error as? PseudonymOverrideError,
                    .styleNotPseudonym(style)
                )
            }
        }
    }

    // MARK: - Shape checks

    func testEmptyReplacementIsRejected() {
        XCTAssertThrowsError(
            try PseudonymOverrideValidator.validate(
                overrides: ["王小明": ""],
                style: .pseudonym,
                corpus: []
            )
        ) { error in
            XCTAssertEqual(
                error as? PseudonymOverrideError,
                .empty(surface: "王小明")
            )
        }
    }

    func testEmptySurfaceIsRejected() {
        XCTAssertThrowsError(
            try PseudonymOverrideValidator.validate(
                overrides: ["": "借款人"],
                style: .pseudonym,
                corpus: []
            )
        ) { error in
            XCTAssertEqual(error as? PseudonymOverrideError, .empty(surface: ""))
        }
    }

    func testReplacementContainingBracesIsRejected() {
        for replacement in ["{借款人}", "借{款人", "借款}人"] {
            XCTAssertThrowsError(
                try PseudonymOverrideValidator.validate(
                    overrides: ["王小明": replacement],
                    style: .pseudonym,
                    corpus: []
                )
            ) { error in
                XCTAssertEqual(
                    error as? PseudonymOverrideError,
                    .containsBraces(surface: "王小明", replacement: replacement)
                )
            }
        }
    }

    // MARK: - Collision checks

    func testDuplicateReplacementAcrossOverridesIsRejected() {
        // Surfaces are validated in sorted order: 李小红 sorts before 王小明,
        // so 王小明 is the pair reported as colliding.
        XCTAssertThrowsError(
            try PseudonymOverrideValidator.validate(
                overrides: ["王小明": "借款人", "李小红": "借款人"],
                style: .pseudonym,
                corpus: []
            )
        ) { error in
            XCTAssertEqual(
                error as? PseudonymOverrideError,
                .collidesWithExistingReplacement(surface: "王小明", replacement: "借款人")
            )
        }
    }

    func testCollisionWithExistingEntryForDifferentSurfaceIsRejected() {
        let existing = entry(token: "借款人", value: "王小明")
        XCTAssertThrowsError(
            try PseudonymOverrideValidator.validate(
                overrides: ["李小红": "借款人"],
                style: .pseudonym,
                corpus: [],
                existingEntries: [existing.token: existing]
            )
        ) { error in
            XCTAssertEqual(
                error as? PseudonymOverrideError,
                .collidesWithExistingReplacement(surface: "李小红", replacement: "借款人")
            )
        }
    }

    func testSameSurfaceReuseOfExistingEntryIsAllowed() {
        // The idempotent re-run: the seed already maps this exact surface to
        // this exact replacement. That is reuse, not a collision.
        let existing = entry(token: "借款人", value: "王小明")
        XCTAssertNoThrow(
            try PseudonymOverrideValidator.validate(
                overrides: ["王小明": "借款人"],
                style: .pseudonym,
                corpus: [],
                existingEntries: [existing.token: existing]
            )
        )
    }

    func testAliasSurfaceReuseOfExistingEntryIsAllowed() {
        let existing = entry(token: "借款人", value: "王小明", aliases: ["小明"])
        XCTAssertNoThrow(
            try PseudonymOverrideValidator.validate(
                overrides: ["小明": "借款人"],
                style: .pseudonym,
                corpus: [],
                existingEntries: [existing.token: existing]
            )
        )
    }

    // MARK: - Natural occurrence

    func testReplacementOccurringInCorpusIsRejected() {
        // Substring semantics, matching the pseudonym uniqueness contract: a
        // replacement occurring anywhere in any session document is rejected.
        XCTAssertThrowsError(
            try PseudonymOverrideValidator.validate(
                overrides: ["杭州西子科技有限公司": "借款人"],
                style: .pseudonym,
                corpus: ["签约方甲。", "本合同项下借款人应按期还款。"]
            )
        ) { error in
            XCTAssertEqual(
                error as? PseudonymOverrideError,
                .occursNaturallyInCorpus(
                    surface: "杭州西子科技有限公司",
                    replacement: "借款人"
                )
            )
        }
    }

    func testValidOverridesPass() {
        XCTAssertNoThrow(
            try PseudonymOverrideValidator.validate(
                overrides: [
                    "杭州西子科技有限公司": "借款人",
                    "王小明": "经办人甲"
                ],
                style: .pseudonym,
                corpus: ["杭州西子科技有限公司委托王小明办理。"]
            )
        )
    }
}
