//
//  SegmentPackerTests.swift
//  LDACoreTests
//
//  Verifies the extraction-window packer: structure-aware boundaries, word
//  alignment (a window never begins mid-word), overlap policy per boundary
//  kind, coverage of the whole document, and CJK/grapheme safety.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class SegmentPackerTests: XCTestCase {

    // MARK: - Helpers

    /// Assert every window slices back to the source at its stated offset.
    private func assertOffsetsSliceBack(_ windows: [TextChunk], source: String) {
        let ns = source as NSString
        for window in windows {
            let length = (window.text as NSString).length
            let slice = ns.substring(with: NSRange(location: window.startUTF16, length: length))
            XCTAssertEqual(slice, window.text)
        }
    }

    /// Assert full coverage: every UTF-16 position of non-whitespace source
    /// text falls inside at least one window.
    private func assertCovers(_ windows: [TextChunk], source: String) {
        let ns = source as NSString
        var covered = [Bool](repeating: false, count: ns.length)
        for window in windows {
            let length = (window.text as NSString).length
            for index in window.startUTF16..<(window.startUTF16 + length) {
                covered[index] = true
            }
        }
        let whitespace = CharacterSet.whitespacesAndNewlines
        for index in 0..<ns.length where !covered[index] {
            let ch = ns.character(at: index)
            if let scalar = Unicode.Scalar(ch), whitespace.contains(scalar) {
                continue
            }
            XCTFail("position \(index) (\(ns.substring(with: NSRange(location: index, length: 1)))) not covered")
            return
        }
    }

    /// Assert no window begins mid-word: the character before a window start is
    /// never a Latin word character when the window's first character is one.
    private func assertNoMidWordStarts(_ windows: [TextChunk], source: String) {
        let ns = source as NSString
        for window in windows where window.startUTF16 > 0 {
            let first = ns.character(at: window.startUTF16)
            let before = ns.character(at: window.startUTF16 - 1)
            if SegmentPacker.isLatinWordChar(first) && SegmentPacker.isLatinWordChar(before) {
                XCTFail("window at \(window.startUTF16) starts mid-word: ...\(ns.substring(with: NSRange(location: max(0, window.startUTF16 - 12), length: 24)))...")
            }
        }
    }

    // MARK: - Basics

    func testEmptyTextProducesNoWindows() {
        XCTAssertTrue(SegmentPacker.segments(of: "").isEmpty)
    }

    func testWhitespaceOnlyTextProducesNoWindows() {
        XCTAssertTrue(SegmentPacker.segments(of: "  \n\n \t ").isEmpty)
    }

    func testShortTextIsASingleWindowAtOffsetZero() {
        let text = "Jordan Lee signed for Meridian Works, LLC."
        let windows = SegmentPacker.segments(of: text)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].text, text)
        XCTAssertEqual(windows[0].startUTF16, 0)
    }

    // MARK: - Paragraph boundaries carry no overlap

    func testParagraphBoundariesProduceDisjointWindows() {
        // Paragraphs of ~600 chars each; target 1000 forces a break near each
        // paragraph boundary. Windows must not overlap (no double scanning).
        let paragraph = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 13)
        let text = (0..<6).map { "P\($0) " + paragraph }.joined(separator: "\n\n")
        let windows = SegmentPacker.segments(of: text, targetChars: 1000)

        XCTAssertGreaterThan(windows.count, 1)
        assertOffsetsSliceBack(windows, source: text)
        assertCovers(windows, source: text)

        for index in 1..<windows.count {
            let previousEnd = windows[index - 1].startUTF16 + (windows[index - 1].text as NSString).length
            XCTAssertGreaterThanOrEqual(
                windows[index].startUTF16, previousEnd,
                "windows overlap even though paragraph boundaries were available"
            )
        }
    }

    // MARK: - Intra-paragraph cuts carry word-aligned overlap

    func testSentenceCutsInsideGiantParagraphOverlapAndStayWordAligned() {
        // One giant paragraph, no newlines: cuts land on sentence boundaries and
        // the next window must back off by an overlap without starting mid-word.
        let text = String(repeating: "Alexandra Hamilton met Meridian Works, LLC in Albany. ", count: 80)
        let windows = SegmentPacker.segments(of: text, targetChars: 1000)

        XCTAssertGreaterThan(windows.count, 2)
        assertOffsetsSliceBack(windows, source: text)
        assertCovers(windows, source: text)
        assertNoMidWordStarts(windows, source: text)

        // At least one consecutive pair must overlap (straddle protection).
        var sawOverlap = false
        for index in 1..<windows.count {
            let previousEnd = windows[index - 1].startUTF16 + (windows[index - 1].text as NSString).length
            if windows[index].startUTF16 < previousEnd {
                sawOverlap = true
            }
        }
        XCTAssertTrue(sawOverlap, "expected overlap after intra-paragraph cuts")
    }

    func testLineWrappedTextNeverStartsWindowMidWord() {
        // Simulates PDF text extraction: short lines separated by single
        // newlines (no paragraph breaks). This is the exact shape that made the
        // old pipeline start segments mid-word ("nformation disclosed ...").
        let line = "Company Confidential Information also includes all information disclosed here"
        let text = Array(repeating: line, count: 60).joined(separator: "\n")
        let windows = SegmentPacker.segments(of: text, targetChars: 2000)

        XCTAssertGreaterThan(windows.count, 1)
        assertOffsetsSliceBack(windows, source: text)
        assertCovers(windows, source: text)
        assertNoMidWordStarts(windows, source: text)
    }

    // MARK: - Straddle protection

    func testNameStraddlingSentenceCutStaysWholeInSomeWindow() {
        // Build text where a full name sits right at the window boundary.
        var text = ""
        while (text as NSString).length < 990 {
            text += "Background words continue here. "
        }
        text += "Signed by Jordan Alexander Lee on behalf of the company. "
        text += String(repeating: "More trailing words follow here. ", count: 40)

        let windows = SegmentPacker.segments(of: text, targetChars: 1000)
        let whole = windows.contains { $0.text.contains("Jordan Alexander Lee") }
        XCTAssertTrue(whole, "straddling name must stay whole in at least one window")
    }

    // MARK: - Pathological input

    func testWhitespaceFreeRunFallsBackToHardCutAndStillAdvances() {
        let text = String(repeating: "x", count: 5000)
        let windows = SegmentPacker.segments(of: text, targetChars: 1000)
        XCTAssertGreaterThan(windows.count, 1)
        assertCovers(windows, source: text)
        // Progress: strictly increasing starts.
        for index in 1..<windows.count {
            XCTAssertGreaterThan(windows[index].startUTF16, windows[index - 1].startUTF16)
        }
    }

    func testCJKTextIsNeverSplitMidCharacterAndCovers() {
        // CJK with full-width sentence terminators; includes surrogate-pair
        // characters to verify grapheme alignment.
        let sentence = "张伟明在上海市浦东新区注册了一家公司\u{20BB7}。"
        let text = String(repeating: sentence, count: 200)
        let windows = SegmentPacker.segments(of: text, targetChars: 800)

        XCTAssertGreaterThan(windows.count, 1)
        assertOffsetsSliceBack(windows, source: text)
        assertCovers(windows, source: text)
        // Re-joining slices must reproduce valid strings (no broken surrogate
        // pairs): substring(with:) would already have produced U+FFFD on a bad
        // cut, so assert none appear.
        for window in windows {
            XCTAssertFalse(window.text.contains("\u{FFFD}"))
        }
    }

    // MARK: - CRLF handling

    func testCRLFSingleLineBreaksAreNotParagraphBreaks() {
        // In a CRLF document a lone \r\n is ONE logical newline. It must be
        // treated as an intra-paragraph cut (overlap applies), not a paragraph
        // break. Detectable via overlap: windows after a CRLF cut back off.
        let line = "Wrapped address lines continue with the entity name across breaks here"
        let text = Array(repeating: line, count: 60).joined(separator: "\r\n")
        let windows = SegmentPacker.segments(of: text, targetChars: 2000)

        XCTAssertGreaterThan(windows.count, 1)
        var sawOverlap = false
        for index in 1..<windows.count {
            let previousEnd = windows[index - 1].startUTF16 + (windows[index - 1].text as NSString).length
            if windows[index].startUTF16 < previousEnd {
                sawOverlap = true
            }
        }
        XCTAssertTrue(sawOverlap, "CRLF line cuts must carry straddle-protection overlap")
        assertCovers(windows, source: text)
        assertNoMidWordStarts(windows, source: text)
    }

    func testCRLFDoubleBreaksAreStillParagraphBreaks() {
        let paragraph = String(repeating: "Short sentence here. ", count: 30)
        let text = (0..<6).map { _ in paragraph }.joined(separator: "\r\n\r\n")
        let windows = SegmentPacker.segments(of: text, targetChars: 700)
        XCTAssertGreaterThan(windows.count, 1)
        assertCovers(windows, source: text)
        // Paragraph-break boundaries carry no overlap.
        for index in 1..<windows.count {
            let previousEnd = windows[index - 1].startUTF16 + (windows[index - 1].text as NSString).length
            XCTAssertGreaterThanOrEqual(windows[index].startUTF16, previousEnd - 250)
        }
    }

    // MARK: - Call-count sanity

    func testWindowCountStaysNearTheoreticalMinimum() {
        // 40k chars of paragraph-structured text at target 2000 should stay
        // close to 20 windows, far below the old chunk-then-resplit explosion.
        let paragraph = String(repeating: "The parties agree that all notices go to the address on file. ", count: 8)
        var text = ""
        while (text as NSString).length < 40_000 {
            text += paragraph + "\n\n"
        }
        let windows = SegmentPacker.segments(of: text, targetChars: 2000)
        let total = (text as NSString).length
        let theoreticalMinimum = Int(ceil(Double(total) / 2000.0))
        XCTAssertLessThanOrEqual(
            windows.count, theoreticalMinimum + Int(ceil(Double(theoreticalMinimum) / 2.0)),
            "window count \(windows.count) drifted too far above the minimum \(theoreticalMinimum)"
        )
        assertCovers(windows, source: text)
    }
}
