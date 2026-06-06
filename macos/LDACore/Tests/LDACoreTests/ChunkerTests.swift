//
//  ChunkerTests.swift
//  LDACoreTests
//
//  Tests for Chunker.chunk(_:targetChars:overlapChars:).
//
//  Offsets are UTF-16 code-unit offsets, NSRange-compatible. startUTF16 must be a
//  valid index into the source NSString so that slicing the source at startUTF16
//  reproduces the chunk's head.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class ChunkerTests: XCTestCase {

    // MARK: - Helpers

    /// Repeats a paragraph body enough times to comfortably exceed `minLength`
    /// UTF-16 code units, separating paragraphs with a blank line.
    private func multiParagraphDoc(minLength: Int) -> String {
        let paragraph = """
        This is a paragraph of an engagement letter describing the scope of the \
        retention, the parties involved, and the fee arrangement agreed between \
        counsel and the client for the matter at hand.
        """
        var parts: [String] = []
        var length = 0
        var index = 1
        while length < minLength {
            parts.append("Section \(index). \(paragraph)")
            length += (parts.last! as NSString).length + 2
            index += 1
        }
        return parts.joined(separator: "\n\n")
    }

    /// The UTF-16 length of a string, matching the chunker's measure.
    private func utf16Length(_ s: String) -> Int {
        (s as NSString).length
    }

    /// Slices `source` from `start` for `length` UTF-16 code units.
    private func slice(_ source: String, from start: Int, length: Int) -> String {
        (source as NSString).substring(with: NSRange(location: start, length: length))
    }

    // MARK: - Short text

    func testShortTextProducesSingleChunkAtOffsetZero() {
        let text = "Short engagement letter for Jane Roe."
        let chunks = Chunker.chunk(text, targetChars: 2000, overlapChars: 350)

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.startUTF16, 0)
        XCTAssertEqual(chunks.first?.text, text)
    }

    func testEmptyTextProducesNoChunks() {
        let chunks = Chunker.chunk("", targetChars: 2000, overlapChars: 350)
        XCTAssertTrue(chunks.isEmpty)
    }

    func testTextExactlyAtTargetProducesSingleChunk() {
        let target = 500
        let text = String(repeating: "a", count: target)
        let chunks = Chunker.chunk(text, targetChars: target, overlapChars: 150)

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.startUTF16, 0)
        XCTAssertEqual(chunks.first?.text, text)
    }

    // MARK: - Multiple chunks under target size

    func testLongDocYieldsMultipleChunksWithinTargetPlusSlack() {
        let target = 2000
        let slack = 64
        let doc = multiParagraphDoc(minLength: target * 4)
        XCTAssertGreaterThan(utf16Length(doc), target * 3)

        let chunks = Chunker.chunk(doc, targetChars: target, overlapChars: 350)

        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(
                utf16Length(chunk.text),
                target + slack,
                "Chunk exceeded target plus slack"
            )
        }
    }

    // MARK: - Overlap

    func testConsecutiveChunksOverlap() {
        let target = 2000
        let overlap = 350
        let doc = multiParagraphDoc(minLength: target * 5)
        let chunks = Chunker.chunk(doc, targetChars: target, overlapChars: overlap)

        XCTAssertGreaterThan(chunks.count, 2)

        for i in 0..<(chunks.count - 1) {
            let current = chunks[i]
            let next = chunks[i + 1]

            let currentEnd = current.startUTF16 + utf16Length(current.text)
            // The next chunk must begin before the current chunk ends so the two
            // overlap in the source.
            XCTAssertLessThan(
                next.startUTF16,
                currentEnd,
                "Chunk \(i + 1) does not overlap chunk \(i)"
            )
            // The overlap should be at least the minimum the chunker enforces.
            let overlapAmount = currentEnd - next.startUTF16
            XCTAssertGreaterThanOrEqual(
                overlapAmount,
                150,
                "Overlap between chunk \(i) and \(i + 1) is below the 150 floor"
            )
        }
    }

    // MARK: - Boundary-straddling entity stays whole

    func testNameNearBoundaryAppearsIntactInSomeChunk() {
        let target = 2000
        let filler = "word "
        let name = "Maximilian Featherstonehaugh"

        // Build text so the name lands right around the 2000-character boundary.
        let prefixCount = 1990
        let prefix = String(repeating: filler, count: (prefixCount / filler.count) + 1)
        let trimmedPrefix = slice(prefix, from: 0, length: prefixCount)
        let suffix = String(repeating: filler, count: 600)
        let doc = trimmedPrefix + name + " " + suffix

        let chunks = Chunker.chunk(doc, targetChars: target, overlapChars: 350)

        let intact = chunks.contains { $0.text.contains(name) }
        XCTAssertTrue(intact, "The boundary-straddling name was split across every chunk")
    }

    // MARK: - CJK safety

    func testCJKTextChunksWithoutBreakingMidCharacter() {
        // A long run of CJK characters with no ASCII boundaries.
        let sentence = "甲方与乙方就本协议项下之权利义务达成如下约定。"
        let doc = String(repeating: sentence, count: 200)
        let target = 600

        let chunks = Chunker.chunk(doc, targetChars: target, overlapChars: 150)
        XCTAssertGreaterThan(chunks.count, 1)

        let ns = doc as NSString
        for chunk in chunks {
            // startUTF16 must sit on a grapheme boundary, never inside a composed
            // character or a surrogate pair.
            let composed = ns.rangeOfComposedCharacterSequence(at: chunk.startUTF16)
            XCTAssertEqual(
                composed.location,
                chunk.startUTF16,
                "Chunk start fell inside a CJK character"
            )
            // Reconstructing the chunk substring from the source must equal the
            // chunk text, which fails if the slice cut a character in half.
            let reconstructed = slice(doc, from: chunk.startUTF16, length: utf16Length(chunk.text))
            XCTAssertEqual(reconstructed, chunk.text)
        }
    }

    // MARK: - Offset correctness

    func testStartOffsetsSliceBackToChunkHead() {
        let target = 1500
        let doc = multiParagraphDoc(minLength: target * 4)
        let chunks = Chunker.chunk(doc, targetChars: target, overlapChars: 300)

        XCTAssertGreaterThan(chunks.count, 1)

        for chunk in chunks {
            // Slicing the original at startUTF16 for the chunk's length must equal
            // the chunk text exactly.
            let reconstructed = slice(doc, from: chunk.startUTF16, length: utf16Length(chunk.text))
            XCTAssertEqual(
                reconstructed,
                chunk.text,
                "Slicing the source at startUTF16 did not match the chunk head"
            )
        }
    }

    func testFirstChunkStartsAtZeroAndChunksAreOrdered() {
        let target = 1200
        let doc = multiParagraphDoc(minLength: target * 4)
        let chunks = Chunker.chunk(doc, targetChars: target, overlapChars: 300)

        XCTAssertEqual(chunks.first?.startUTF16, 0)

        // Start offsets are strictly increasing in document order.
        for i in 0..<(chunks.count - 1) {
            XCTAssertLessThan(chunks[i].startUTF16, chunks[i + 1].startUTF16)
        }
    }

    func testChunksCoverEntireDocument() {
        let target = 1000
        let doc = multiParagraphDoc(minLength: target * 5)
        let chunks = Chunker.chunk(doc, targetChars: target, overlapChars: 200)

        // The first chunk starts at the document head.
        XCTAssertEqual(chunks.first?.startUTF16, 0)

        // The last chunk reaches the document end.
        let last = chunks.last!
        let lastEnd = last.startUTF16 + utf16Length(last.text)
        XCTAssertEqual(lastEnd, utf16Length(doc), "Chunks did not reach the end of the document")

        // There are no gaps: each chunk starts at or before the previous chunk's
        // end, so the union covers the whole source.
        for i in 0..<(chunks.count - 1) {
            let currentEnd = chunks[i].startUTF16 + utf16Length(chunks[i].text)
            XCTAssertLessThanOrEqual(
                chunks[i + 1].startUTF16,
                currentEnd,
                "Gap detected between chunk \(i) and \(i + 1)"
            )
        }
    }
}
