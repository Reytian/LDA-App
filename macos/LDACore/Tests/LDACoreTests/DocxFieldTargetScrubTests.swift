//
//  DocxFieldTargetScrubTests.swift
//  LDACoreTests
//
//  Review R3 (2026-09-07): assembling a split field instruction fixed the
//  split case but the scrub still matched RAW XML with a pattern that ended a
//  target at the first apostrophe, quote or space. Two shapes leaked:
//
//    HYPERLINK "mail&#116;o:client@example.test"   survived untouched
//    HYPERLINK "mailto:o'brien@example.test"       became
//    HYPERLINK "about:blank'brien@example.test"
//
//  The first is the ordinary mailto: scheme: XML expands the character
//  reference before any consumer reads the instruction, so the pattern looked
//  for a scheme that is not spelled in the bytes. The second is a legal and
//  common email local part, and the rewrite kept the identifying half of it
//  while reporting a successful export.
//
//  A field instruction is a sequence of arguments, and a quoted argument ends
//  at its own closing quote, not at the first quote of either style. So the
//  scrub decodes the instruction, finds targets on the DECODED text with the
//  instruction's real delimiters, replaces the WHOLE target, and projects the
//  edits back onto the raw bytes.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class DocxFieldTargetScrubTests: XCTestCase {

    private static let email = "client@example.test"
    private static let apostropheLocalPart = "o'brien@example.test"
    private static let neutralized = " HYPERLINK \"about:blank\" "

    // MARK: - Fixtures

    /// A complex field whose instruction runs carry `segments` VERBATIM, so a
    /// fixture can spell a character reference the way the reviewer's package
    /// does. DocxSplitFieldInstructionTests encodes its segments instead,
    /// which is why an encoded scheme was never exercised there.
    private func field(rawInstruction segments: [String]) -> String {
        let runs = segments
            .map { "<w:r><w:instrText>\($0)</w:instrText></w:r>" }
            .joined()
        return "<w:p><w:r><w:fldChar w:fldCharType=\"begin\"/></w:r>"
            + runs
            + "<w:r><w:fldChar w:fldCharType=\"separate\"/></w:r>"
            + "<w:r><w:t>Email client</w:t></w:r>"
            + "<w:r><w:fldChar w:fldCharType=\"end\"/></w:r></w:p>"
    }

    /// A simple field, whose whole instruction lives in one w:instr attribute.
    private func simpleField(rawInstruction instruction: String) -> String {
        "<w:p><w:fldSimple w:instr=\"\(instruction)\"><w:r><w:t>Email client</w:t></w:r></w:fldSimple></w:p>"
    }

    /// The instruction a consumer of the field actually reads: assembled back
    /// across its runs and decoded.
    private func assembledInstruction(in xml: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<w:instrText\\b[^>]*>([^<]*)</w:instrText>") else {
            return ""
        }
        let ns = xml as NSString
        return regex
            .matches(in: xml, range: NSRange(location: 0, length: ns.length))
            .map { xmlDecode(ns.substring(with: $0.range(at: 1))) }
            .joined()
    }

    /// The decoded instruction of a simple field.
    private func simpleInstruction(in xml: String) -> String {
        guard let value = DocxAttributes.value("w:instr", in: xml) else { return "" }
        return xmlDecode(value)
    }

    // MARK: - The two leaks

    /// The reviewer's escaped-scheme package: the scheme's "t" is written as
    /// a decimal character reference and split across two runs exactly as the
    /// probe writes it. Nothing was rewritten and the whole address shipped.
    func testAnEncodedSchemeTargetIsRemovedEntirely() {
        let scrubbed = DocxMarkupScrub.scrubRedactedPart(
            field(rawInstruction: [" HYPERLINK \"mail&#116;o:", "\(Self.email)\" "])
        )
        XCTAssertFalse(scrubbed.contains(Self.email), "the complete address survives the scrub: \(scrubbed)")
        XCTAssertEqual(assembledInstruction(in: scrubbed), Self.neutralized)
    }

    /// The same scheme spelled with a hex character reference.
    func testAHexEncodedSchemeTargetIsRemovedEntirely() {
        let scrubbed = DocxMarkupScrub.scrubRedactedPart(
            field(rawInstruction: [" HYPERLINK \"&#x6D;ailto:\(Self.email)\" "])
        )
        XCTAssertFalse(scrubbed.contains(Self.email), scrubbed)
        XCTAssertEqual(assembledInstruction(in: scrubbed), Self.neutralized)
    }

    /// The reviewer's apostrophe package: a double-quoted target whose local
    /// part contains an apostrophe. The old pattern stopped there and left
    /// "about:blank'brien@example.test" in the export.
    func testAnApostropheAddressIsRemovedEntirely() {
        let scrubbed = DocxMarkupScrub.scrubRedactedPart(
            field(rawInstruction: [" HYPERLINK \"mailto:o'", "brien@example.test\" "])
        )
        XCTAssertFalse(
            scrubbed.contains("brien@example.test"),
            "the identifying half of the address survives: \(scrubbed)"
        )
        XCTAssertEqual(assembledInstruction(in: scrubbed), Self.neutralized)
    }

    // MARK: - The instruction's real delimiters

    /// An unquoted target ends at whitespace, and the switch after it survives.
    func testAnUnquotedTargetEndsAtWhitespace() {
        let scrubbed = DocxMarkupScrub.scrubRedactedPart(
            field(rawInstruction: [" HYPERLINK mailto:\(Self.email) \\t "])
        )
        XCTAssertFalse(scrubbed.contains(Self.email), scrubbed)
        XCTAssertEqual(assembledInstruction(in: scrubbed), " HYPERLINK about:blank \\t ")
    }

    /// A single-quoted target ends at its closing single quote, so a double
    /// quote inside it is part of the address and the whole target goes.
    func testASingleQuotedTargetEndsAtItsClosingQuote() {
        let scrubbed = DocxMarkupScrub.scrubRedactedPart(
            field(rawInstruction: [" HYPERLINK 'mailto:\(Self.email)' "])
        )
        XCTAssertFalse(scrubbed.contains(Self.email), scrubbed)
        XCTAssertEqual(assembledInstruction(in: scrubbed), " HYPERLINK 'about:blank' ")
    }

    /// A tel: target with an apostrophe-free but quoted argument, split the
    /// way Word splits one.
    func testATelTargetIsRemovedEntirely() {
        let scrubbed = DocxMarkupScrub.scrubRedactedPart(
            field(rawInstruction: [" HYPERLINK \"te&#108;:+8613", "800138000\" "])
        )
        // Asserted on the ASSEMBLED instruction: the fixture splits the number
        // across two runs, so searching the raw XML for it would pass without
        // anything having been rewritten.
        XCTAssertFalse(assembledInstruction(in: scrubbed).contains("13800138000"), scrubbed)
        XCTAssertEqual(assembledInstruction(in: scrubbed), Self.neutralized)
    }

    // MARK: - What must not change

    /// An http link is not a sensitive target and is copied through byte for
    /// byte, switches and all.
    func testAnHttpLinkIsLeftUntouched() {
        let xml = field(rawInstruction: [" HYPERLINK \"https://example.com/terms\" \\o \"Terms\" "])
        XCTAssertEqual(DocxMarkupScrub.scrubRedactedPart(xml), xml)
    }

    /// A host whose name merely ENDS in "tel" is not a tel: target. The scheme
    /// match keeps its word boundary, so widening the target's END must not
    /// widen what counts as a scheme.
    func testAnHttpHostEndingInTelIsLeftUntouched() {
        let xml = field(rawInstruction: [" HYPERLINK \"http://hotel:8080/rooms\" "])
        XCTAssertEqual(DocxMarkupScrub.scrubRedactedPart(xml), xml)
    }

    // MARK: - The simple-field attribute path

    /// The same encoded scheme inside a w:instr attribute, whose instruction
    /// spells its own quotes as &quot;.
    func testASimpleFieldWithAnEncodedSchemeIsRemovedEntirely() {
        let scrubbed = DocxMarkupScrub.scrubRedactedPart(
            simpleField(rawInstruction: " HYPERLINK &quot;mail&#116;o:\(Self.email)&quot; ")
        )
        XCTAssertFalse(scrubbed.contains(Self.email), scrubbed)
        XCTAssertEqual(simpleInstruction(in: scrubbed), " HYPERLINK \"about:blank\" ")
    }

    /// An apostrophe address inside a w:instr attribute, where the apostrophe
    /// is itself entity-escaped.
    func testASimpleFieldApostropheAddressIsRemovedEntirely() {
        let scrubbed = DocxMarkupScrub.scrubRedactedPart(
            simpleField(rawInstruction: " HYPERLINK &quot;mailto:o&apos;brien@example.test&quot; ")
        )
        XCTAssertFalse(scrubbed.contains("brien@example.test"), scrubbed)
        XCTAssertEqual(simpleInstruction(in: scrubbed), " HYPERLINK \"about:blank\" ")
    }

    /// A raw apostrophe inside a double-quoted w:instr attribute is legal XML
    /// and must not truncate the target either.
    func testASimpleFieldRawApostropheAddressIsRemovedEntirely() {
        let scrubbed = DocxMarkupScrub.scrubRedactedPart(
            simpleField(rawInstruction: " HYPERLINK &quot;mailto:\(Self.apostropheLocalPart)&quot; ")
        )
        XCTAssertFalse(scrubbed.contains("brien@example.test"), scrubbed)
        XCTAssertEqual(simpleInstruction(in: scrubbed), " HYPERLINK \"about:blank\" ")
    }
}
