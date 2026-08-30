//
//  TokenRewriteCharacterizationTests.swift
//  LDACoreTests
//
//  Characterization of the restore failure the output-style work is fixing.
//
//  The Restorer is deliberately a pure deterministic token scanner: it only
//  substitutes strings that match TokenGrammar.placeholderPattern exactly.
//  An external AI editing the redacted text routinely rewrites "{COMPANY_1}"
//  into "[COMPANY_1]", "COMPANY_1", "{COMPANY 1}", a fullwidth-brace variant,
//  or a translation. Every rewritten token is a silently unrestorable site:
//  the value never comes back, restoredCount stays 0 for it, and at best the
//  forensics scan FLAGS the shape for the user (it never substitutes).
//
//  These tests document that baseline so the pseudonym style has a measured
//  failure to beat. They assert TODAY'S behavior on purpose:
//    - no rewritten shape is ever restored (byte-identical text out),
//    - ASCII near-miss shapes are flagged as suspects,
//    - fullwidth-brace and translated shapes are not even flagged (the worst
//      case: silent loss with no report at all).
//  If later work improves brace-token recovery these expectations may be
//  adjusted, but the byte-identical semantics for well-formed tokens and the
//  flag-don't-guess contract must never be weakened.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

// MARK: - Simulated AI rewriter (shared with the style robustness tests)

/// A deterministic stand-in for an external AI that edits redacted text.
///
/// Real models treat "{COMPANY_1}" as markup and rewrite it (bracket swap,
/// brace strip, underscore to space, fullwidth punctuation) while leaving
/// natural-language names alone because they read as names, not markup. The
/// simulator reproduces exactly that: every grammar token is mangled by a
/// per-type rule, and every non-token character passes through verbatim.
enum AIRewriteSimulator {

    /// Rewrite every "{TYPE_N}" token in the text with a per-type mangling:
    ///   COMPANY  -> "[COMPANY_N]"        (bracket swap)
    ///   PERSON   -> "PERSON_N"           (braces stripped)
    ///   ADDRESS  -> "{ADDRESS N}"        (underscore to space)
    ///   DATE     -> fullwidth braces     (CJK-style punctuation)
    ///   others   -> "[TYPE_N]"           (bracket swap)
    /// Non-token text is copied through unchanged, the way a model preserves
    /// natural names.
    static func rewriteTokens(in text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: TokenGrammar.placeholderPattern
        ) else {
            return text
        }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, options: [], range: fullRange)

        var result = ""
        var cursor = 0
        for match in matches {
            let range = match.range
            if range.location > cursor {
                result += nsText.substring(
                    with: NSRange(location: cursor, length: range.location - cursor)
                )
            }
            result += mangle(nsText.substring(with: range))
            cursor = range.location + range.length
        }
        if cursor < nsText.length {
            result += nsText.substring(from: cursor)
        }
        return result
    }

    /// The per-type mangling for one exact token "{TYPE_N}".
    private static func mangle(_ token: String) -> String {
        let inner = String(token.dropFirst().dropLast())
        if inner.hasPrefix("COMPANY") {
            return "[\(inner)]"
        }
        if inner.hasPrefix("PERSON") {
            return inner
        }
        if inner.hasPrefix("ADDRESS") {
            return "{\(inner.replacingOccurrences(of: "_", with: " "))}"
        }
        if inner.hasPrefix("DATE") {
            return "\u{FF5B}\(inner)\u{FF5D}"
        }
        return "[\(inner)]"
    }
}

// MARK: - Characterization tests

final class TokenRewriteCharacterizationTests: XCTestCase {

    /// One mapping entry per rewrite shape under test.
    private func makeMapping() -> Mapping {
        let entries = [
            MappingEntry(
                token: "{COMPANY_1}",
                value: "Acme Holdings Ltd",
                type: .company,
                surfaceText: "Acme Holdings Ltd",
                aliases: []
            ),
            MappingEntry(
                token: "{PERSON_1}",
                value: "John Smith",
                type: .person,
                surfaceText: "John Smith",
                aliases: []
            ),
            MappingEntry(
                token: "{ADDRESS_1}",
                value: "12 Harbour Road",
                type: .address,
                surfaceText: "12 Harbour Road",
                aliases: []
            ),
            MappingEntry(
                token: "{DATE_1}",
                value: "12 March 2026",
                type: .date,
                surfaceText: "12 March 2026",
                aliases: []
            )
        ]
        return Mapping(
            entries: Dictionary(uniqueKeysWithValues: entries.map { ($0.token, $0) }),
            createdAtISO8601: "2026-08-30T00:00:00Z",
            sourceFile: "doc.txt"
        )
    }

    // MARK: Control: the well-formed token round trip stays byte-identical

