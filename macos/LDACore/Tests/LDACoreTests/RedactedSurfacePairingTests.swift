//
//  RedactedSurfacePairingTests.swift
//  LDACoreTests
//
//  The public pairing seam over Tokenizer's emit walk, on its own: which
//  offsets of a redacted rendering are the original document's own text.
//
//  What is pinned here is mostly what the type REFUSES. Its one claim is that
//  a carried-through run is the same characters in both texts, and the claim
//  rests entirely on the re-rendering being byte identical to the text that
//  was actually shown. So the tests feed it renderings it cannot reproduce
//  and span sets whose arithmetic does not add up, and require nil every
//  time: a half-trusted map would be read as "safe to protect", which is the
//  answer that mints a mapping keyed on a replacement.
//
//  House rules: English only. Fixture strings may be Chinese. No em-dash or
//  en-dash-as-separator.
//

import XCTest
@testable import LDACore

final class RedactedSurfacePairingTests: XCTestCase {

    // MARK: - Fixture

    /// A contract line with two values to redact and one the scan missed (the
    /// email). Both replacements are longer than what they replace, so every
    /// offset after them differs between the two surfaces.
    private static let original =
        "买方 北京朝阳科技有限公司 与 张三 签署本协议，邮箱 li@x.example，双方各执一份，均无异议。"

    private static func range(of surface: String, in text: String = original) -> NSRange {
        let found = (text as NSString).range(of: surface)
        precondition(found.location != NSNotFound, "fixture surface missing: \(surface)")
        return found
    }

    private static func span(_ surface: String, _ type: EntityType) -> Span {
        let found = range(of: surface)
        return Span(
            start: found.location,
            end: NSMaxRange(found),
            type: type,
            text: surface,
            source: .llm,
            confidence: 0.9,
            priority: 30
        )
    }

    private static var spans: [Span] {
        [span("北京朝阳科技有限公司", .company), span("张三", .person)]
    }

    private static func tokenize(
        _ spans: [Span],
        style: SubstitutionStyle = .token
    ) -> TokenizeResult {
        Tokenizer.tokenize(
            text: original,
            spans: spans,
            sourceFile: "fixture",
            createdAtISO8601: "fixture",
            style: style
        )
    }

    private static func pair(
        _ spans: [Span],
        _ result: TokenizeResult,
        redacted: String? = nil
    ) -> RedactedSurfacePairing? {
        RedactedSurfacePairing.pair(
            original: original,
            redacted: redacted ?? result.tokenizedText,
            spans: spans,
            mapping: result.mapping
        )
    }

    // MARK: - Building

    func testPairingTilesTheRenderingAndEveryCarriedRunAgreesWithTheOriginal() throws {
        let spans = Self.spans
        let result = Self.tokenize(spans)
        let pairing = try XCTUnwrap(Self.pair(spans, result))

        XCTAssertEqual(pairing.redactedLength, (result.tokenizedText as NSString).length)
        XCTAssertEqual(pairing.originalLength, (Self.original as NSString).length)

        // The runs tile the rendering: no gap, no overlap, in order.
        var cursor = 0
        for run in pairing.runs {
            XCTAssertEqual(run.redacted.location, cursor, "runs must tile the rendering")
            XCTAssertGreaterThan(run.redacted.length, 0, "an empty run describes nothing")
            cursor = NSMaxRange(run.redacted)
        }
        XCTAssertEqual(cursor, pairing.redactedLength)

        // And a carried-through run really is the same characters in both
        // texts, which is what makes reading the original at its range safe.
        let redacted = result.tokenizedText as NSString
        let source = Self.original as NSString
        for run in pairing.runs where run.origin == .carriedThrough {
            XCTAssertEqual(run.redacted.length, run.original.length)
            XCTAssertEqual(
                redacted.substring(with: run.redacted),
                source.substring(with: run.original)
            )
        }
        XCTAssertEqual(
            pairing.runs.filter { $0.origin == .replacement }.count, 2,
            "one run per emitted replacement"
        )
        // A replacement run pairs with the span it stands for, whose length
        // has nothing to do with the run's own.
        let company = try XCTUnwrap(pairing.runs.first { $0.origin == .replacement })
        XCTAssertEqual(company.original, Self.range(of: "北京朝阳科技有限公司"))
        XCTAssertNotEqual(company.redacted.length, company.original.length)
    }

    /// The byte-identity precondition is the whole proof, so it has to have
    /// teeth: a rendering that is not the one the walk produces pairs with
    /// nothing. (That the walk and Tokenizer's emit agree byte for byte is
    /// pinned by RestorerPrefixAdjacencyTests.)
    func testPairingRefusesARenderingItCannotReproduce() {
        let spans = Self.spans
        let result = Self.tokenize(spans)

        for broken in [
            result.tokenizedText.replacingOccurrences(of: "签署", with: "签订"),
            result.tokenizedText + "。",
            String(result.tokenizedText.dropLast()),
            "{COMPANY_1}",
            ""
        ] {
            XCTAssertNil(
                Self.pair(spans, result, redacted: broken),
                "paired a rendering the walk does not produce: \(broken)"
            )
        }
    }

    /// A mapping that does not name the replacement emitted for a surface
    /// cannot describe the rendering either. The walk then copies the surface
    /// through verbatim, which is not what the redacted text holds.
    func testPairingRefusesAMappingThatDoesNotDescribeTheRendering() {
        let spans = Self.spans
        let result = Self.tokenize(spans)
        var stripped = result
        stripped.mapping.entries = [:]

        XCTAssertNil(Self.pair(spans, stripped, redacted: result.tokenizedText))
    }

