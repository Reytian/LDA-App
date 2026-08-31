//
//  PdfTextNormalizer.swift
//  LDACore
//
//  Repairs PDFKit text-layer extraction artifacts on PDF import.
//
//  A non-breaking space (U+00A0) is common in real legal PDFs: typography tools
//  (and Word) insert it after abbreviations ("Mr.", "Dr.", "No."), around
//  section signs, and inside dates. PDFKit's text extraction can return such a
//  non-breaking space as a spurious "A with circumflex" (U+00C2) followed by a
//  space-like character, the familiar shape of UTF-8 bytes read as Latin-1.
//  Left unrepaired this both corrupts the redacted/restored output and can
//  split a name from its title so the detector misses it (a PII recall risk).
//
//  The paired repair lives in PdfImporter.normalizeWhitespace: the redaction
//  box locator searches the ORIGINAL page text for a needle taken from the text
//  repaired here, so the locator has to collapse the same artifact or a
//  repaired needle would never match and the value would be detected but never
//  boxed. See the comment there.
//
//  Pure: no clock reads, no I/O.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// Normalizes PDF text-layer artifacts produced by PDFKit extraction.
public enum PdfTextNormalizer {

    /// The mis-extraction marker: U+00C2, the Latin-1 reading of the first byte
    /// of a UTF-8 encoded non-breaking space.
    static let artifactMarker = "\u{00C2}"

    /// The same marker as a UTF-16 unit, for callers that scan NSString units.
    /// PdfImporter.normalizeWhitespace mirrors the repair below over the raw
    /// page text; sharing these units keeps the two collapse sites identical
    /// by construction instead of by comment.
    public static let artifactMarkerUnit: UInt16 = 0x00C2
    /// The space-like units that complete the artifact pair.
    public static let nonBreakingSpaceUnit: UInt16 = 0x00A0
    public static let plainSpaceUnit: UInt16 = 0x0020

    /// Repair the non-breaking-space artifacts in `text`:
    ///
    /// 1. "A with circumflex" (U+00C2) immediately followed by a non-breaking
    ///    space or a regular space is the PDFKit mis-extraction of a source
    ///    non-breaking space. Collapse it to a single regular space. A
    ///    legitimate U+00C2 is followed by a letter (the start of a word, as in
    ///    "Ame") and is therefore left intact.
    /// 2. Any remaining non-breaking space is normalized to a regular space so
    ///    the redacted Markdown handed to the AI and the restored text read
    ///    cleanly and detection is never split by an invisible separator.
    public static func normalize(_ text: String) -> String {
        guard text.contains(artifactMarker) || text.contains("\u{00A0}") else {
            return text
        }
        var out = text
        // Repair the marker followed by a non-breaking space, then by a regular
        // space. Order matters only in that both forms are observed in the wild.
        out = out.replacingOccurrences(of: "\(artifactMarker)\u{00A0}", with: " ")
        out = out.replacingOccurrences(of: "\(artifactMarker)\u{0020}", with: " ")
        // Normalize any surviving non-breaking space to a regular space.
        out = out.replacingOccurrences(of: "\u{00A0}", with: " ")
        return out
    }
}
