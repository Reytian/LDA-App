//
//  DocxParts.swift
//  LDACore
//
//  Extends DOCX redaction beyond word/document.xml to every other text-bearing
//  part of the package, closing the io-docx-nonbody-parts-leak. Legal documents
//  routinely carry PII in running headers and footers, footnotes and endnotes,
//  comments, author metadata (docProps), and external hyperlink targets (mailto:
//  links) in the relationships. None of that flows through document.xml, so the
//  body-only redactor used to ship it untouched.
//
//  Responsibilities:
//   - Enumerate the additional text-bearing parts (header*.xml, footer*.xml,
//     footnotes.xml, endnotes.xml, comments.xml) which all use the same w:t run
//     model, so DocxDocumentXML.parse already handles them.
//   - Detect over each such part (deterministic plus optional LLM, injected) and
//     mint tokens that stay consistent with the body mapping: reuse an existing
//     token when the surface is already mapped, otherwise continue the per-type
//     numbering. This mirrors ImageRedactionResolver's token policy.
//   - Scrub author/title metadata in docProps/core.xml and docProps/app.xml.
//   - Neutralize external mailto:/tel: hyperlink Targets in the .rels parts.
//
//  Offset convention: per-part w:t offsets are UTF-16 code units into that part's
//  own concatenated text, matching Span in CoreTypes.swift.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import ZIPFoundation

/// The fixed paths of the docProps parts whose metadata is scrubbed.
let docxCorePropsPath = "docProps/core.xml"
let docxAppPropsPath = "docProps/app.xml"
let docxCustomPropsPath = "docProps/custom.xml"

/// Processes the non-body parts of a .docx package: redaction of additional
/// text-bearing parts, metadata scrubbing, and external-link neutralization.
enum DocxParts {

    // MARK: - Part enumeration

    /// Lists the additional text-bearing part paths present in the archive that
    /// use the w:t run model (headers, footers, footnotes, endnotes, comments).
    /// word/document.xml is deliberately excluded; it is handled by DocxRedactor.
    static func textBearingPartPaths(in url: URL) -> [String] {
        enumerateEntryPaths(in: url).filter { isTextBearingPart($0) }.sorted()
    }

    /// Lists every relationships part (.rels) present in the archive.
    static func relsPartPaths(in url: URL) -> [String] {
        enumerateEntryPaths(in: url).filter { $0.hasSuffix(".rels") }.sorted()
    }

    /// True for the additional w:t-bearing parts. headerN/footerN are numbered,
    /// the notes and comments parts are fixed names.
    static func isTextBearingPart(_ path: String) -> Bool {
        if path == docxMainPartPath { return false }
        if path.hasPrefix("word/header") && path.hasSuffix(".xml") { return true }
        if path.hasPrefix("word/footer") && path.hasSuffix(".xml") { return true }
        switch path {
        case "word/footnotes.xml", "word/endnotes.xml", "word/comments.xml":
            return true
        default:
            return false
        }
    }

