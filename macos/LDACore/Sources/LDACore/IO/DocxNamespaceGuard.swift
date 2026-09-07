//
//  DocxNamespaceGuard.swift
//  LDACore
//
//  The one namespace assumption the .docx reader makes, checked instead of
//  assumed.
//
//  DocxDocumentXML matches the LITERAL element names "w:t" and "w:delText",
//  and DocxRunText, DocxMarkupScrub and DocxParts all match literal "w:"
//  names too. XML does not work that way: a prefix is arbitrary, so a package
//  that binds the WordprocessingML namespace to "x" and writes <x:t> is
//  exactly as valid as Word's own output, and Word opens it. Our reader saw no
//  text in such a part at all: detection ran over an empty string, the
//  redactor had nothing to replace, and the markup, PII included, was copied
//  into the "redacted" output. Measured on the review's probe:
//  importedText="" preservedPII=true.
//
//  Namespace-aware matching used consistently by parsing, scrubbing and
//  rewriting is the full fix. Until then the reader REFUSES a representation
//  it cannot read, because the one outcome that must never ship is a silent
//  empty extraction with the text preserved. A refusal costs a lawyer an
//  export; a silent empty extraction costs a client their name.
//
//  Two shapes are refused, and they are mirror images:
//   - the WordprocessingML namespace bound to any prefix other than "w",
//     including the default namespace (no prefix at all), anywhere in the
//     part, root element or a rebinding on a single run.
//   - "w" bound to some other namespace, where "w:t" is not Word text and
//     rewriting it would edit a foreign vocabulary.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

enum DocxNamespaceGuard {

    /// The WordprocessingML main namespace, the vocabulary this reader knows.
    static let wordprocessingMLNamespace =
        "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

    /// The only prefix the literal element matching in this module supports.
    static let supportedPrefix = "w"

    /// A namespace declaration inside one start tag, in either quote style.
    /// Group 1 is the prefix (absent for a default declaration); group 2 and
    /// group 3 are the double- and single-quoted URI. The name is anchored to
    /// a preceding space so it is a whole attribute name, never the tail of
    /// one.
    ///
    /// The prefix class is everything a quoted attribute name can hold rather
    /// than the XML NCName production spelled out. An XML Name accepts letters
    /// far outside ASCII, so a class of [A-Za-z_] did not merely mis-read a
    /// Unicode prefix, it failed to see the DECLARATION at all: <文:document
    /// xmlns:文="...main"> passed the guard, every literal "w:" match then
    /// missed, and the part imported as empty text with its PII preserved.
    /// Erring wide here can only refuse more, never less, which is the safe
    /// direction for a guard whose job is to refuse what it cannot read.
    private static let declarationRegex = try? NSRegularExpression(
        pattern: #"(?<=\s)xmlns(?::([^\s=/>"']+))?\s*=\s*(?:"([^"]*)"|'([^']*)')"#
    )

    /// Refuse the start tag occupying [start, end) of `scalars` when it
    /// rebinds the WordprocessingML namespace away from "w" or binds "w"
    /// elsewhere.
    ///
    /// The range is checked for the literal "xmlns" first so the common tag,
    /// which declares nothing, costs a short scan and no String allocation.
    static func enforceSupportedBindings(
        _ scalars: [Character],
        from start: Int,
        to end: Int
    ) throws {
        guard containsDeclaration(scalars, from: start, to: end) else { return }
        try enforceSupportedBindings(inTag: String(scalars[start ..< end]))
    }

    /// Refuse one start tag whose namespace declarations this reader cannot
    /// honor. A tag that declares nothing, or declares only other
    /// vocabularies, passes.
    static func enforceSupportedBindings(inTag tag: String) throws {
        guard let declarationRegex else { return }
        let ns = tag as NSString
        let full = NSRange(location: 0, length: ns.length)
        for match in declarationRegex.matches(in: tag, range: full) {
            let prefix = capture(match, at: 1, in: ns)
            guard let raw = capture(match, at: 2, in: ns) ?? capture(match, at: 3, in: ns) else {
                continue
            }
            // The namespace name is the DECODED attribute value. XML expands
            // character references and the five predefined entities before an
            // attribute value is a namespace name, so ".../ma&#105;n" IS the
            // Word namespace and Word reads it as such. Comparing the raw text
            // let that spelling bypass the refusal: the export reported zero
            // entities and copied the document's own address into the output.
            let uri = xmlDecode(raw)
            if uri == wordprocessingMLNamespace, prefix != supportedPrefix {
                throw unsupportedBinding(
                    "the Word text namespace is bound to "
                        + (prefix.map { "the prefix \"\($0)\"" } ?? "no prefix")
                )
            }
            if prefix == supportedPrefix, uri != wordprocessingMLNamespace {
                throw unsupportedBinding("the prefix \"w\" names a namespace other than Word text")
            }
        }
    }

    /// The refusal. It names the representation, never any content: the
    /// offending value is the document's own text, and an error string travels
    /// into logs and UI.
    private static func unsupportedBinding(_ detail: String) -> DocumentIOError {
        DocumentIOError.unsupportedFormat(
            "this document uses an XML namespace layout the redactor cannot read (\(detail)). "
                + "Open it in Word and save a copy, then try again."
        )
    }

    private static func capture(
        _ match: NSTextCheckingResult,
        at group: Int,
        in ns: NSString
    ) -> String? {
        let range = match.range(at: group)
        guard range.location != NSNotFound else { return nil }
        return ns.substring(with: range)
    }

    /// True when [start, end) contains the literal "xmlns".
    private static func containsDeclaration(
        _ scalars: [Character],
        from start: Int,
        to end: Int
    ) -> Bool {
        let pattern: [Character] = ["x", "m", "l", "n", "s"]
        guard end - start >= pattern.count else { return false }
        var i = start
        let last = end - pattern.count
        while i <= last {
            if scalars[i] == "x" {
                var k = 1
                while k < pattern.count, scalars[i + k] == pattern[k] { k += 1 }
                if k == pattern.count { return true }
            }
            i += 1
        }
        return false
    }
}
