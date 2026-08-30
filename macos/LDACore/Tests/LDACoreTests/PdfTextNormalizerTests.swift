//
//  PdfTextNormalizerTests.swift
//  LDACoreTests
//
//  Unit tests for the PDF text-layer non-breaking-space repair, and for the
//  paired repair in PdfImporter.normalizeWhitespace that keeps the redaction
//  box locator matching text the importer repaired.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class PdfTextNormalizerTests: XCTestCase {

    /// The observed PDFKit artifact: U+00C2 + regular space replacing a source nbsp.
    func testRepairsMarkerPlusSpace() {
        XCTAssertEqual(
            PdfTextNormalizer.normalize("Dear Mr.\u{00C2} Jonathan A. Whitfield"),
            "Dear Mr. Jonathan A. Whitfield"
        )
    }

    /// The classic UTF-8-nbsp-as-Latin1 form: U+00C2 + non-breaking space.
    func testRepairsMarkerPlusNbsp() {
        XCTAssertEqual(
            PdfTextNormalizer.normalize("Section\u{00C2}\u{00A0}5"),
            "Section 5"
        )
    }

    /// A clean non-breaking space is normalized to a regular space.
    func testNormalizesBareNbsp() {
        XCTAssertEqual(PdfTextNormalizer.normalize("No.\u{00A0}12"), "No. 12")
    }

    /// A legitimate U+00C2 before a letter (a real word) must be left untouched,
    /// and so must a precomposed letter that merely contains a circumflex.
    func testLeavesLegitimateWordIntact() {
        XCTAssertEqual(PdfTextNormalizer.normalize("\u{00C2}me et corps"), "\u{00C2}me et corps")
        XCTAssertEqual(PdfTextNormalizer.normalize("Ch\u{00E2}teau Margaux"), "Ch\u{00E2}teau Margaux")
    }

    /// Text carrying neither artifact is returned unchanged (fast path).
    func testPassesCleanTextThrough() {
        let clean = "Dear Mr. Jonathan A. Whitfield, regards."
        XCTAssertEqual(PdfTextNormalizer.normalize(clean), clean)
    }

    // MARK: - Locator alignment

    /// The repair on import must be mirrored by the box locator's own
    /// normalization. The locator searches the ORIGINAL page text for a needle
    /// taken from the repaired text, so if only one side collapses the artifact
    /// the needle never matches: the value is detected and reported but never
    /// boxed, leaving it VISIBLE in a PDF the app calls redacted. That is the
    /// worst failure this app has, so it is pinned on both sides here.
    func testLocatorNormalizationBridgesTheArtifact() {
        let pageText = "Attn: Mr.\u{00C2}\u{00A0}John Smith, Esq."
        let needle = PdfTextNormalizer.normalize(pageText.replacingOccurrences(
            of: "Attn: ", with: ""
        ).replacingOccurrences(of: ", Esq.", with: ""))
        XCTAssertEqual(needle, "Mr. John Smith", "the importer repairs the needle")

        let haystack = PdfImporter.normalizeWhitespace(pageText).text
        let found = (haystack as NSString).range(of: needle, options: [.caseInsensitive])
        XCTAssertNotEqual(found.location, NSNotFound,
                          "a needle repaired on import must still be locatable on the page")
    }

    /// The artifact collapse must keep normalizeWhitespace's documented
    /// invariant: exactly one original-index entry per UTF-16 unit of the
    /// normalized text. A break here silently paints boxes over the wrong
    /// glyphs, which a match/no-match assertion alone would not catch.
    func testLocatorIndexMapStaysAlignedAcrossTheArtifact() {
        let (text, indexes) = PdfImporter.normalizeWhitespace("Mr.\u{00C2}\u{00A0}Smith")
        XCTAssertEqual(text, "Mr. Smith")
        XCTAssertEqual(indexes.count, text.utf16.count,
                       "one original index per normalized UTF-16 unit")
        // The collapsed space maps to the marker, so a box covers that glyph.
        let spaceOffset = Array(text).firstIndex(of: " ")!
        XCTAssertEqual(indexes[spaceOffset], 3, "the space maps back to the marker position")
        // The character after the collapsed run maps past both original units.
        XCTAssertEqual(indexes[spaceOffset + 1], 5, "S resumes after marker plus nbsp")
    }

    /// A marker followed by a letter is not the artifact and must not collapse,
    /// or a real word would lose its first letter and its index map would shift.
    func testLocatorLeavesLegitimateMarkerIntact() {
        let (text, indexes) = PdfImporter.normalizeWhitespace("\u{00C2}me")
        XCTAssertEqual(text, "\u{00C2}me")
        XCTAssertEqual(indexes.count, text.utf16.count)
        XCTAssertEqual(indexes, [0, 1, 2])
    }
}
