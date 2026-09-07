//
//  DocxSplitFieldInstructionTests.swift
//  LDACoreTests
//
//  Review finding 5 (2026-09-06): a complex field's instruction is one
//  logical string that Word is free to split across several w:instrText runs,
//  and it does, at any character. The scrub judged each run ALONE, so a
//  HYPERLINK whose scheme and address landed in different runs was half
//  rewritten: run one became HYPERLINK "about:blank and run two kept
//  client@example.test" in full. The neutralized scheme made the output look
//  scrubbed while the whole address rode out in the next run.
//
//  The instruction must be assembled across the runs of one field, scrubbed
//  as the single string it is, and projected back onto those runs so the run
//  structure survives. Splits at the scheme, inside the address, at the
//  closing quote, and three ways.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class DocxSplitFieldInstructionTests: XCTestCase {

    private static let email = "client@example.test"

    // MARK: - Fixtures

    /// A complex field whose instruction is split across `segments`, in the
    /// begin / instruction / separate / result / end shape Word writes.
    private func field(instruction segments: [String], element: String = "w:instrText") -> String {
        let runs = segments
            .map { "<w:r><\(element)>\(xmlEncode($0))</\(element)></w:r>" }
            .joined()
        return "<w:p><w:r><w:fldChar w:fldCharType=\"begin\"/></w:r>"
            + runs
            + "<w:r><w:fldChar w:fldCharType=\"separate\"/></w:r>"
            + "<w:r><w:t>Email client</w:t></w:r>"
            + "<w:r><w:fldChar w:fldCharType=\"end\"/></w:r></w:p>"
    }

    /// The instruction text the part still carries, assembled back across its
    /// runs: what a consumer of the field actually reads.
    private func assembledInstruction(in xml: String, element: String = "w:instrText") -> String {
        let pattern = "<\(element)\\b[^>]*>([^<]*)</\(element)>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return "" }
        let ns = xml as NSString
        return regex
            .matches(in: xml, range: NSRange(location: 0, length: ns.length))
            .map { xmlDecode(ns.substring(with: $0.range(at: 1))) }
            .joined()
    }

    private func assertScrubbed(
        _ segments: [String],
        element: String = "w:instrText",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let scrubbed = DocxMarkupScrub.scrubRedactedPart(field(instruction: segments, element: element))
        XCTAssertFalse(
            scrubbed.contains(Self.email),
            "the complete address survives the scrub: \(scrubbed)",
            file: file,
            line: line
        )
        XCTAssertEqual(
            assembledInstruction(in: scrubbed, element: element),
            " HYPERLINK \"about:blank\" ",
            "the assembled instruction must read as one neutralized target",
            file: file,
            line: line
        )
        XCTAssertTrue(
            scrubbed.contains("<w:t>Email client</w:t>"),
            "the field result is ordinary run text and is left to the run redactor",
            file: file,
            line: line
        )
    }

    // MARK: - The splits

    /// The review's probe: the split falls between the scheme and the address.
    func testASplitAtTheSchemeRemovesTheWholeAddress() {
        assertScrubbed([" HYPERLINK \"mailto:", "\(Self.email)\" "])
    }

    /// The split falls inside the address itself, so neither run holds a
    /// recognizable target on its own.
    func testASplitInsideTheAddressRemovesTheWholeAddress() {
        assertScrubbed([" HYPERLINK \"mailto:client@ex", "ample.test\" "])
    }

    /// The split falls just before the closing quote, so run one looks like a
    /// complete unterminated target and run two is punctuation.
    func testASplitAtTheClosingQuoteRemovesTheWholeAddress() {
        assertScrubbed([" HYPERLINK \"mailto:\(Self.email)", "\" "])
    }

    /// Three runs, with the scheme itself divided.
    func testAThreeWaySplitRemovesTheWholeAddress() {
        assertScrubbed([" HYPERLINK \"mai", "lto:client@examp", "le.test\" "])
    }

    /// A tracked deletion spells its instruction w:delInstrText, and splits
    /// the same way.
    func testASplitTrackedDeletionInstructionIsScrubbedToo() {
        assertScrubbed(
            [" HYPERLINK \"mailto:", "\(Self.email)\" "],
            element: "w:delInstrText"
        )
    }

    /// A tel: target splits and neutralizes exactly like mailto:.
    func testASplitTelephoneTargetIsNeutralized() {
        let scrubbed = DocxMarkupScrub.scrubRedactedPart(
            field(instruction: [" HYPERLINK \"tel:+8613", "800138000\" "])
        )
        XCTAssertFalse(scrubbed.contains("13800138000"), scrubbed)
        XCTAssertEqual(assembledInstruction(in: scrubbed), " HYPERLINK \"about:blank\" ")
    }

    // MARK: - What must not change

    /// One unsplit instruction still scrubs exactly as it did before, so the
    /// assembled pass is a superset of the per-run one.
    func testAnUnsplitInstructionIsUnchangedInBehaviour() {
        assertScrubbed([" HYPERLINK \"mailto:\(Self.email)\" "])
    }

    /// A field whose instruction carries no sensitive target is copied
    /// through byte for byte, split or not.
    func testASplitPageFieldIsLeftAlone() {
        let xml = field(instruction: [" PA", "GEREF _Toc1 \\h "])
        XCTAssertEqual(DocxMarkupScrub.scrubRedactedPart(xml), xml)
    }

    /// Two fields in one paragraph are separate instructions: assembling
    /// across the field boundary would let one field's text change another's.
    func testTwoAdjacentFieldsAreAssembledSeparately() {
        let xml = "<w:p><w:r><w:fldChar w:fldCharType=\"begin\"/></w:r>"
            + "<w:r><w:instrText> HYPERLINK \"mailto:</w:instrText></w:r>"
            + "<w:r><w:fldChar w:fldCharType=\"end\"/></w:r>"
            + "<w:r><w:fldChar w:fldCharType=\"begin\"/></w:r>"
            + "<w:r><w:instrText>\(xmlEncode(Self.email))\" </w:instrText></w:r>"
            + "<w:r><w:fldChar w:fldCharType=\"end\"/></w:r></w:p>"
        let scrubbed = DocxMarkupScrub.scrubRedactedPart(xml)

        // The first field's dangling scheme is neutralized on its own, and the
        // second field's run is not pulled into it. A bare address in an
        // instruction with no scheme is a different gap (this pass rewrites
        // mailto:/tel: TARGETS, and w:instrText is not run text, so nothing
        // rewrites it); assembling across the field boundary to reach it would
        // let one field's instruction edit another field's runs.
        XCTAssertTrue(scrubbed.contains("about:blank"), scrubbed)
        XCTAssertFalse(scrubbed.contains("mailto:"), scrubbed)
        XCTAssertTrue(scrubbed.contains("\(xmlEncode(Self.email))\" "), scrubbed)
    }

    /// An instruction whose quotes are entity-escaped, the shape a w:instr
    /// attribute uses, still neutralizes across a split.
    func testASplitWithEscapedQuotesIsNeutralized() {
        let scrubbed = DocxMarkupScrub.scrubRedactedPart(
            "<w:p><w:r><w:fldChar w:fldCharType=\"begin\"/></w:r>"
                + "<w:r><w:instrText> HYPERLINK &quot;mailto:</w:instrText></w:r>"
                + "<w:r><w:instrText>\(Self.email)&quot; </w:instrText></w:r>"
                + "<w:r><w:fldChar w:fldCharType=\"end\"/></w:r></w:p>"
        )
        XCTAssertFalse(scrubbed.contains(Self.email), scrubbed)
        XCTAssertEqual(assembledInstruction(in: scrubbed), " HYPERLINK \"about:blank\" ")
    }
}
