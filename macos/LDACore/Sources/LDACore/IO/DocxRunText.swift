//
//  DocxRunText.swift
//  LDACore
//
//  Helpers for the text-bearing run elements of WordprocessingML (w:t and
//  w:delText). An XML consumer may drop leading and trailing whitespace from
//  element content unless the element carries xml:space="preserve", and Word
//  does exactly that: a run rewritten to " for details" without the attribute
//  renders as "for details", and a Word re-save loses the space for good. Word
//  itself writes the attribute whenever a run's text starts or ends with
//  whitespace, so the redactor mirrors that rule on every run it rewrites.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

enum DocxRunText {

    /// The element names whose character content is run text. w:delText is the
    /// text of a tracked deletion; it reads and rewrites exactly like w:t.
    static let textElementNames: [String] = ["w:t", "w:delText"]

    /// The character a run-level break element contributes to the concatenated
    /// text, or nil for any other element. w:tab and w:ptab are tabs; w:br (of
    /// every type, page breaks included) and w:cr are line breaks. The element
    /// itself stays in the markup verbatim; only the text gains a character.
    static func breakText(forElement name: String) -> String? {
        switch name {
        case "w:tab", "w:ptab": return "\t"
        case "w:br", "w:cr": return "\n"
        default: return nil
        }
    }

    /// XML whitespace (space, tab, carriage return, line feed): the characters
    /// a consumer may strip from the edges of element content.
    private static let xmlWhitespace: Set<Unicode.Scalar> = [" ", "\t", "\r", "\n"]

    /// True when `text` starts or ends with XML whitespace and therefore needs
    /// xml:space="preserve" on its element to survive a Word round trip.
    static func needsSpacePreserve(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first, let last = text.unicodeScalars.last else {
            return false
        }
        return xmlWhitespace.contains(first) || xmlWhitespace.contains(last)
    }

    /// An existing xml:space attribute, in either quote style, including the
    /// whitespace that separates it from the previous token.
    private static let spaceAttributePattern = #"\sxml:space\s*=\s*(?:"[^"]*"|'[^']*')"#

    private static let preserveAttribute = " xml:space=\"preserve\""

    /// Return `openTag` (a w:t or w:delText start tag) carrying
    /// xml:space="preserve". An existing xml:space attribute is rewritten,
    /// since xml:space="default" tells Word to strip the space; otherwise the
    /// attribute is inserted before the closing ">".
    static func openTagPreservingSpace(_ openTag: String) -> String {
        if let regex = try? NSRegularExpression(pattern: spaceAttributePattern) {
            let ns = openTag as NSString
            let full = NSRange(location: 0, length: ns.length)
            if let match = regex.firstMatch(in: openTag, range: full) {
                return ns.replacingCharacters(in: match.range, with: preserveAttribute)
            }
        }
        guard openTag.hasSuffix(">") else { return openTag }
        return String(openTag.dropLast()) + preserveAttribute + ">"
    }

    /// Whether `markup` is the start tag of a text element (w:t or w:delText),
    /// as opposed to a longer name that merely begins the same way (w:tab,
    /// w:tbl, w:tc).
    static func isTextOpenTag(_ markup: String) -> Bool {
        for name in textElementNames {
            let prefix = "<" + name
            guard markup.hasPrefix(prefix) else { continue }
            guard let next = markup.dropFirst(prefix.count).first else { return false }
            return next == ">" || xmlWhitespace.contains(next.unicodeScalars.first ?? "x")
        }
        return false
    }
}
