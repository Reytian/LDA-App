//
//  PdfRedactionCoverage.swift
//  LDACore
//
//  Occurrence level accounting for the review PDF's redaction boxes.
//
//  The failure this file exists to prevent: coverage measured per unique TOKEN
//  reports a value as covered the moment SOME box carries that token. A name
//  printed normally on one page and wrapped across two lines on another then
//  reads as fully redacted while the wrapped page keeps the original pixels,
//  which is the worst outcome this app can produce. Coverage is therefore
//  measured per OCCURRENCE: one located instance of a value in the page
//  geometry, carrying the boxes that cover it.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import CoreGraphics

/// One located instance of a surface text in a PDF's page geometry, together
/// with the boxes that cover it.
///
/// A wrapped occurrence carries one box PER VISUAL LINE, so a box count is not
/// an occurrence count. That mismatch is exactly why occurrences are modelled
/// apart from boxes: only the occurrence can answer "is this instance covered".
public struct PdfTextOccurrence: Sendable, Equatable {
    /// Zero-based page the occurrence sits on.
    public var pageIndex: Int
    /// The token the occurrence's value was replaced with.
    public var token: String
    /// The boxes covering it. EMPTY means the occurrence was found in the page
    /// text but no usable glyph geometry could be read for it, which is a value
    /// the review PDF will still show.
    public var boxes: [RedactionBox]

    /// UTF-16 range in the page text (or joined OCR lines), before normalization.
    /// Unlike a bounding box, this identifies distinct values on one OCR line.
    public var textRange: NSRange?
    /// The text actually printed at this site, before whitespace normalization.
    public var matchedText: String?

    public init(
        pageIndex: Int, token: String, boxes: [RedactionBox],
        textRange: NSRange? = nil, matchedText: String? = nil
    ) {
        self.pageIndex = pageIndex
        self.token = token
        self.boxes = boxes
        self.textRange = textRange
        self.matchedText = matchedText
    }

    /// True when at least one box covers this occurrence.
    public var isCovered: Bool { !boxes.isEmpty }
}

/// Every occurrence located in one PDF's text layer, plus the boxes over them.
public struct PdfRedactionCoverage: Sendable, Equatable {
    public var occurrences: [PdfTextOccurrence]

    public init(occurrences: [PdfTextOccurrence] = []) {
        self.occurrences = occurrences
    }

    /// Assign each text site once before drawing or counting its boxes.
    /// Searches remain case-insensitive for PDF/OCR noise, but a literal case
    /// match owns a site when the mapping carries multiple spellings. A nested
    /// short value is not another replacement inside the longer value.
    static func assigningSites(
        _ occurrences: [PdfTextOccurrence],
        surfaceTexts: [(text: String, token: String)]
    ) -> [PdfTextOccurrence] {
        let spellings = surfaceTexts.map {
            (text: PdfImporter.normalizeWhitespace($0.text).text, token: $0.token)
        }
        // Cache by matched spelling, not by token: mixed-case sites can choose
        // different owners without transforming any UTF-16 offsets.
        var owners: [String: String] = [:]
        let assigned = occurrences.filter { occurrence in
            guard let matched = occurrence.matchedText else { return true }
            let spelling = PdfImporter.normalizeWhitespace(matched).text
            if let owner = owners[spelling] { return owner == occurrence.token }
            let exact = spellings.filter { $0.text == spelling }
            let candidates = exact.isEmpty ? spellings.filter {
                $0.text.compare(spelling, options: .caseInsensitive) == .orderedSame
            } : exact
            // Tie-breaking is independent of dictionary/search iteration order.
            guard let owner = candidates.map(\.token).sorted().first else { return true }
            owners[spelling] = owner
            return owner == occurrence.token
        }
        return assigned.filter { occurrence in
            guard let range = occurrence.textRange else { return true }
            return !assigned.contains { other in
                guard other.pageIndex == occurrence.pageIndex,
                      let outer = other.textRange else { return false }
                return outer.length > range.length && NSLocationInRange(range.location, outer)
                    && NSMaxRange(range) <= NSMaxRange(outer)
            }
        }
    }