    /// Reads every file entry path from the archive. Returns an empty list when the
    /// archive cannot be opened; callers treat that as "no extra parts".
    private static func enumerateEntryPaths(in url: URL) -> [String] {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            return []
        }
        var paths: [String] = []
        for entry in archive where entry.type == .file {
            paths.append(entry.path)
        }
        return paths
    }

    // MARK: - Combined visible text (for detection folding)

    /// The visible text of one non-body part plus its layout, used to detect and
    /// redact that part independently.
    struct LoadedPart {
        var path: String
        var layout: DocxLayout
    }

    /// Loads and parses every additional text-bearing part. Parts that fail to
    /// parse are skipped rather than aborting the whole redaction; a malformed
    /// header should not block redacting the body and the other parts.
    static func loadTextBearingParts(from url: URL) -> [LoadedPart] {
        var loaded: [LoadedPart] = []
        for path in textBearingPartPaths(in: url) {
            guard let data = try? DocxZip.readEntry(path, from: url),
                  let layout = try? DocxDocumentXML.parse(data) else { continue }
            loaded.append(LoadedPart(path: path, layout: layout))
        }
        return loaded
    }

    // MARK: - Redaction of text-bearing parts

    /// The result of redacting all non-body text parts plus scrubbing metadata and
    /// neutralizing external links.
    struct Result {
        /// path -> rewritten bytes, ready to feed DocxZip.rewrite's replacing dict.
        var replacements: [String: Data]
        /// New mapping entries minted for surfaces found only in non-body parts.
        var newEntries: [MappingEntry]
    }

    /// Redact every non-body text part, scrub docProps metadata, and neutralize
    /// external mailto:/tel: hyperlink Targets.
    ///
    /// - Parameters:
    ///   - url: the source .docx.
    ///   - mapping: the body mapping (read-only here); used so a surface already
    ///     mapped in the body reuses its token.
    ///   - detect: detection over arbitrary text (deterministic plus optional LLM).
    /// - Returns: the per-path rewritten bytes and any new mapping entries.
    static func redactNonBodyParts(
        url: URL,
        mapping: Mapping,
        detect: (String) -> [Span]
    ) -> Result {
        var replacements: [String: Data] = [:]
        var newEntries: [MappingEntry] = []

        // Token reuse index and per-type counters seeded from the body mapping,
        // then carried across parts so numbering never collides.
        var tokenByNormSurface: [String: String] = [:]
        for entry in mapping.entries.values {
            tokenByNormSurface[TextMatching.normalize(entry.surfaceText)] = entry.token
            for alias in entry.aliases {
                tokenByNormSurface[TextMatching.normalize(alias)] = entry.token
            }
        }
        var counters = perTypeMaxIndices(in: mapping.entries.keys)

        for part in loadTextBearingParts(from: url) {
            // Split spans crossing the synthetic paragraph newline; a surface
            // carrying it cannot restore into a single run (see SpanSplitter).
            let spans = SpanSplitter.splitAtLineBreaks(
                detect(part.layout.text),
                in: part.layout.text
            )
            guard !spans.isEmpty else { continue }

            // Resolve a token for each accepted span, extending the mapping.
            var replacementsForPart: [Replacement] = []
            for span in acceptedSpans(spans, in: part.layout.text) {
                let token = resolveToken(
                    for: span,
                    tokenByNormSurface: &tokenByNormSurface,
                    counters: &counters,
                    newEntries: &newEntries
                )
                replacementsForPart.append(Replacement(span: span, token: token))
            }
            guard !replacementsForPart.isEmpty else { continue }

            if let rewritten = try? redactLayout(part.layout, replacements: replacementsForPart) {
                replacements[part.path] = rewritten
            }
        }

        // Scrub author/title metadata.
        if let data = try? DocxZip.readEntry(docxCorePropsPath, from: url),
           let xml = String(data: data, encoding: .utf8) {
            replacements[docxCorePropsPath] = Data(scrubCoreProps(xml).utf8)
        }
        if let data = try? DocxZip.readEntry(docxAppPropsPath, from: url),
           let xml = String(data: data, encoding: .utf8) {
            replacements[docxAppPropsPath] = Data(scrubAppProps(xml).utf8)
        }
        // Scrub custom document properties: DMS-stamped client names, matter
        // numbers, and billing codes routinely live here as string values.
        if let data = try? DocxZip.readEntry(docxCustomPropsPath, from: url),
           let xml = String(data: data, encoding: .utf8) {
            replacements[docxCustomPropsPath] = Data(scrubCustomProps(xml).utf8)
        }

        // Neutralize external mailto:/tel: hyperlink targets in every .rels part.
        for relsPath in relsPartPaths(in: url) {
            guard let data = try? DocxZip.readEntry(relsPath, from: url),
                  let xml = String(data: data, encoding: .utf8) else { continue }
            let neutralized = neutralizeExternalTargets(xml)
            if neutralized != xml {
                replacements[relsPath] = Data(neutralized.utf8)
            }
        }

        return Result(replacements: replacements, newEntries: newEntries)
    }

    // MARK: - Restore of text-bearing parts

    /// Re-substitute token -> value across every non-body text part of a redacted
    /// package, returning the rewritten bytes per path. The docProps and .rels
    /// scrubs are destructive and are not reversed (there is nothing to restore).
    static func restoreNonBodyParts(
        url: URL,
        tokenToValue: [String: String]
    ) -> [String: Data] {
        var replacements: [String: Data] = [:]
        guard let regex = try? NSRegularExpression(pattern: TokenGrammar.placeholderPattern) else {
            return replacements
        }
        for path in textBearingPartPaths(in: url) {
            guard let data = try? DocxZip.readEntry(path, from: url),
                  var layout = try? DocxDocumentXML.parse(data) else { continue }
            var changed = false
            for index in layout.segments.indices {
                guard case .runText(let text) = layout.segments[index] else { continue }
                guard text.contains("{") else { continue }
                let replaced = substituteTokens(in: text, using: regex, tokenToValue: tokenToValue)
                if replaced != text {
                    layout.segments[index] = .runText(replaced)
                    changed = true
                }
            }
            if changed {
                replacements[path] = DocxDocumentXML.serialize(layout)
            }
        }
        return replacements
    }

    /// Literal-style counterpart of restoreNonBodyParts: re-substitute every
    /// unambiguous replacement string across the non-body text parts. Used
    /// for pseudonym and asterisk mappings.
    static func restoreNonBodyPartsLiteral(
        url: URL,
        replacementToValue: [String: String]
    ) -> [String: Data] {
        var replacements: [String: Data] = [:]
        for path in textBearingPartPaths(in: url) {
            guard let data = try? DocxZip.readEntry(path, from: url),
                  var layout = try? DocxDocumentXML.parse(data) else { continue }
            var changed = false
            for index in layout.segments.indices {
                guard case .runText(let text) = layout.segments[index] else { continue }
                let replaced = Restorer.substituteLiteralReplacements(
                    in: text,
                    replacementToValue: replacementToValue
                )
                if replaced != text {
                    layout.segments[index] = .runText(replaced)
                    changed = true
                }
            }
            if changed {
                replacements[path] = DocxDocumentXML.serialize(layout)
            }
        }
        return replacements
    }

    // MARK: - Token resolution

    /// The dominant non-overlapping spans for a part, longest-first then earliest,
    /// so multiple detections in one part do not collide on the same run text.
    private static func acceptedSpans(_ spans: [Span], in text: String) -> [Span] {
        let utf16Count = text.utf16.count
        let valid = spans.filter { $0.start >= 0 && $0.end <= utf16Count && $0.start < $0.end }
        let ordered = valid.sorted { lhs, rhs in
            let l = lhs.end - lhs.start, r = rhs.end - rhs.start
            if l != r { return l > r }
            return lhs.start < rhs.start
        }
        var accepted: [Span] = []
        for span in ordered {
            let overlaps = accepted.contains { span.start < $0.end && span.end > $0.start }
            if !overlaps { accepted.append(span) }
        }
        return accepted.sorted { $0.start < $1.start }
    }

    /// Reuse an existing token for a known surface, otherwise mint the next
    /// {TYPE_N} continuing the shared per-type numbering and record a new entry.
    private static func resolveToken(
        for span: Span,
        tokenByNormSurface: inout [String: String],
        counters: inout [String: Int],
        newEntries: inout [MappingEntry]
    ) -> String {
        let norm = TextMatching.normalize(span.text)
        if let existing = tokenByNormSurface[norm] {
            return existing
        }
        let typeToken = TokenGrammar.sanitizeType(span.type.rawValue)
        let n = (counters[typeToken] ?? 0) + 1
        counters[typeToken] = n
        let token = "{\(typeToken)_\(n)}"
        tokenByNormSurface[norm] = token
        newEntries.append(
            MappingEntry(
                token: token,
                value: span.text,
                type: span.type,
                surfaceText: span.text,
                aliases: []
            )
        )
        return token
    }

    /// Max N per TYPE across canonical "{TYPE_N}" mapping keys, identical to
    /// ImageRedactionResolver.perTypeMaxIndices, so non-body tokens continue the
    /// same numbering as the body and the image channel.
    private static func perTypeMaxIndices<S: Sequence>(in keys: S) -> [String: Int]
    where S.Element == String {
        var maxima: [String: Int] = [:]
        for key in keys {
            guard key.hasPrefix("{"), key.hasSuffix("}") else { continue }
            let inner = key.dropFirst().dropLast()
            guard let underscore = inner.lastIndex(of: "_") else { continue }
            let typePart = String(inner[..<underscore])
            guard let n = Int(inner[inner.index(after: underscore)...]) else { continue }
            maxima[typePart] = max(maxima[typePart] ?? 0, n)
        }
        return maxima
    }

    // MARK: - Layout redaction (shared plan/apply, mirrors DocxRedactor)

    /// Apply replacements to a parsed layout and return the serialized bytes. This
    /// reuses DocxRedactor's run-edit planning so cross-run spans and multiple
    /// spans per run behave identically to the body path.
    private static func redactLayout(
        _ layout: DocxLayout,
        replacements: [Replacement]
    ) throws -> Data {
        var working = layout
        let edits = try DocxRedactor.planRunEdits(
            replacements,
            runs: working.runs,
            segments: working.segments
        )
        for (segmentIndex, segmentEdits) in edits {
            try DocxRedactor.applyRunEdits(segmentEdits, atSegment: segmentIndex, in: &working)
        }
        return DocxDocumentXML.serialize(working)
    }

    /// Single left-to-right token substitution over one run's text, identical in
    /// behavior to DocxRedactor.replaceTokens.
    private static func substituteTokens(
        in text: String,
        using regex: NSRegularExpression,
        tokenToValue: [String: String]
    ) -> String {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: text, range: full)
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = 0
        for match in matches {
            let range = match.range
            if range.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            }
            let token = ns.substring(with: range)
            result += tokenToValue[token] ?? token
            cursor = range.location + range.length
        }
        if cursor < ns.length {
            result += ns.substring(from: cursor)
        }
        return result
    }

    // MARK: - docProps metadata scrub

    /// Author and title elements whose text content is blanked in core.xml.
    private static let coreScrubElements = [
        "dc:creator", "cp:lastModifiedBy", "dc:title", "dc:subject", "dc:description"
    ]

    /// Identity elements whose text content is blanked in app.xml.
    private static let appScrubElements = ["Company", "Manager"]

    /// Blank the text content of the configured core-properties elements.
    static func scrubCoreProps(_ xml: String) -> String {
        var out = xml
        for element in coreScrubElements {
            out = blankElementContent(out, element: element)
        }
        return out
    }

    /// Blank the text content of the configured extended-properties elements.
    static func scrubAppProps(_ xml: String) -> String {
        var out = xml
        for element in appScrubElements {
            out = blankElementContent(out, element: element)
        }
        return out
    }

    /// String-typed variant elements whose content is blanked in custom.xml.
    /// Non-string variants (vt:bool, vt:i4, vt:filetime) carry far less direct
    /// PII and are left untouched so document tooling keeps working.
    private static let customScrubElements = ["vt:lpwstr", "vt:lpstr", "vt:bstr"]

    /// Blank every string-typed custom property value. Property names and the
    /// element structure survive so the part stays schema-valid.
    static func scrubCustomProps(_ xml: String) -> String {
        var out = xml
        for element in customScrubElements {
            out = blankElementContent(out, element: element)
        }
        return out
    }

    // MARK: - Embedded media inventory

    /// Paths of embedded media files (word/media/...). These are copied
    /// verbatim into the redacted package because there is no DOCX image
    /// redaction channel yet, so wet-ink signature scans or stamps inside them
    /// are NOT scanned for PII. Callers surface the count as a warning.
    static func embeddedMediaPaths(in url: URL) -> [String] {
        enumerateEntryPaths(in: url)
            .filter { $0.hasPrefix("word/media/") }
            .sorted()
    }

    /// Replace the inner text of every "<element ...>...</element>" with empty,
    /// leaving the tags (and any attributes) intact. Matching is non-greedy so
    /// repeated elements are each handled. A self-closing element is left as is.
    private static func blankElementContent(_ xml: String, element: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: element)
        let pattern = "(<\(escaped)(?:\\s[^>]*)?>)(.*?)(</\(escaped)>)"
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators]
        ) else { return xml }
        let ns = xml as NSString
        let full = NSRange(location: 0, length: ns.length)
        return regex.stringByReplacingMatches(in: xml, range: full, withTemplate: "$1$3")
    }

    // MARK: - External hyperlink neutralization

    /// Schemes whose external Target values carry PII and must be neutralized.
    private static let sensitiveSchemes = ["mailto:", "tel:"]

    /// Replacement Target value written over a neutralized external link.
    private static let neutralizedTarget = "about:blank"

    /// Rewrite the Target attribute of every Relationship that is TargetMode
    /// "External" and whose Target starts with a sensitive scheme (mailto:/tel:),
    /// replacing the address with a neutral value. Other relationships (internal
    /// part targets, http links) are left untouched.
    static func neutralizeExternalTargets(_ xml: String) -> String {
        // Match each <Relationship ...> start tag (self-closing or not) so we can
        // inspect both TargetMode and Target before rewriting this one tag only.
        // Relationship elements are empty by the OOXML schema, so the attributes
        // we need always live on the start tag.
        let pattern = "<Relationship\\b[^>]*>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return xml }
        let ns = xml as NSString
        let full = NSRange(location: 0, length: ns.length)

        var result = ""
        var cursor = 0
        regex.enumerateMatches(in: xml, range: full) { match, _, _ in
            guard let match else { return }
            let range = match.range
            if range.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            }
            let element = ns.substring(with: range)
            result += rewriteRelationshipElement(element)
            cursor = range.location + range.length
        }
        if cursor < ns.length {
            result += ns.substring(from: cursor)
        }
        return result
    }

    /// A whole Target attribute in either quote style, used to overwrite the
    /// address wholesale. The value is delimited by the SAME quote that opened
    /// it, so it may legally contain the other quote: an apostrophe in an email
    /// local part (o'brien@example.com) is both legal and real. A matcher
    /// that ended the value at the first quote of EITHER style would rewrite
    /// only the opening fragment and strand the rest of the address as loose
    /// text in the part, which is a leak wearing the costume of a fix.
    private static let targetAttributePattern = #"(?<=\s)Target=(?:"[^"]*"|'[^']*')"#

    /// Rewrite one <Relationship .../> element when it is an external link with a
    /// sensitive scheme; otherwise return it unchanged.
    ///
    /// Every attribute here is read quote-agnostically. XML gives the two quote
    /// styles equal standing (AttValue accepts either), and while Word writes
    /// double quotes, LibreOffice, python-docx variants, XML tooling, and
    /// hand-edited packages emit single-quoted attributes. Matching only double
    /// quotes left those targets in place, so a real mailto:/tel: address rode
    /// out of the app inside the "redacted" package. The TargetMode guard has to
    /// be quote-agnostic for the same reason: a quote-agnostic rewrite sitting
    /// behind a double-quote-only guard is dead code for exactly the files that
    /// need it.
    private static func rewriteRelationshipElement(_ element: String) -> String {
        guard attributeValue("TargetMode", in: element) == "External" else { return element }
        guard let target = attributeValue("Target", in: element) else { return element }
        let lowered = target.lowercased()
        guard sensitiveSchemes.contains(where: { lowered.hasPrefix($0) }) else { return element }
        guard let regex = try? NSRegularExpression(pattern: targetAttributePattern) else {
            return element
        }
        let ns = element as NSString
        let full = NSRange(location: 0, length: ns.length)
        // escapedTemplate: the replacement is a literal, never a "$1" reference.
        let template = NSRegularExpression.escapedTemplate(
            for: "Target=\"\(neutralizedTarget)\""
        )
        return regex.stringByReplacingMatches(in: element, range: full, withTemplate: template)
    }

    /// Extract the unescaped value of an attribute from one tag, accepting
    /// either quote style. Returns nil when the attribute is absent.
    ///
    /// The two quote styles are separate alternatives rather than one [^"']
    /// character class so that a value keeps whichever quote it did not open
    /// with (see targetAttributePattern). The name is anchored to a preceding
    /// space so it matches a whole attribute name only, never the tail of a
    /// longer one ("Mode" must not match inside "TargetMode").
    private static func attributeValue(_ name: String, in element: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "(?<=\\s)\(escaped)=(?:\"([^\"]*)\"|'([^']*)')"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = element as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: element, range: full) else { return nil }
        // Exactly one of the two quote alternatives participates in a match.
        for group in 1 ... 2 where match.range(at: group).location != NSNotFound {
            return ns.substring(with: match.range(at: group))
        }
        return nil
    }
}
