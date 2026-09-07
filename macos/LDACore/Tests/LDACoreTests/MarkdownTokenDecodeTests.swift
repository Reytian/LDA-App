//
//  MarkdownTokenDecodeTests.swift
//  LDACoreTests
//
//  R6: the mapped decode the seam verifier reads restore sites through. Two
//  properties matter and neither is obvious from the call site.
//
//  1. The mapped decode and the plain decode must produce the SAME text. The
//     plain one is what restore applies; the mapped one is what verification
//     judges. If they ever disagree, verification clears a document restore
//     would corrupt.
//  2. The offset map must land a decoded range back on the exact original
//     bytes it came from, escape backslashes included, so a site can be
//     compared with the piece tokenization emitted there.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class MarkdownTokenDecodeTests: XCTestCase {

    /// Inputs that exercise every branch: nothing to decode, one escape, two
    /// escapes, an escape at each end, a backslash that is not part of a
    /// token, a lookalike that the grammar rejects, and non-ASCII around the
    /// escape so the per-unit map is not trivially the identity.
    private static let inputs: [String] = [
        "",
        "no tokens here",
        "{PERSON_1} is already exact",
        #"Fill in {PERSON\_1}."#,
        #"{PERSON\_1} and {COMPANY\_2} and {DATE_3}"#,
        #"{PERSON\_1}"#,
        #"tail {PERSON\_12}"#,
        #"a stray \_ underscore"#,
        #"{person\_1} is the wrong case"#,
        #"{PERSON\_}"#,
        #"甲方 {PERSON\_1} 与乙方 {COMPANY\_1} 签署"#,
        "emoji \u{1F600} then {PERSON\\_1}"
    ]

    // MARK: - The two decodes agree

    func testTheMappedDecodeProducesTheSameTextAsThePlainDecode() {
        for input in Self.inputs {
            XCTAssertEqual(
                MarkdownTokenDecode.decode(input).text,
                MarkdownTokenDecode.decodedText(input),
                "mapped and plain decode disagree on \(String(reflecting: input))"
            )
            XCTAssertEqual(
                MarkdownTokenDecode.decodedText(input),
                PlaceholderForensics.decodeMarkdownEscapedTokens(in: input),
                "the public restore entry point must stay the same decode"
            )
        }
    }

    func testTheDecodeRewritesOnlyEscapedExactTokens() {
        XCTAssertEqual(MarkdownTokenDecode.decodedText(#"Fill in {PERSON\_1}."#), "Fill in {PERSON_1}.")
        XCTAssertEqual(
            MarkdownTokenDecode.decodedText(#"a stray \_ underscore"#),
            #"a stray \_ underscore"#,
            "a backslash outside a token shape is left alone"
        )
        XCTAssertEqual(
            MarkdownTokenDecode.decodedText(#"{person\_1}"#),
            #"{person\_1}"#,
            "the grammar is upper case, so this is not an exact token"
        )
    }

    // MARK: - The per-unit map

    func testEveryDecodeKeepsThePerUnitInvariant() {
        for input in Self.inputs {
            let decoded = MarkdownTokenDecode.decode(input)
            XCTAssertTrue(decoded.isConsistent, "for \(String(reflecting: input))")
            XCTAssertEqual(decoded.originalLength, (input as NSString).length)
        }
    }

    func testTheMapIsStrictlyIncreasingAndInBounds() {
        for input in Self.inputs {
            let indexes = MarkdownTokenDecode.decode(input).originalIndexes
            for (previous, next) in zip(indexes, indexes.dropFirst()) {
                XCTAssertLessThan(previous, next, "for \(String(reflecting: input))")
            }
            for index in indexes {
                XCTAssertTrue(
                    (0..<(input as NSString).length).contains(index),
                    "for \(String(reflecting: input))"
                )
            }
        }
    }

    /// A decoded token maps back to the ORIGINAL bytes it was built from, the
    /// escape backslash included, so the range covers the whole literal a
    /// verifier has to judge.
    func testADecodedTokenMapsBackOverItsEscape() throws {
        let original = #"Fill in {PERSON\_1}."#
        let decoded = MarkdownTokenDecode.decode(original)
        let site = (decoded.text as NSString).range(of: "{PERSON_1}")

        let mapped = try XCTUnwrap(decoded.originalRange(of: site))

        XCTAssertEqual((original as NSString).substring(with: mapped), #"{PERSON\_1}"#)
        XCTAssertEqual(mapped.length, site.length + 1, "the escape backslash is inside the mapped range")
    }

    /// A range AFTER an earlier escape is shifted back by exactly the escapes
    /// that preceded it. Guessing the shift is what R6 forbids.
    func testARangeAfterAnEscapeMapsBackToItsOriginalOffset() throws {
        let original = #"{PERSON\_1} then Acme {COMPANY_9} ends"#
        let decoded = MarkdownTokenDecode.decode(original)
        let site = (decoded.text as NSString).range(of: "{COMPANY_9}")

        let mapped = try XCTUnwrap(decoded.originalRange(of: site))

        XCTAssertEqual((original as NSString).substring(with: mapped), "{COMPANY_9}")
        XCTAssertEqual(mapped.location, site.location + 1)
        XCTAssertEqual(mapped.length, site.length)
    }

    func testAnOutOfBoundsRangeMapsToNil() {
        let decoded = MarkdownTokenDecode.decode(#"Fill in {PERSON\_1}."#)
        let length = (decoded.text as NSString).length

        XCTAssertNil(decoded.originalRange(of: NSRange(location: length, length: 1)))
        XCTAssertNil(decoded.originalRange(of: NSRange(location: 0, length: length + 1)))
    }

    // MARK: - Reservation reads both spellings

    func testReservedLiteralsCoverTheRawAndTheDecodedSpelling() {
        XCTAssertEqual(
            SourceTokenLiterals.literals(in: #"Fill in {PERSON\_1}."#),
            ["{PERSON_1}"],
            "the escaped literal is reserved under the token it decodes to"
        )
        XCTAssertEqual(
            SourceTokenLiterals.literals(in: #"{COMPANY_2} and {PERSON\_1}"#),
            ["{COMPANY_2}", "{PERSON_1}"]
        )
        XCTAssertTrue(SourceTokenLiterals.literals(in: "nothing token shaped here").isEmpty)
    }

    // MARK: - Bounded work

    /// The decode is one linear pass with a bounded pattern. A long run of
    /// backslashes and braces must not make it superlinear.
    func testTheDecodeStaysBoundedOnAdversarialInput() {
        let adversarial = String(repeating: #"{PERSON\"#, count: 4000) + "_1}"

        let started = Date()
        let decoded = MarkdownTokenDecode.decode(adversarial)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(decoded.isConsistent)
        XCTAssertLessThan(elapsed, 2.0, "the decode must not backtrack, took \(elapsed)s")
    }
}
