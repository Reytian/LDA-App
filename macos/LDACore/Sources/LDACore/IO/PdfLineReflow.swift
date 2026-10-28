//
//  PdfLineReflow.swift
//  LDACore
//
//  Joins the line breaks a PDF puts at the end of every printed line inside a
//  paragraph.
//
//  PDFKit's text layer, and Vision OCR, return one line of text per printed
//  line. Chinese has no space to tell a wrap from a word break, so a name
//  wrapped at the right margin reached detection in two pieces, or as a
//  different value from the same name printed on one line. Every spelling then
//  got its own placeholder, and SpanSplitter gave each side of the break a
//  token of its own: in a guiding case one company became several, and a
//  wrapped place name (香 at a line end, 港 on the next line) became a company.
//
//  A break is joined only where the layout shows a wrap: the line before it
//  runs to the page's measure, the line after it is neither blank, indented,
//  nor a numbered or bracketed heading, and the page holds a block of full
//  lines to measure against. Every other break stays as written. The review
//  PDF finds its boxes by searching each value's text, wrapped or not
//  (PdfImporter.redactionCoverage), so it does not depend on these offsets.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

public enum PdfLineReflow {

    /// Returns `text` with every soft line break joined: removed between two
    /// CJK characters, replaced by one space between two Latin words, removed
    /// after a URL, email address or path. Lines are measured in display
    /// columns (a CJK or full-width character is two, anything else one).
    public static func joinSoftBreaks(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.count > 1 else { return text }
        let widths = lines.map { width(of: trimmedTrailing($0)) }
        guard let measure = measure(of: widths) else { return text }
        let full = measure - tolerance(for: measure)

        var result = ""
        result.reserveCapacity(text.utf16.count)
        for index in lines.indices {
            let line = lines[index]
            guard index + 1 < lines.count else {
                result += line
                break
            }
            let next = lines[index + 1]
            if widths[index] >= full, let joiner = joiner(between: line, and: next) {
                result += trimmedTrailing(line) + joiner
            } else {
                result += line + "\n"
            }
        }
        return result
    }

    // MARK: - Measure

    /// The page's full-line width: the upper quartile of its line widths, when
    /// at least three lines reach it and it is wide enough to be a text block.
    /// A page of short lines (a list, a table, a signature block) has no
    /// measure, so nothing on it is joined.
    static func measure(of widths: [Int]) -> Int? {
        let filled = widths.filter { $0 > 0 }.sorted(by: >)
        guard filled.count >= 3 else { return nil }
        let measure = filled[(filled.count - 1) / 4]
        guard measure >= 24 else { return nil }
        guard filled.filter({ $0 >= measure - tolerance(for: measure) }).count >= 3 else { return nil }
        return measure
    }

    /// How far short of the measure a line may end and still count as full:
    /// justified Chinese lines differ by a character or two of punctuation
    /// compression, Latin lines by part of a word.
    static func tolerance(for measure: Int) -> Int {
        max(4, Int((Double(measure) * 0.06).rounded(.up)))
    }

    /// Display columns: two for a CJK or full-width character, one otherwise.
    static func width(of line: String) -> Int {
        line.unicodeScalars.reduce(0) { $0 + (isWide($1) ? 2 : 1) }
    }

    static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
             0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }

    // MARK: - Joining

    /// What replaces the break between `line` and `next`, or nil when the break
    /// is a real one: `next` is blank, starts indented, or opens a heading or a
    /// list item.
    static func joiner(between line: String, and next: String) -> String? {
        let current = trimmedTrailing(line)
        guard let last = current.unicodeScalars.last,
              let first = next.unicodeScalars.first,
              !CharacterSet.whitespaces.contains(first),
              !opensBlock(next) else { return nil }
        if endsInAddress(current) { return "" }
        return isLatinWordCharacter(last) && isLatinWordCharacter(first) ? " " : ""
    }

    /// A heading or list marker at the start of a line: 第三条, 1. or 1、
    /// (not 1.5), （一）, 一、, 【, or a bullet.
    static func opensBlock(_ line: String) -> Bool {
        line.range(of: blockMarker, options: .regularExpression) != nil
    }

    private static let blockMarker =
        "^(第[一二三四五六七八九十百千零〇两0-9]+[条章节款项编部]|[0-9]{1,3}[.、．)）](?![0-9])"
        + "|[（(][一二三四五六七八九十0-9]{1,3}[)）]|[一二三四五六七八九十]{1,3}、|【|[•·●▪*-]\\s)"

    /// True when the line's last word is a URL, an email address or a path,
    /// which continue on the next line without a space.
    static func endsInAddress(_ line: String) -> Bool {
        guard let word = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).last else { return false }
        return word.contains("/") || word.contains("@")
    }

    static func isLatinWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar))
    }

    static func trimmedTrailing(_ line: String) -> String {
        let scalars = line.unicodeScalars
        guard let end = scalars.lastIndex(where: { !CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            return ""
        }
        return String(String.UnicodeScalarView(scalars[...end]))
    }
}