    func testWellFormedTokensRestoreByteIdentical() {
        let redacted = "By {PERSON_1} of {COMPANY_1}, {ADDRESS_1}, on {DATE_1}."
        let result = Restorer.restore(text: redacted, mapping: makeMapping())
        XCTAssertEqual(
            result.text,
            "By John Smith of Acme Holdings Ltd, 12 Harbour Road, on 12 March 2026."
        )
        XCTAssertEqual(result.restoredCount, 4)
        XCTAssertTrue(result.orphanTokens.isEmpty)
        XCTAssertTrue(result.suspectPlaceholders.isEmpty)
    }

    // MARK: Failure mode 1: bracket swap. Not restored, but flagged.

    func testBracketRewriteIsNotRestoredOnlyFlagged() {
        let result = Restorer.restore(text: "Sold to [COMPANY_1] today.", mapping: makeMapping())
        XCTAssertEqual(result.text, "Sold to [COMPANY_1] today.")
        XCTAssertEqual(result.restoredCount, 0)
        XCTAssertEqual(result.suspectPlaceholders, ["[COMPANY_1]"])
    }

    // MARK: Failure mode 2: braces stripped. Not restored, but flagged.

    func testBareRewriteIsNotRestoredOnlyFlagged() {
        let result = Restorer.restore(text: "Sold to COMPANY_1 today.", mapping: makeMapping())
        XCTAssertEqual(result.text, "Sold to COMPANY_1 today.")
        XCTAssertEqual(result.restoredCount, 0)
        XCTAssertEqual(result.suspectPlaceholders, ["COMPANY_1"])
    }

    // MARK: Failure mode 3: underscore to space. Not restored, but flagged.

    func testSpaceRewriteIsNotRestoredOnlyFlagged() {
        let result = Restorer.restore(text: "Sold to {COMPANY 1} today.", mapping: makeMapping())
        XCTAssertEqual(result.text, "Sold to {COMPANY 1} today.")
        XCTAssertEqual(result.restoredCount, 0)
        XCTAssertEqual(result.suspectPlaceholders, ["{COMPANY 1}"])
    }

    // MARK: Failure mode 4: fullwidth braces. Not restored; only the bare
    // core is flagged (the fullwidth pair itself is invisible to forensics).

    func testFullwidthBraceRewriteIsNotRestored() {
        let text = "Sold to \u{FF5B}COMPANY_1\u{FF5D} today."
        let result = Restorer.restore(text: text, mapping: makeMapping())
        XCTAssertEqual(result.text, text)
        XCTAssertEqual(result.restoredCount, 0)
        // The forensics bracket class covers ASCII pairs only, but the
        // bare-token pattern still matches the COMPANY_1 core between the
        // fullwidth braces, so the shape is reported as a bare token rather
        // than as the fullwidth pair the AI actually produced.
        XCTAssertEqual(result.suspectPlaceholders, ["COMPANY_1"])
    }

    // MARK: Failure mode 5: translated type. Not restored AND not flagged.

    func testTranslatedTokenIsSilentlyLost() {
        let text = "Sold to {\u{516C}\u{53F8}_1} today."
        let result = Restorer.restore(text: text, mapping: makeMapping())
        XCTAssertEqual(result.text, text)
        XCTAssertEqual(result.restoredCount, 0)
        XCTAssertTrue(
            result.suspectPlaceholders.isEmpty,
            "A translated TYPE is outside the mapping's TYPE set, so nothing flags it"
        )
    }

    // MARK: The measured degradation across a whole simulated AI round trip

    func testSimulatedAIRoundTripLosesEveryRewrittenToken() {
        let redacted = "By {PERSON_1} of {COMPANY_1}, {ADDRESS_1}, on {DATE_1}."
        let afterAI = AIRewriteSimulator.rewriteTokens(in: redacted)
        XCTAssertEqual(
            afterAI,
            "By PERSON_1 of [COMPANY_1], {ADDRESS 1}, on \u{FF5B}DATE_1\u{FF5D}."
        )

        let result = Restorer.restore(text: afterAI, mapping: makeMapping())

        // Baseline being fixed: ZERO of the four entities restore, and the
        // output still contains every mangled shape instead of the values.
        XCTAssertEqual(result.restoredCount, 0)
        XCTAssertEqual(result.text, afterAI)
        XCTAssertFalse(result.text.contains("John Smith"))
        XCTAssertFalse(result.text.contains("Acme Holdings Ltd"))

        // The forensics scan flags the ASCII near-miss shapes (and the bare
        // core between the fullwidth braces), so the user at least hears
        // about these four. Nothing is ever substituted for them.
        XCTAssertEqual(
            Set(result.suspectPlaceholders),
            Set(["PERSON_1", "[COMPANY_1]", "{ADDRESS 1}", "DATE_1"])
        )
    }
}
