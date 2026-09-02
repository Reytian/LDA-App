//
//  DocxMarkupScrubTests.swift
//  LDACoreTests
//
//  Unit pins for DocxMarkupScrub: the field-instruction and authorship
//  rewrites must cover every spelling Word and other producers emit (either
//  quote style, literal or entity-escaped quotes, upper-case schemes, the
//  tracked-deletion instruction element) and must leave everything else,
//  including visible run text, byte for byte.
//
//  House rules: all comments and strings in English. Fixture values may be
//  Chinese. No em-dash and no en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class DocxMarkupScrubTests: XCTestCase {

    func testNeutralizesFieldTargetsInEverySpelling() {
        let xml = "<w:p>"
            + "<w:fldSimple w:instr=' HYPERLINK \"mailto:a@example.com\" '><w:r><w:t>x</w:t></w:r></w:fldSimple>"
            + "<w:fldSimple w:instr=\" HYPERLINK &quot;tel:+12125550147&quot; \\t \"><w:r><w:t>y</w:t></w:r></w:fldSimple>"
            + "<w:r><w:instrText xml:space=\"preserve\"> HYPERLINK &quot;MAILTO:b@example.com&quot; \\o &quot;tip&quot; </w:instrText></w:r>"
            + "<w:r><w:delInstrText> HYPERLINK \"mailto:c@example.com\" </w:delInstrText></w:r>"
            + "</w:p>"

        let out = DocxMarkupScrub.neutralizeFieldTargets(xml)

        XCTAssertFalse(out.contains("example.com"), out)
        XCTAssertFalse(out.contains("+12125550147"), out)
        XCTAssertEqual(out.components(separatedBy: "about:blank").count, 5, "four targets neutralized: \(out)")
        XCTAssertTrue(out.contains("w:instr=' HYPERLINK \"about:blank\" '"), "single-quoted attribute keeps its quotes: \(out)")
        XCTAssertTrue(out.contains("&quot;about:blank&quot; \\t "), "the switch after an entity-quoted target survives: \(out)")
        XCTAssertTrue(out.contains("\\o &quot;tip&quot;"), "switches after the target survive: \(out)")
        XCTAssertTrue(out.contains("<w:t>x</w:t>") && out.contains("<w:t>y</w:t>"), "display text is untouched")
    }

    func testLeavesOtherInstructionsAndRunTextUntouched() {
        let xml = "<w:p>"
            + "<w:fldSimple w:instr=\" PAGE \"><w:r><w:t>1</w:t></w:r></w:fldSimple>"
            + "<w:r><w:instrText> HYPERLINK \"https://example.com/a?mailto=1\" </w:instrText></w:r>"
            + "<w:r><w:t>Write to mailto:visible@example.com in the text</w:t></w:r>"
            + "</w:p>"

        XCTAssertEqual(DocxMarkupScrub.neutralizeFieldTargets(xml), xml)
    }

    func testBlankAttributesHandlesBothQuoteStylesAndKeepsTheRest() {
        let xml = "<w:ins w:id=\"1\" w:author=\"张三\" w:date=\"d\"/>"
            + "<w:del w:id='2' w:author='O&quot;Brien' w:initials='OB'/>"
            + "<w:comment w:initials=\"LS\" w:author=\"李四\"><w:p><w:r><w:t>author: 王五</w:t></w:r></w:p></w:comment>"

        let out = DocxMarkupScrub.blankAttributes(DocxMarkupScrub.authorAttributes, in: xml)

        XCTAssertEqual(
            out,
            "<w:ins w:id=\"1\" w:author=\"\" w:date=\"d\"/>"
                + "<w:del w:id='2' w:author=\"\" w:initials=\"\"/>"
                + "<w:comment w:initials=\"\" w:author=\"\"><w:p><w:r><w:t>author: 王五</w:t></w:r></w:p></w:comment>"
        )
    }

    func testPeopleScrubBlanksNamesAndKeepsProviderIds() {
        let xml = "<w15:people xmlns:w15=\"\(DocxTestPackage.w15Namespace)\">"
            + "<w15:person w15:author=\"李四\"><w15:presenceInfo w15:providerId=\"AD\" w15:userId=\"S::li@example.com::1\"/></w15:person>"
            + "</w15:people>"

        let out = DocxMarkupScrub.scrubPeoplePart(xml)

        XCTAssertEqual(
            out,
            "<w15:people xmlns:w15=\"\(DocxTestPackage.w15Namespace)\">"
                + "<w15:person w15:author=\"\"><w15:presenceInfo w15:providerId=\"AD\" w15:userId=\"\"/></w15:person>"
                + "</w15:people>"
        )
    }
}
