//
//  DocxMarkupScrub.swift
//  LDACore
//
//  Scrubs the PII that WordprocessingML keeps in MARKUP rather than in run
//  text, for the redacted copy only:
//   - field instructions (w:instrText, w:delInstrText, w:fldSimple/@w:instr)
//     whose HYPERLINK target is a mailto: or tel: address. The target is
//     rewritten to about:blank exactly as DocxParts does for external
//     relationship targets; the display text is ordinary run text and is
//     left to the run redactor.
//   - revision and comment authorship: w:author and w:initials on w:ins,
//     w:del, w:comment, and every other change-tracking element, blanked.
//   - word/people.xml, whose w15:author and w15:userId name the same people
//     (a directory account carries its email in w15:userId), blanked.
//
//  Like the docProps scrub these rewrites are destructive: there is nothing
//  to restore, so the restored copy keeps blank authors and dead field links.
//  Filling a form goes through the run rewriter without this pass, since a
//  filled form is not a redacted copy.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

enum DocxMarkupScrub {

    /// Attributes naming a person on change-tracking and comment markup.
    static let authorAttributes = ["w:author", "w:initials"]

    /// Attributes naming a person in word/people.xml.
    static let peopleAttributes = ["w15:author", "w15:userId"]

    /// The fixed path of the people part.
    static let peoplePartPath = "word/people.xml"

    /// Scrub one text-bearing part (body, header, footer, notes, comments)
    /// for the redacted copy: field targets first, then authorship, then the
    /// data bindings whose custom XML store the export removes (finding 4).
    static func scrubRedactedPart(_ xml: String) -> String {
        DocxPackagePolicy.removeDataBindings(
            blankAttributes(authorAttributes, in: neutralizeFieldTargets(xml))
        )
    }

    /// Blank every person named in the people part. Presence provider ids and
    /// the element structure survive so Word keeps treating the part as valid.
    static func scrubPeoplePart(_ xml: String) -> String {
        blankAttributes(peopleAttributes, in: xml)
    }

    // MARK: - Field instructions

    /// A simple field start tag; its instruction lives in the w:instr attribute.
    private static let simpleFieldRegex = try? NSRegularExpression(pattern: #"<w:fldSimple\b[^>]*>"#)

    /// The whole w:instr attribute in either quote style (see DocxParts for
    /// why the two styles are separate alternatives).
    private static let instrAttributeRegex = try? NSRegularExpression(
        pattern: #"(?<=\s)w:instr=("[^"]*"|'[^']*')"#
    )

    /// A sensitive address inside an instruction: the scheme and everything up
    /// to whitespace, a quote, an angle bracket, or an escaped quote entity,
    /// so the rewrite covers the address whether the instruction spells its
    /// quotes literally (element content) or as &quot; (attribute value).
    private static let sensitiveTargetRegex: NSRegularExpression? = {
        let schemes = DocxParts.sensitiveSchemes
            .map { NSRegularExpression.escapedPattern(for: String($0.dropLast())) }
            .joined(separator: "|")
        return try? NSRegularExpression(
            pattern: #"(?i)\b(?:"# + schemes + #"):(?:(?!&quot;|&apos;)[^\s"'<>])*"#
        )
    }()

    /// Rewrite every mailto:/tel: target in the part's field instructions to
    /// about:blank. Other instructions (PAGE, http links) are left untouched.
    ///
    /// A complex field's instruction is assembled across the runs Word split
    /// it into before it is judged, then written back onto those runs (see
    /// DocxFieldInstruction). Judging one run alone read a string no consumer
    /// reads and left a scheme-split address whole in the next run. A simple
    /// field keeps its whole instruction in one w:instr attribute, so it
    /// cannot split and is rewritten in place.
    static func neutralizeFieldTargets(_ xml: String) -> String {
        let elementsDone = DocxFieldInstruction.rewriteAssembled(in: xml) {
            sensitiveTargetEdits(in: $0)
        }
        return rewriteMatches(of: simpleFieldRegex, in: elementsDone) { match, ns in
            let element = ns.substring(with: match.range)
            return rewriteMatches(of: instrAttributeRegex, in: element) { attribute, elementNS in
                "w:instr=" + neutralizeSensitiveTargets(in: elementNS.substring(with: attribute.range(at: 1)))
            }
        }
    }

    private static func neutralizeSensitiveTargets(in instruction: String) -> String {
        rewriteMatches(of: sensitiveTargetRegex, in: instruction) { _, _ in
            DocxParts.neutralizedTarget
        }
    }

    /// Every sensitive target in one assembled instruction, as edits over
    /// that string. The same regex as neutralizeSensitiveTargets, reported as
    /// ranges instead of applied, so a target that crosses runs can be
    /// projected back onto them.
    private static func sensitiveTargetEdits(
        in instruction: String
    ) -> [DocxFieldInstruction.AssembledEdit] {
        guard let sensitiveTargetRegex else { return [] }
        let ns = instruction as NSString
        return sensitiveTargetRegex
            .matches(in: instruction, range: NSRange(location: 0, length: ns.length))
            .map { .init(range: $0.range, text: DocxParts.neutralizedTarget) }
    }

    // MARK: - Authorship attributes

    private static let authorAttributesRegex = attributeRegex(for: authorAttributes)
    private static let peopleAttributesRegex = attributeRegex(for: peopleAttributes)

    /// Every attribute named in `names`, in either quote style, with the name
    /// as group 1.
    private static func attributeRegex(for names: [String]) -> NSRegularExpression? {
        let alternatives = names
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        return try? NSRegularExpression(pattern: "(?<=\\s)(\(alternatives))=(?:\"[^\"]*\"|'[^']*')")
    }

    /// Blank the value of every attribute named in `names`, in either quote
    /// style. The attribute survives with an empty value, which the schema
    /// accepts, so the revision or comment itself stays intact. The two lists
    /// the scrub uses are precompiled; this entry point compiles for any list.
    static func blankAttributes(_ names: [String], in xml: String) -> String {
        if names == authorAttributes { return blankAttributes(matching: authorAttributesRegex, in: xml) }
        if names == peopleAttributes { return blankAttributes(matching: peopleAttributesRegex, in: xml) }
        return blankAttributes(matching: attributeRegex(for: names), in: xml)
    }

    private static func blankAttributes(matching regex: NSRegularExpression?, in xml: String) -> String {
        rewriteMatches(of: regex, in: xml) { match, ns in
            ns.substring(with: match.range(at: 1)) + "=\"\""
        }
    }

    // MARK: - Regex plumbing

    /// Rebuild `text` with every match of `regex` replaced by `rewrite`'s
    /// result. Text between matches is copied verbatim. A nil regex (a pattern
    /// that failed to compile, a programming error that is never
    /// input-dependent) leaves the text as is.
    private static func rewriteMatches(
        of regex: NSRegularExpression?,
        in text: String,
        rewrite: (NSTextCheckingResult, NSString) -> String
    ) -> String {
        guard let regex else { return text }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var result = ""
        var cursor = 0
        regex.enumerateMatches(in: text, range: full) { match, _, _ in
            guard let match else { return }
            if match.range.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            }
            result += rewrite(match, ns)
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            result += ns.substring(from: cursor)
        }
        return result
    }
}
