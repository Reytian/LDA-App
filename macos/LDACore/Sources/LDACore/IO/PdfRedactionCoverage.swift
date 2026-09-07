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

    public init(pageIndex: Int, token: String, boxes: [RedactionBox]) {
        self.pageIndex = pageIndex
        self.token = token
        self.boxes = boxes
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
}
