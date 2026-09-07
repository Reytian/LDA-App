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
//   - Scrub the markup-borne PII of every text-bearing part and of
//     word/people.xml (field targets, revision and comment authors), via
//     DocxMarkupScrub, whether or not detection found anything in its text.
//
//  Offset convention: per-part w:t offsets are UTF-16 code units into that part's
//  own concatenated text, matching Span in CoreTypes.swift.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import ZIPFoundation

/// The fixed path of the package's content-type declarations.
let docxContentTypesPath = "[Content_Types].xml"

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
        /// The part's original bytes, so an untouched part can be re-emitted
        /// byte for byte.
        var data: Data
    }

    /// The outcome of loading every additional text-bearing part: the parts
    /// that parsed, and the paths of those that did not. A part that cannot be
    /// parsed cannot be redacted, and DocxZip.rewrite would otherwise copy it
    /// into the output verbatim, PII included, so the caller must refuse to
    /// write the package when failedParts is non-empty.
    struct LoadedParts {
        var parts: [LoadedPart]
        var failedParts: [String]
    }

    /// Loads and parses every additional text-bearing part, reporting the
    /// parts that failed instead of skipping them silently.
    ///
    /// A size ceiling is NOT a failed part and is rethrown. Collecting it here
    /// turned "this package inflates past the unpacking limit" into "3
    /// supplementary parts could not be redacted", which is the wrong thing to
    /// tell a lawyer and hides the ceiling that actually fired.
    static func loadTextBearingParts(
        from url: URL,
        budget: ArchiveBudget
    ) throws -> LoadedParts {
        var loaded: [LoadedPart] = []
        var failed: [String] = []
        for path in textBearingPartPaths(in: url) {
            do {
                loaded.append(try loadRequiredTextBearingPart(path, from: url, budget: budget))
            } catch let error as DocumentIOError {
                if case .tooLarge = error { throw error }
                failed.append(path)
            } catch {
                failed.append(path)
            }
        }
        return LoadedParts(parts: loaded, failedParts: failed)
    }

    /// Strict counterpart used by restoration. Once a package has enumerated a
    /// supplementary text part, silently omitting it would make the report and
    /// restored output look complete while leaving an unknown part untouched.
    private static func loadRequiredTextBearingParts(
        from url: URL,
        budget: ArchiveBudget
    ) throws -> [LoadedPart] {
        try textBearingPartPaths(in: url).map {
            try loadRequiredTextBearingPart($0, from: url, budget: budget)
        }
    }

    private static func loadRequiredTextBearingPart(
        _ path: String,
        from url: URL,
        budget: ArchiveBudget
    ) throws -> LoadedPart {
        let data = try DocxZip.readEntry(path, from: url, budget: budget)
        do {
            return LoadedPart(path: path, layout: try DocxDocumentXML.parse(data), data: data)
        } catch let error as DocumentIOError {
            // Name the part, keep the KIND. A size limit or an unreadable
            // namespace layout restated as "corrupt" would send a lawyer
            // looking for file damage that is not there.
            throw error.detailed(with: "cannot parse \(path)")
        } catch {
            throw DocumentIOError.corrupt(
                "cannot parse \(path): \(error.localizedDescription)"
            )
        }
    }

    /// The package-wide visible text used to report restoration outcomes.
    /// Body and supplementary parts are separated with NUL, which XML 1.0
    /// cannot contain, so an ordinary replacement can never match across the
    /// synthetic boundary. One combined scan also keeps orphan reporting
    /// global to the package rather than falsely orphaning a replacement in
    /// every individual part where it does not occur.
    static func restoreReportText(
        from url: URL,
        budget: ArchiveBudget = ArchiveBudget()
    ) throws -> String {
        let bodyData = try DocxZip.readEntry(docxMainPartPath, from: url, budget: budget)
        let body = try DocxDocumentXML.parse(bodyData)
        let partTexts = try loadRequiredTextBearingParts(from: url, budget: budget)
            .map { $0.layout.text }
        return ([body.text] + partTexts).joined(separator: "\u{0000}")
    }

    // MARK: - Redaction of text-bearing parts

    /// The result of redacting all non-body text parts plus scrubbing metadata and
    /// neutralizing external links.
    struct Result {
        /// path -> rewritten bytes, ready to feed DocxZip.rewrite's replacing dict.
        var replacements: [String: Data]
        /// New mapping entries minted for surfaces found only in non-body parts.
        var newEntries: [MappingEntry]
        /// Paths of supplementary parts that could not be parsed or rewritten.
        /// Their PII would ride into the output verbatim, so a non-empty list
        /// means the redaction must not be written (DocxRedactor.redact throws).
        var failedParts: [String]
        /// Members the export removes from the package entirely: the custom
        /// XML data store behind bound content controls, and the rendered
        /// first-page thumbnail. See DocxPackagePolicy.
        var removedParts: [String]
        /// Members the export can neither redact nor drop. A non-empty list
        /// means the package must not be written at all: copying such a part
        /// through would ship its content under a clean redaction report.
        var unsupportedParts: [String]
        /// What was covered outside the body, for the caller's coverage report.
        var coverage: DocxSupplementaryCoverage
    }

    /// What the supplementary parts of `url` would receive, WITHOUT writing
    /// anything. Runs the same detection, break splitting, and dominance
    /// filter the redaction pass runs, so a preview and the run it predicts
    /// cannot drift apart.
    ///
    /// A part that fails to parse is simply not counted here; the redaction
    /// pass refuses to write such a package, so no caller ever sees a coverage
    /// number for one.
    static func supplementaryCoverage(
        url: URL,
        detect: (String) -> [Span],
        budget: ArchiveBudget = ArchiveBudget()
    ) -> DocxSupplementaryCoverage {
        var coverage = DocxSupplementaryCoverage.none
        // A package that hits the unpacking ceiling previews as zero rather
        // than throwing from a coverage number. It cannot mislead: the
        // redaction pass reads the same parts under the same ceiling and
        // refuses to write anything, so no artifact ever ships behind an
        // under-reported preview.
        let loaded = (try? loadTextBearingParts(from: url, budget: budget))
            ?? LoadedParts(parts: [], failedParts: [])
        for part in loaded.parts {
            coverage.add(acceptedSupplementarySpans(in: part.layout.text, detect: detect))
        }
        return coverage
    }

    /// The spans one supplementary part's text would actually have replaced:
    /// detected, split at synthetic breaks (a surface carrying a paragraph
    /// newline, line break, or tab cannot restore into a single run; see
    /// SpanSplitter), then reduced to the dominant non-overlapping set.
    ///
    /// The single source of truth for both the redaction pass and the preview.
    private static func acceptedSupplementarySpans(
        in text: String,
        detect: (String) -> [Span]
    ) -> [Span] {
        acceptedSpans(SpanSplitter.splitAtBreaks(detect(text), in: text), in: text)
    }

    /// Redact every non-body text part, scrub docProps metadata, and neutralize
    /// external mailto:/tel: hyperlink Targets.
    ///
    /// - Parameters:
    ///   - url: the source .docx.
    ///   - mapping: the body mapping (read-only here); used so a surface already
    ///     mapped in the body reuses its token.
    ///   - detect: detection over arbitrary text (deterministic plus optional LLM).
    /// - Returns: the per-path rewritten bytes, any new mapping entries, and
    ///   how much was covered outside the body.
    static func redactNonBodyParts(
        url: URL,
        mapping: Mapping,
        detect: (String) -> [Span],
        budget: ArchiveBudget
    ) throws -> Result {
        let loaded = try loadTextBearingParts(from: url, budget: budget)
        var text = redactedTextParts(loaded.parts, mapping: mapping, detect: detect)
        text.failedParts += loaded.failedParts

        // What this package holds that the export removes, and what makes it
        // refuse outright. Classified before any reference cleanup, because
        // the cleanup has to know what is going away.
        let classified = DocxPackagePolicy.classify(paths: enumerateEntryPaths(in: url))
        var replacements = text.replacements
        for (path, bytes) in scrubbedMetadataParts(url: url, budget: budget) {
            replacements[path] = bytes
        }
        for (path, bytes) in cleanedPackageParts(url: url, dropped: classified.dropped, budget: budget) {
            replacements[path] = bytes
        }

        return Result(
            replacements: replacements,
            newEntries: text.newEntries,
            failedParts: text.failedParts,
            removedParts: classified.dropped,
            unsupportedParts: classified.unsupported,
            coverage: text.coverage
        )
    }

    /// What redacting the supplementary TEXT parts produced, before the
    /// metadata scrubs and the package-plumbing cleanup are folded in.
    private struct TextPartRedaction {
        var replacements: [String: Data] = [:]
        var newEntries: [MappingEntry] = []
        var failedParts: [String] = []
        var coverage = DocxSupplementaryCoverage.none
    }

    /// Every normalized surface the body mapping already knows, aliases
    /// included, pointing at the token it was given. A surface a header
    /// repeats must reuse the body's token, not mint a second one.
    private static func tokensByNormalizedSurface(in mapping: Mapping) -> [String: String] {
        var tokens: [String: String] = [:]
        for entry in mapping.entries.values {
            tokens[TextMatching.normalize(entry.surfaceText)] = entry.token
            for alias in entry.aliases {
                tokens[TextMatching.normalize(alias)] = entry.token
            }
        }
        return tokens
    }

    /// Redact every supplementary text part, minting tokens that continue the
    /// body's per-type numbering and reusing the body's token for a surface
    /// the body already mapped.
    private static func redactedTextParts(
        _ parts: [LoadedPart],
        mapping: Mapping,
        detect: (String) -> [Span]
    ) -> TextPartRedaction {
        // Token reuse index and per-type counters seeded from the body mapping,
        // then carried across parts so numbering never collides.
        var tokenByNormSurface = tokensByNormalizedSurface(in: mapping)
        var counters = perTypeMaxIndices(in: mapping.entries.keys)
        var outcome = TextPartRedaction()

        for part in parts {
            // Exactly the spans supplementaryCoverage would preview, so the
            // preview and this pass can never disagree.
            let accepted = acceptedSupplementarySpans(in: part.layout.text, detect: detect)
            outcome.coverage.add(accepted)

            // Resolve a token for each accepted span, extending the mapping.
            let replacementsForPart = accepted.map { span in
                Replacement(
                    span: span,
                    token: resolveToken(
                        for: span,
                        tokenByNormSurface: &tokenByNormSurface,
                        counters: &counters,
                        newEntries: &outcome.newEntries
                    )
                )
            }

            // Every part also loses the PII its markup carries (field targets,
            // revision authors), even when detection found nothing in its text.
            // A part neither pass touched is not listed, so it copies through
            // byte for byte.
            guard let rewritten = redactedPartXML(part, replacements: replacementsForPart) else {
                outcome.failedParts.append(part.path)
                continue
            }
            let scrubbed = DocxMarkupScrub.scrubRedactedPart(rewritten)
            if !replacementsForPart.isEmpty || scrubbed != rewritten {
                outcome.replacements[part.path] = Data(scrubbed.utf8)
            }
        }
        return outcome
    }

    /// The identity metadata parts, blanked. Read best effort: a package that
    /// carries none of them simply contributes nothing here.
    private static func scrubbedMetadataParts(
        url: URL,
        budget: ArchiveBudget
    ) -> [String: Data] {
        // Custom document properties matter as much as the core ones:
        // DMS-stamped client names, matter numbers, and billing codes
        // routinely live there as string values.
        let scrubs: [(String, (String) -> String)] = [
            (DocxMarkupScrub.peoplePartPath, DocxMarkupScrub.scrubPeoplePart),
            (docxCorePropsPath, scrubCoreProps),
            (docxAppPropsPath, scrubAppProps),
            (docxCustomPropsPath, scrubCustomProps)
        ]
        var replacements: [String: Data] = [:]
        for (path, scrub) in scrubs {
            guard let data = try? DocxZip.readEntry(path, from: url, budget: budget),
                  let xml = String(data: data, encoding: .utf8) else { continue }
            replacements[path] = Data(scrub(xml).utf8)
        }
        return replacements
    }

    /// The package plumbing, cleaned: external mailto:/tel: hyperlink targets
    /// neutralized in every .rels part, relationships to a removed member
    /// dropped, and the content-type overrides of removed members dropped, so
    /// the package declares and references no part it no longer carries.
    private static func cleanedPackageParts(
        url: URL,
        dropped: [String],
        budget: ArchiveBudget
    ) -> [String: Data] {
        var replacements: [String: Data] = [:]
        for relsPath in relsPartPaths(in: url) {
            guard let data = try? DocxZip.readEntry(relsPath, from: url, budget: budget),
                  let xml = String(data: data, encoding: .utf8) else { continue }
            let cleaned = DocxPackagePolicy.removeDroppedRelationships(
                neutralizeExternalTargets(xml)
            )
            if cleaned != xml {
                replacements[relsPath] = Data(cleaned.utf8)
            }
        }
        guard !dropped.isEmpty,
              let data = try? DocxZip.readEntry(docxContentTypesPath, from: url, budget: budget),
              let xml = String(data: data, encoding: .utf8) else { return replacements }
        let cleaned = DocxPackagePolicy.removeDroppedOverrides(xml)
        if cleaned != xml {
            replacements[docxContentTypesPath] = Data(cleaned.utf8)
        }
        return replacements
    }

    // MARK: - Restore of text-bearing parts

    /// Re-substitute a token-style mapping's sites across every non-body text
    /// part of a redacted package, returning the rewritten bytes per path. The
    /// plan decides the brace tokens and any entries carried from another
    /// style together over each part's whole text (see
    /// Restorer.tokenStyleRestoreSites). The docProps and .rels scrubs are
    /// destructive and are not reversed (there is nothing to restore).
    static func restoreNonBodyPartsTokenStyle(
        url: URL,
        plan: Restorer.TokenStyleRestorePlan,
        budget: ArchiveBudget
    ) throws -> [String: Data] {
        var replacements: [String: Data] = [:]
        for part in try loadRequiredTextBearingParts(from: url, budget: budget) {
            var layout = part.layout
            let outcome = try DocxRedactor.restoreTokenStyleInLayout(&layout, plan: plan)
            guard outcome.restoredCount > 0 else { continue }
            replacements[part.path] = DocxDocumentXML.serialize(layout)
        }
        return replacements
    }

    /// Literal-style counterpart of restoreNonBodyParts: re-substitute every
    /// unambiguous replacement string across the non-body text parts. Used
    /// for pseudonym and asterisk mappings.
    ///
    /// Each part is decided over its own whole concatenated text rather than
    /// run by run, so a replacement split across runs by Word is resolved on
    /// the string a reader sees. A part whose restore throws is left as it was
    /// rather than written half done.
    static func restoreNonBodyPartsLiteral(
        url: URL,
        plan: Restorer.LiteralRestorePlan,
        budget: ArchiveBudget
    ) throws -> [String: Data] {
        var replacements: [String: Data] = [:]
        for part in try loadRequiredTextBearingParts(from: url, budget: budget) {
            var layout = part.layout
            let outcome = try DocxRedactor.restoreLiteralInLayout(&layout, plan: plan)
            guard outcome.restoredCount > 0 else { continue }
            replacements[part.path] = DocxDocumentXML.serialize(layout)
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

    /// The part's XML after applying `replacements`: the original bytes when
    /// there is nothing to redact, so an untouched part stays byte-identical;
    /// nil when the part cannot be rewritten.
    private static func redactedPartXML(_ part: LoadedPart, replacements: [Replacement]) -> String? {
        if replacements.isEmpty {
            return String(data: part.data, encoding: .utf8)
        }
        return try? redactLayout(part.layout, replacements: replacements)
    }

    /// Apply replacements to a parsed layout and return the serialized XML. This
    /// reuses DocxRedactor's run-edit planning so cross-run spans and multiple
    /// spans per run behave identically to the body path.
    private static func redactLayout(
        _ layout: DocxLayout,
        replacements: [Replacement]
    ) throws -> String {
        var working = layout
        let edits = try DocxRedactor.planRunEdits(
            replacements,
            runs: working.runs,
            segments: working.segments
        )
        for (segmentIndex, segmentEdits) in edits {
            try DocxRedactor.applyRunEdits(segmentEdits, atSegment: segmentIndex, in: &working)
        }
        return DocxDocumentXML.serializeXML(working)
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
    /// Shared with DocxMarkupScrub, which applies the same rule to field
    /// instructions.
    static let sensitiveSchemes = ["mailto:", "tel:"]

    /// Replacement Target value written over a neutralized external link.
    static let neutralizedTarget = "about:blank"

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

    /// Attribute reading lives in DocxAttributes, shared with the package
    /// policy: both passes must read Target the same quote-agnostic way.
    private static func attributeValue(_ name: String, in element: String) -> String? {
        DocxAttributes.value(name, in: element)
    }
}