    /// Every box, in occurrence order. This is what the redactor paints.
    public var boxes: [RedactionBox] { occurrences.flatMap(\.boxes) }

    /// Occurrences the page geometry could not cover. Each one is a value the
    /// review PDF still shows, so it is reported, never dropped.
    public var uncoveredOccurrenceCount: Int {
        occurrences.filter { !$0.isCovered }.count
    }

    /// How many occurrences of `token` the text layer located, covered or not.
    public func occurrenceCount(forToken token: String) -> Int {
        occurrences.filter { $0.token == token }.count
    }

    /// The count the review surfaces warn with: how many replaced OCCURRENCES
    /// the review PDF may still show.
    ///
    /// Two ways a value stays visible, and both are counted:
    ///  - an occurrence the text layer located but could not box; and
    ///  - a replaced value the text layer never located AT ALL that no other
    ///    channel boxed either. Page OCR and embedded-image OCR contribute
    ///    boxes without contributing text-layer occurrences, so those channels
    ///    are consulted through `boxedTokens`.
    ///
    /// Counting per occurrence rather than per unique token is the point: a
    /// value boxed on one page and unboxed on another is incompletely covered
    /// and has to say so.
    public static func unboxedOccurrenceCount(
        surfaceTexts: [(text: String, token: String)],
        textCoverage: PdfRedactionCoverage,
        boxedTokens: Set<String>
    ) -> Int {
        let locatedTokens = Set(textCoverage.occurrences.map(\.token))
        let neverLocated = surfaceTexts.filter { entry in
            !locatedTokens.contains(entry.token) && !boxedTokens.contains(entry.token)
        }
        return textCoverage.uncoveredOccurrenceCount + neverLocated.count
    }

    /// How many replaced OCCURRENCES the review PDF may still show, counted
    /// against the sites the text replaced: for each token, its sites in the
    /// redacted text less the occurrences any channel boxed.
    ///
    /// Review 2026-11-11 (F6): the count above asked whether a token was boxed
    /// SOMEWHERE, so a value boxed where it is printed on one line and left
    /// unboxed where it wraps (the search never located that occurrence at
    /// all) read as fully covered. The sites are what the text replaced, so a
    /// located occurrence short of them is an occurrence still showing.
    ///
    /// - Parameters:
    ///   - sitesByToken: how many sites of each token the redacted text has.
    ///   - occurrences: every occurrence the text-layer search and page OCR
    ///     located, covered or not.
    public static func unboxedOccurrenceCount(
        sitesByToken: [String: Int],
        occurrences: [PdfTextOccurrence]
    ) -> Int {
        // An occurrence lying wholly inside another token's box is part of
        // that longer value ("Ellis" found in "Jordan Ellis"), not a site of
        // its own; counted as covered it cancelled a real unboxed site of
        // the short value (independent review of F6).
        func isInsideAnotherValue(_ occurrence: PdfTextOccurrence) -> Bool {
            occurrences.contains { other in
                guard other.token != occurrence.token, other.pageIndex == occurrence.pageIndex else {
                    return false
                }
                if let inner = occurrence.textRange, let outer = other.textRange {
                    // OCR deliberately covers a whole line. Equal geometry is
                    // not evidence that two different text sites are nested.
                    return outer.length > inner.length && NSLocationInRange(inner.location, outer)
                        && NSMaxRange(inner) <= NSMaxRange(outer)
                }
                // Keep the conservative geometry fallback for callers that do
                // not carry text ranges. Equal boxes cannot pay for both tokens.
                return occurrence.boxes.allSatisfy { box in
                    other.boxes.contains { $0.rect.insetBy(dx: -1, dy: -1).contains(box.rect) }
                }
            }
        }
        var covered: [String: Int] = [:]
        for occurrence in occurrences where occurrence.isCovered && !isInsideAnotherValue(occurrence) {
            covered[occurrence.token, default: 0] += 1
        }
        return sitesByToken.reduce(0) { total, entry in
            total + max(0, entry.value - (covered[entry.key] ?? 0))
        }
    }
}
