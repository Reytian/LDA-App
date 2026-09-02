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
    /// for the redacted copy: field targets first, then authorship.
    static func scrubRedactedPart(_ xml: String) -> String {
        blankAttributes(authorAttributes, in: neutralizeFieldTargets(xml))
    }

    /// Blank every person named in the people part. Presence provider ids and
    /// the element structure survive so Word keeps treating the part as valid.
    static func scrubPeoplePart(_ xml: String) -> String {
        blankAttributes(peopleAttributes, in: xml)
    }

    // MARK: - Field instructions

    /// A complex-field instruction element with its content, in either the
    /// live (w:instrText) or the tracked-deletion (w:delInstrText) spelling.
    /// The close tag is a backreference so the two never pair up crosswise.
    private static let instructionElementPattern =
        #"(<w:(instrText|delInstrText)\b[^>]*>)(.*?)(</w:\2>)"#

    /// A simple field start tag; its instruction lives in the w:instr attribute.
    private static let simpleFieldPattern = #"<w:fldSimple\b[^>]*>"#

    /// The whole w:instr attribute in either quote style (see DocxParts for
    /// why the two styles are separate alternatives).
    private static let instrAttributePattern = #"(?<=\s)w:instr=("[^"]*"|'[^']*')"#

    /// A sensitive address inside an instruction: the scheme and everything up
    /// to whitespace, a quote, an angle bracket, or an escaped quote entity,
    /// so the rewrite covers the address whether the instruction spells its
    /// quotes literally (element content) or as &quot; (attribute value).
    private static let sensitiveTargetPattern: String = {
        let schemes = DocxParts.sensitiveSchemes
            .map { NSRegularExpression.escapedPattern(for: String($0.dropLast())) }
            .joined(separator: "|")
        return #"(?i)\b(?:"# + schemes + #"):(?:(?!&quot;|&apos;)[^\s"'<>])*"#
    }()

    /// Rewrite every mailto:/tel: target in the part's field instructions to
    /// about:blank. Other instructions (PAGE, http links) are left untouched.
    static func neutralizeFieldTargets(_ xml: String) -> String {
        let elementsDone = rewriteMatches(
            of: instructionElementPattern,
            options: [.dotMatchesLineSeparators],
            in: xml
        ) { match, ns in
            ns.substring(with: match.range(at: 1))
                + neutralizeSensitiveTargets(in: ns.substring(with: match.range(at: 3)))
                + ns.substring(with: match.range(at: 4))
        }
        return rewriteMatches(of: simpleFieldPattern, options: [], in: elementsDone) { match, ns in
            let element = ns.substring(with: match.range)
            return rewriteMatches(of: instrAttributePattern, options: [], in: element) { attribute, elementNS in
                "w:instr=" + neutralizeSensitiveTargets(in: elementNS.substring(with: attribute.range(at: 1)))
            }
        }
    }

    private static func neutralizeSensitiveTargets(in instruction: String) -> String {
        rewriteMatches(of: sensitiveTargetPattern, options: [], in: instruction) { _, _ in
            DocxParts.neutralizedTarget
        }
    }

    // MARK: - Authorship attributes

    /// Blank the value of every attribute named in `names`, in either quote
    /// style. The attribute survives with an empty value, which the schema
    /// accepts, so the revision or comment itself stays intact.
    static func blankAttributes(_ names: [String], in xml: String) -> String {
        let alternatives = names
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        let pattern = "(?<=\\s)(\(alternatives))=(?:\"[^\"]*\"|'[^']*')"
        return rewriteMatches(of: pattern, options: [], in: xml) { match, ns in
            ns.substring(with: match.range(at: 1)) + "=\"\""
        }
    }

    // MARK: - Regex plumbing

    /// Rebuild `text` with every match of `pattern` replaced by `rewrite`'s
    /// result. Text between matches is copied verbatim. An unparsable pattern
    /// (a programming error, never input-dependent) leaves the text as is.
    private static func rewriteMatches(
        of pattern: String,
        options: NSRegularExpression.Options,
        in text: String,
        rewrite: (NSTextCheckingResult, NSString) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }
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
