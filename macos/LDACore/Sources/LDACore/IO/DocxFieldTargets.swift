//
//  DocxFieldTargets.swift
//  LDACore
//
//  Finding the mailto:/tel: target inside a field instruction, on the
//  instruction a consumer actually reads.
//
//  Why this file exists. The scrub used to match the RAW instruction with one
//  regex: the scheme, then everything up to whitespace, a quote of either
//  style, or an angle bracket. Review R3 broke it twice with well formed
//  input:
//
//    HYPERLINK "mail&#116;o:client@example.test"
//      survived untouched, because the pattern looked for a scheme that is
//      not spelled in the bytes. XML expands the reference before any
//      consumer reads the instruction, so this IS mailto:.
//
//    HYPERLINK "mailto:o'brien@example.test"
//      became HYPERLINK "about:blank'brien@example.test", because the pattern
//      ended the target at the first apostrophe. An apostrophe in an email
//      local part is legal and real, and the rewrite kept the identifying
//      half of the address while the export reported success.
//
//  What a field instruction actually is. A sequence of arguments separated by
//  whitespace, where an argument may be quoted. A double-quoted argument ends
//  at its own closing double quote (an apostrophe inside it is content); a
//  single-quoted argument ends at its own closing single quote; an unquoted
//  argument ends at whitespace. So the target's END is a property of the
//  instruction's delimiters, never of the address.
//
//  The rule here: decode the instruction, split it into arguments, and for
//  any argument holding a sensitive scheme, replace from the scheme to the
//  END of that argument. Replacing to the argument end rather than to the
//  next delimiter is deliberate: a switch value such as \o "write to
//  mailto:a@b" is display text carrying the same address, and over-removing
//  inside a redacted copy is the safe direction. The scheme match keeps its
//  word boundary, so a host named "hotel:8080" is not a tel: target.
//
//  Offsets returned are UTF-16 units into the RAW instruction, which is what
//  DocxFieldInstruction projects back onto the runs.
//
//  Pure: no clock reads, no I/O.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

enum DocxFieldTargets {

    /// A sensitive scheme at a word boundary, matched case-insensitively:
    /// Word writes MAILTO: as readily as mailto:. Built from the one list of
    /// schemes DocxParts uses for relationship targets.
    private static let schemeRegex: NSRegularExpression? = {
        let schemes = DocxParts.sensitiveSchemes
            .map { NSRegularExpression.escapedPattern(for: String($0.dropLast())) }
            .joined(separator: "|")
        return try? NSRegularExpression(pattern: #"(?i)\b(?:"# + schemes + #"):"#)
    }()

    private static let space: Set<UInt16> = [0x20, 0x09, 0x0A, 0x0D] // space, tab, LF, CR
    private static let doubleQuote: UInt16 = 0x22
    private static let singleQuote: UInt16 = 0x27
    private static let backslash: UInt16 = 0x5C

    /// Every sensitive target in `raw`, as edits over the RAW text.
    static func neutralizingEdits(inRaw raw: String) -> [DocxFieldInstruction.AssembledEdit] {
        guard let schemeRegex else { return [] }
        let decoded = DocxDecodedXML.decode(raw)
        let instruction = decoded.text
        var edits: [DocxFieldInstruction.AssembledEdit] = []

        for argument in arguments(in: instruction) {
            guard let match = schemeRegex.firstMatch(in: instruction, range: argument) else { continue }
            let targetEnd = argument.location + argument.length
            let target = NSRange(
                location: match.range.location,
                length: targetEnd - match.range.location
            )
            guard target.length > 0 else { continue }
            edits.append(
                .init(
                    range: decoded.rawRange(for: target),
                    text: DocxParts.neutralizedTarget
                )
            )
        }
        return edits
    }

    /// `raw` with every sensitive target replaced. For the simple-field
    /// w:instr attribute, whose whole instruction is one string and cannot be
    /// split across runs.
    static func neutralized(inRaw raw: String) -> String {
        DocxFieldInstruction.apply(neutralizingEdits(inRaw: raw), to: raw)
    }

    // MARK: - Arguments

    /// The VALUE range of each argument of `instruction`, quotes excluded.
    ///
    /// A quoted argument that is never closed runs to the end of the
    /// instruction: that is a field split across runs mid-target, and stopping
    /// early there is exactly the leak this module exists to prevent. A
    /// backslash escapes the next unit inside a quoted argument, which is how
    /// Word spells a quote inside a field argument.
    private static func arguments(in instruction: String) -> [NSRange] {
        let ns = instruction as NSString
        var ranges: [NSRange] = []
        var index = 0
        while index < ns.length {
            let unit = ns.character(at: index)
            if space.contains(unit) {
                index += 1
                continue
            }
            if unit == doubleQuote || unit == singleQuote {
                let end = closingQuote(after: index, matching: unit, in: ns)
                ranges.append(NSRange(location: index + 1, length: end - index - 1))
                index = min(end + 1, ns.length)
                continue
            }
            let end = endOfUnquotedArgument(from: index, in: ns)
            ranges.append(NSRange(location: index, length: end - index))
            index = end
        }
        return ranges
    }

    /// The index of the quote closing the argument opened at `open`, or the
    /// instruction's end when there is none.
    private static func closingQuote(after open: Int, matching quote: UInt16, in ns: NSString) -> Int {
        var index = open + 1
        while index < ns.length {
            let unit = ns.character(at: index)
            if unit == backslash, index + 1 < ns.length {
                index += 2
                continue
            }
            if unit == quote { return index }
            index += 1
        }
        return ns.length
    }

    private static func endOfUnquotedArgument(from start: Int, in ns: NSString) -> Int {
        var index = start
        while index < ns.length, !space.contains(ns.character(at: index)) {
            index += 1
        }
        return index
    }
}