    /// An overlapping span set renders the same text (both the walk and
    /// Tokenizer drop the contained span) yet produces no piece for it, so
    /// the run arithmetic cannot be trusted and the pairing refuses. The
    /// alternative would be reproducing Tokenizer's longest-wins rule here,
    /// in a second place, which is how the two would drift apart.
    func testPairingRefusesOverlappingSpans() {
        let contained = Self.range(of: "朝阳科技")
        let spans = Self.spans + [
            Span(
                start: contained.location,
                end: NSMaxRange(contained),
                type: .company,
                text: "朝阳科技",
                source: .llm,
                confidence: 0.9,
                priority: 30
            )
        ]
        let result = Self.tokenize(spans)
        XCTAssertFalse(
            result.tokenizedText.contains("朝阳科技"),
            "the containing span won, so the rendering is the same one"
        )
        XCTAssertNil(Self.pair(spans, result))
    }

    /// Span order is the caller's convenience, not part of the contract: the
    /// walk sorts, exactly as Tokenizer's emit does.
    func testPairingDoesNotDependOnTheOrderSpansArriveIn() throws {
        let spans = Self.spans
        let result = Self.tokenize(spans)
        let forward = try XCTUnwrap(Self.pair(spans, result))
        let reversed = try XCTUnwrap(Self.pair(spans.reversed(), result))
        XCTAssertEqual(forward, reversed)
    }

    /// A document with nothing redacted is its own rendering, so all of it is
    /// the document's own text.
    func testAnUnredactedRenderingIsEntirelyCarriedThrough() throws {
        let result = Self.tokenize([])
        XCTAssertEqual(result.tokenizedText, Self.original)
        let pairing = try XCTUnwrap(Self.pair([], result))
        XCTAssertEqual(pairing.runs.count, 1)
        XCTAssertEqual(pairing.runs.first?.origin, .carriedThrough)
        XCTAssertEqual(
            pairing.resolve(selection: NSRange(location: 0, length: pairing.redactedLength)),
            .carriedThrough(NSRange(location: 0, length: pairing.originalLength))
        )
    }

    func testEveryStylesRenderingPairs() throws {
        for style in [SubstitutionStyle.token, .pseudonym, .asterisk] {
            let spans = Self.spans
            let result = Self.tokenize(spans, style: style)
            let pairing = try XCTUnwrap(
                Self.pair(spans, result),
                "\(style) rendering did not pair"
            )
            let email = (result.tokenizedText as NSString).range(of: "li@x.example")
            XCTAssertEqual(
                pairing.resolve(selection: email),
                .carriedThrough(Self.range(of: "li@x.example")),
                "\(style): the missed value must still be reachable"
            )
        }
    }

    // MARK: - Resolving

    func testResolveDistinguishesCarriedTextFromReplacementsAndBoundaries() throws {
        let spans = Self.spans
        let result = Self.tokenize(spans)
        let redacted = result.tokenizedText as NSString
        let pairing = try XCTUnwrap(Self.pair(spans, result))

        let token = redacted.range(of: "{COMPANY_1}")
        XCTAssertNotEqual(token.location, NSNotFound)

        // Inside a replacement, whole or partial.
        XCTAssertEqual(pairing.resolve(selection: token), .replacement)
        XCTAssertEqual(
            pairing.resolve(selection: NSRange(location: token.location + 1, length: 4)),
            .replacement
        )

        // Straddling either edge: part document text, part stand-in, so not a
        // value the document holds anywhere.
        XCTAssertEqual(
            pairing.resolve(selection: NSRange(location: token.location - 1, length: 3)),
            .replacement,
            "a selection that starts before the replacement still touches it"
        )
        XCTAssertEqual(
            pairing.resolve(selection: NSRange(location: NSMaxRange(token) - 2, length: 4)),
            .replacement,
            "and one that runs past its end"
        )
        XCTAssertEqual(
            pairing.resolve(selection: NSRange(location: 0, length: pairing.redactedLength)),
            .replacement,
            "selecting everything selects the stand-ins too"
        )

        // Carried-through text, translated into the original's offsets.
        let email = redacted.range(of: "li@x.example")
        let resolved = pairing.resolve(selection: email)
        XCTAssertEqual(resolved, .carriedThrough(Self.range(of: "li@x.example")))
        guard case .carriedThrough(let mapped) = resolved else {
            return XCTFail("the missed email must resolve to the original")
        }
        XCTAssertEqual((Self.original as NSString).substring(with: mapped), "li@x.example")
        XCTAssertNotEqual(
            mapped.location, email.location,
            "the fixture must actually shift, or this proves nothing"
        )

        // The character that ends exactly where a replacement begins is still
        // the document's own text: the ranges are half open.
        XCTAssertEqual(
            pairing.resolve(selection: NSRange(location: token.location - 1, length: 1)),
            .carriedThrough(
                NSRange(location: Self.range(of: "北京朝阳科技有限公司").location - 1, length: 1)
            )
        )
        XCTAssertEqual(
            pairing.resolve(selection: NSRange(location: NSMaxRange(token), length: 1)),
            .carriedThrough(
                NSRange(location: NSMaxRange(Self.range(of: "北京朝阳科技有限公司")), length: 1)
            )
        )

        // No answer at all rather than a wrong one.
        for nonsense in [
            NSRange(location: 0, length: 0),
            NSRange(location: pairing.redactedLength, length: 1),
            NSRange(location: pairing.redactedLength - 1, length: 5),
            NSRange(location: NSNotFound, length: 2),
            NSRange(location: -1, length: 2)
        ] {
            XCTAssertEqual(
                pairing.resolve(selection: nonsense), .undecidable,
                "resolved a nonsense range: \(nonsense)"
            )
        }
    }
}
