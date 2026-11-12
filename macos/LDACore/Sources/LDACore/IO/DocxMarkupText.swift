//
//  DocxMarkupText.swift
//  LDACore
//
//  Text that WordprocessingML keeps in markup rather than in w:t runs, read
//  and rewritten as the text a consumer reads.
//
//  Review 2026-11-11 (F5). Field instructions (a HYPERLINK target, a TA
//  table-of-authorities citation, an XE index entry), a content control's
//  alias, tag and list items, a legacy form field's entries and help text, a
//  VML watermark's string and the alternative text of a picture or shape are
//  all shown to a reader or used to build what a reader sees, and none of
//  them is run text. The export copied them through: the probe document kept
//  "Ellis, Jordan" in an index entry and "jordan.ellis" in a content control
//  tag while its body read {PERSON_1}.
//
//  Each such text is handed to the caller decoded (character references and
//  the predefined entities expanded, see DocxDecodedXML); the caller says
//  which ranges to replace with what, and the edits land on the raw bytes. A
//  complex field's instruction is assembled across the runs Word split it
//  into first (see DocxFieldInstruction), a simple field's lives whole in
//  w:fldSimple/@w:instr.
//
//  Redaction writes brace tokens here in every style, like the other
//  supplementary channels, and restore writes the values back by token, so a
//  restored table of authorities and a restored drop-down list read as the
//  original did.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

enum DocxMarkupText {

    /// One replacement inside a decoded markup text.
    struct Edit {
        var range: NSRange
        var text: String
    }

    /// Decides the replacements for one decoded markup text.
    typealias Decide = (String) -> [Edit]

    /// Elements whose attributes hold text, and those attributes.
    static let textAttributes: [String: [String]] = [
        // Content controls.
        "w:alias": ["w:val"],
        "w:tag": ["w:val"],
        "w:listItem": ["w:displayText", "w:value"],
        // Legacy form fields.
        "w:listEntry": ["w:val"],
        "w:statusText": ["w:val"],
        "w:helpText": ["w:val"],
        "w:default": ["w:val"],
        // Simple fields keep their whole instruction in one attribute.
        "w:fldSimple": ["w:instr"],
        // VML: WordArt and watermarks, alternative text and titles.
        "v:textpath": ["string"],
        "v:shape": ["alt"],
        "v:rect": ["alt"],
        "v:roundrect": ["alt"],
        "v:oval": ["alt"],
        "v:imagedata": ["o:title"],
        // DrawingML alternative text and titles.
        "wp:docPr": ["descr", "title"],
        "pic:cNvPr": ["descr", "title"],
        "wps:cNvPr": ["descr", "title"],
        "wpg:cNvPr": ["descr", "title"],
    ]

    /// `xml` with every field instruction and text attribute rewritten as
    /// `decide` says.
    static func rewrite(_ xml: String, decide: Decide) -> String {
        let instructions = DocxFieldInstruction.rewriteAssembled(in: xml) { raw in
            rawEdits(for: raw, decide: decide, escape: escapeContent)
        }
        return rewriteAttributes(instructions, decide: decide)
    }

    /// `xml` with every brace token in its field instructions and text
    /// attributes replaced by its value from `values`. A token absent from
    /// `values` is left as it is.
    static func restore(_ xml: String, values: [String: String]) -> String {
        guard !values.isEmpty, xml.contains("{") else { return xml }
        return rewrite(xml) { text in
            tokenEdits(in: text, values: values)
        }
    }

    /// The brace tokens of `text` that `values` knows, as edits.
    static func tokenEdits(in text: String, values: [String: String]) -> [Edit] {
        guard let regex = tokenRegex else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            values[ns.substring(with: match.range)].map { Edit(range: match.range, text: $0) }
        }
    }

    private static let tokenRegex = try? NSRegularExpression(pattern: TokenGrammar.placeholderPattern)

    /// The value ranges of the double-quoted arguments of a field
    /// instruction, quotes excluded. A backslash escapes the next character
    /// inside quotes, which is how Word spells a quote in an argument; an
    /// argument never closed runs to the end.
    static func quotedArguments(in text: String) -> [NSRange] {
        let ns = text as NSString
        var ranges: [NSRange] = []
        var index = 0
        while index < ns.length {
            guard ns.character(at: index) == 0x22 else {
                index += 1
                continue
            }
            var end = index + 1
            while end < ns.length, ns.character(at: end) != 0x22 {
                end += ns.character(at: end) == 0x5C ? 2 : 1
            }
            let close = min(end, ns.length)
            if close > index + 1 {
                ranges.append(NSRange(location: index + 1, length: close - index - 1))
            }
            index = close + 1
        }
        return ranges
    }

    // MARK: - Attributes

    private static let elementRegex: NSRegularExpression? = {
        let names = textAttributes.keys.sorted().map { NSRegularExpression.escapedPattern(for: $0) }
        return try? NSRegularExpression(pattern: "<(" + names.joined(separator: "|") + ")(?=[\\s/>])[^>]*>")
    }()

    private static let attributeRegexes: [String: NSRegularExpression] = {
        var regexes: [String: NSRegularExpression] = [:]
        for name in Set(textAttributes.values.flatMap { $0 }) {
            let escaped = NSRegularExpression.escapedPattern(for: name)
            regexes[name] = try? NSRegularExpression(pattern: "(?<=\\s)\(escaped)=(?:\"([^\"]*)\"|'([^']*)')")
        }
        return regexes
    }()

    private static func rewriteAttributes(_ xml: String, decide: Decide) -> String {
        guard let elementRegex else { return xml }
        let ns = xml as NSString
        var result = ""
        var cursor = 0
        for match in elementRegex.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            let element = ns.substring(with: match.range(at: 1))
            var tag = ns.substring(with: match.range)
            for attribute in textAttributes[element] ?? [] {
                tag = rewriteAttribute(attribute, in: tag, decide: decide)
            }
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)) + tag
            cursor = match.range.location + match.range.length
        }
        return result.isEmpty && cursor == 0 ? xml : result + ns.substring(from: cursor)
    }

    private static func rewriteAttribute(_ name: String, in tag: String, decide: Decide) -> String {
        guard let regex = attributeRegexes[name] else { return tag }
        let ns = tag as NSString
        guard let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)) else { return tag }
        for (group, quote) in [(1, "\""), (2, "'")] where match.range(at: group).location != NSNotFound {
            let valueRange = match.range(at: group)
            let raw = ns.substring(with: valueRange)
            let edits = rawEdits(for: raw, decide: decide) { escapeAttribute($0, quote: quote) }
            guard !edits.isEmpty else { return tag }
            return ns.replacingCharacters(in: valueRange, with: DocxFieldInstruction.apply(edits, to: raw))
        }
        return tag
    }

    // MARK: - Decoding and escaping

    private static func rawEdits(
        for raw: String,
        decide: Decide,
        escape: (String) -> String
    ) -> [DocxFieldInstruction.AssembledEdit] {
        let decoded = DocxDecodedXML.decode(raw)
        return decide(decoded.text).map {
            DocxFieldInstruction.AssembledEdit(range: decoded.rawRange(for: $0.range), text: escape($0.text))
        }
    }

    private static func escapeContent(_ text: String) -> String {
        xmlEncode(text)
    }

    private static func escapeAttribute(_ text: String, quote: String) -> String {
        var out = xmlEncode(text)
        out = quote == "\"" ? out.replacingOccurrences(of: "\"", with: "&quot;")
            : out.replacingOccurrences(of: "'", with: "&apos;")
        return out
    }
}
