//
//  DocumentPaneStyleTests.swift
//  LDACoreTests
//
//  The document pane's highlight treatment, pinned as data: the underline
//  carries the type hue in BOTH review states (thick solid for a span that
//  will be redacted, thick dashed for one kept visible), the fill carries
//  state only (0.18 for accepted, none for kept visible), Original mode keeps
//  the body serif face, Safe Preview tokens take the parsed type hue at 0.24
//  in the monospaced face, and every highlighted range carries a tooltip that
//  names the type, the source, and the occurrence count. The styler is a pure
//  function over AppKit-scoped attributes so these tests need no view.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import AppKit
import XCTest
@testable import LDAUI
@testable import LDACore

final class DocumentPaneStyleTests: XCTestCase {

    private static let text = "Party 张三 signed. Contact 张三 at jane@x.example. 张三 again."

    /// A span over the n-th occurrence of `surface` in the fixture text.
    private static func span(
        _ surface: String,
        _ type: EntityType,
        occurrence: Int = 0,
        source: DetectionSource = .llm
    ) -> Span {
        let ns = text as NSString
        var found = NSRange(location: NSNotFound, length: 0)
        var searchStart = 0
        for _ in 0...occurrence {
            found = ns.range(
                of: surface,
                range: NSRange(location: searchStart, length: ns.length - searchStart)
            )
            precondition(found.location != NSNotFound, "fixture surface missing")
            searchStart = found.location + found.length
        }
        return Span(
            start: found.location,
            end: found.location + found.length,
            type: type,
            text: surface,
            source: source,
            confidence: 0.9,
            priority: 30
        )
    }

    private func attributes(
        of styled: NSAttributedString,
        at location: Int
    ) -> [NSAttributedString.Key: Any] {
        styled.attributes(at: location, effectiveRange: nil)
    }

    private func resolveLight(_ color: NSColor) throws -> UInt32 {
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)
        }
        let srgb = try XCTUnwrap(resolved)
        let red = UInt32((srgb.redComponent * 255).rounded())
        let green = UInt32((srgb.greenComponent * 255).rounded())
        let blue = UInt32((srgb.blueComponent * 255).rounded())
        return (red << 16) | (green << 8) | blue
    }

    // MARK: - Original mode

    func testAcceptedSpanCarriesHueUnderlineAndStateFill() throws {
        let entity = ReviewEntity(span: Self.span("张三", .person), accepted: true)
        let styled = DocumentTextStyler.styledOriginal(text: Self.text, entities: [entity])
        let attrs = attributes(of: styled, at: entity.span.start)

        let fill = try XCTUnwrap(attrs[.backgroundColor] as? NSColor, "accepted span has a fill")
        XCTAssertEqual(fill.alphaComponent, DocumentHighlightStyle.acceptedFillOpacity, accuracy: 0.001)
        XCTAssertEqual(try resolveLight(fill), CounselTheme.entityHex(for: .person).light)

        let underline = try XCTUnwrap(attrs[.underlineStyle] as? Int)
        XCTAssertEqual(underline, DocumentHighlightStyle.acceptedUnderline.rawValue)
        XCTAssertEqual(underline & NSUnderlineStyle.patternDash.rawValue, 0, "accepted underline is solid")

        let underlineColor = try XCTUnwrap(attrs[.underlineColor] as? NSColor)
        XCTAssertEqual(try resolveLight(underlineColor), CounselTheme.entityHex(for: .person).light)
    }

    func testKeptVisibleSpanHasNoFillAndADashedHueUnderline() throws {
        let entity = ReviewEntity(span: Self.span("张三", .person), accepted: false)
        let styled = DocumentTextStyler.styledOriginal(text: Self.text, entities: [entity])
        let attrs = attributes(of: styled, at: entity.span.start)

        XCTAssertNil(attrs[.backgroundColor], "kept-visible spans carry no fill")

        let underline = try XCTUnwrap(attrs[.underlineStyle] as? Int)
        XCTAssertEqual(underline, DocumentHighlightStyle.keptVisibleUnderline.rawValue)
        XCTAssertNotEqual(underline & NSUnderlineStyle.patternDash.rawValue, 0, "kept-visible underline is dashed")
        XCTAssertNotEqual(underline & NSUnderlineStyle.thick.rawValue, 0, "kept-visible underline is thick")

        let underlineColor = try XCTUnwrap(attrs[.underlineColor] as? NSColor)
        XCTAssertEqual(try resolveLight(underlineColor), CounselTheme.entityHex(for: .person).light)
    }

    func testOriginalModeKeepsTheBodySerifFaceInsideHighlights() throws {
        let entity = ReviewEntity(span: Self.span("张三", .person), accepted: true)
        let styled = DocumentTextStyler.styledOriginal(text: Self.text, entities: [entity])

        let plainFont = try XCTUnwrap(attributes(of: styled, at: 0)[.font] as? NSFont)
        let highlightedFont = try XCTUnwrap(attributes(of: styled, at: entity.span.start)[.font] as? NSFont)
        XCTAssertEqual(highlightedFont, plainFont, "no face change in Original mode")
        XCTAssertFalse(highlightedFont.isFixedPitch, "the chip face belongs to Safe Preview tokens only")
    }

    func testUnstyledTextCarriesTheReadingParagraphStyle() throws {
        let styled = DocumentTextStyler.styledOriginal(text: Self.text, entities: [])
        let paragraph = try XCTUnwrap(attributes(of: styled, at: 0)[.paragraphStyle] as? NSParagraphStyle)
        XCTAssertEqual(paragraph.lineSpacing, DocumentTextStyler.lineSpacing)
        XCTAssertNil(attributes(of: styled, at: 0)[.underlineStyle])
        XCTAssertNil(attributes(of: styled, at: 0)[.toolTip])
        XCTAssertEqual(styled.string, Self.text, "styling never changes the text")
    }

    func testEveryHighlightCarriesATooltipNamingTypeSourceAndCount() throws {
        let entities = [
            ReviewEntity(span: Self.span("张三", .person, occurrence: 0), accepted: true),
            ReviewEntity(span: Self.span("张三", .person, occurrence: 1), accepted: true),
            ReviewEntity(span: Self.span("张三", .person, occurrence: 2), accepted: false),
            ReviewEntity(span: Self.span("jane@x.example", .email, source: .deterministic), accepted: true)
        ]
        let styled = DocumentTextStyler.styledOriginal(text: Self.text, entities: entities)

        let personTip = try XCTUnwrap(attributes(of: styled, at: entities[1].span.start)[.toolTip] as? String)
        XCTAssertEqual(
            personTip,
            DocumentTextStyler.tooltip(type: .person, source: .llm, occurrences: 3)
        )
        XCTAssertTrue(personTip.contains(EntityTypePresentation.localizedName(for: .person)))
        XCTAssertTrue(personTip.contains("3"))
        XCTAssertTrue(personTip.contains(EntityTypePresentation.sourceLabel(for: .llm)))

        let emailTip = try XCTUnwrap(attributes(of: styled, at: entities[3].span.start)[.toolTip] as? String)
        XCTAssertTrue(emailTip.contains(EntityTypePresentation.sourceLabel(for: .deterministic)))
        XCTAssertTrue(emailTip.contains("1"))
    }

    func testOutOfRangeAndSurrogateSplittingSpansAreSkipped() {
        let text = "A \u{1F600} B"
        let bogus = [
            ReviewEntity(span: Span(start: 10, end: 12, type: .person, text: "x", source: .llm, confidence: 1, priority: 1), accepted: true),
            ReviewEntity(span: Span(start: 3, end: 4, type: .person, text: "x", source: .llm, confidence: 1, priority: 1), accepted: true)
        ]
        let styled = DocumentTextStyler.styledOriginal(text: text, entities: bogus)
        XCTAssertEqual(styled.string, text)
        for location in 0..<(text as NSString).length {
            XCTAssertNil(styled.attributes(at: location, effectiveRange: nil)[.underlineStyle])
        }
    }

    // MARK: - Safe Preview

    func testSafePreviewTokensTakeTheParsedTypeHueInTheMonoFace() throws {
        let preview = "Party {PERSON_1} signed for {NATIONALID_1}."
        let styled = DocumentTextStyler.styledSafePreview(text: preview)
        let ns = preview as NSString

        let personRange = ns.range(of: "{PERSON_1}")
        let personAttrs = attributes(of: styled, at: personRange.location)
        let personFill = try XCTUnwrap(personAttrs[.backgroundColor] as? NSColor)
        XCTAssertEqual(personFill.alphaComponent, DocumentHighlightStyle.tokenFillOpacity, accuracy: 0.001)
        XCTAssertEqual(try resolveLight(personFill), CounselTheme.entityHex(for: .person).light)
        XCTAssertNil(personAttrs[.underlineStyle], "tokens carry no underline")
        let personFont = try XCTUnwrap(personAttrs[.font] as? NSFont)
        XCTAssertEqual(personFont, DocumentTextStyler.monoFont)
        XCTAssertTrue(personFont.isFixedPitch, "tokens render in the monospaced chip face")

        // Sanitized token types drop the underscore (NATIONAL_ID -> NATIONALID)
        // and must still find their kind, or every ID would fall to neutral.
        let idRange = ns.range(of: "{NATIONALID_1}")
        let idFill = try XCTUnwrap(attributes(of: styled, at: idRange.location)[.backgroundColor] as? NSColor)
        XCTAssertEqual(try resolveLight(idFill), CounselTheme.entityHex(for: .nationalID).light)

        // Plain text between tokens stays in the serif body face without fill.
        let plainAttrs = attributes(of: styled, at: 0)
        XCTAssertNil(plainAttrs[.backgroundColor])
        let plainFont = try XCTUnwrap(plainAttrs[.font] as? NSFont)
        XCTAssertEqual(plainFont, DocumentTextStyler.bodyFont)
        XCTAssertFalse(plainFont.isFixedPitch)
    }

    func testUnparseableTokenTypeFallsBackToUnknown() {
        XCTAssertEqual(DocumentTextStyler.tokenType(forPlaceholder: "{PERSON_1}"), .person)
        XCTAssertEqual(DocumentTextStyler.tokenType(forPlaceholder: "{CASENUMBER_12}"), .caseNumber)
        XCTAssertEqual(DocumentTextStyler.tokenType(forPlaceholder: "{WECHATID_2}"), .wechatID)
        XCTAssertEqual(DocumentTextStyler.tokenType(forPlaceholder: "{FOO_1}"), .unknown)
        XCTAssertEqual(DocumentTextStyler.tokenType(forPlaceholder: "{X9_1}"), .unknown)
        XCTAssertEqual(DocumentTextStyler.tokenType(forPlaceholder: "garbage"), .unknown)
    }

    func testSafePreviewLeavesPseudonymTextUnstyled() {
        let preview = "Mail contact1@example.com today."
        let styled = DocumentTextStyler.styledSafePreview(text: preview)
        XCTAssertEqual(styled.string, preview)
        for location in 0..<(preview as NSString).length {
            XCTAssertNil(styled.attributes(at: location, effectiveRange: nil)[.backgroundColor])
        }
    }
}
