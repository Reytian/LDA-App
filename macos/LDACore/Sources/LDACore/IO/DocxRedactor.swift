//
//  DocxRedactor.swift
//  LDACore
//
//  Run-preserving redaction and restoration for .docx edit surfaces.
//
//  redact: re-open the original .docx, apply Replacements to the w:t runs of
//  word/document.xml, and write a new .docx to out. A replacement span may cross
//  several runs; the token is written into the FIRST overlapped run and the
//  covered substring is deleted from every other overlapped run. All other runs
//  and all formatting are preserved. The redacted .docx is the edit surface.
//
//  restore: because each token sits within a single run after redaction, do a
//  per-run find/replace of token -> value across all w:t runs and re-zip to out.
//
//  restoreLiteral: the pseudonym and asterisk styles have no brace grammar, so
//  a replacement is an ordinary string that Word may have split across runs and
//  whose ambiguity can only be judged against its neighbours. That pass decides
//  over the part's WHOLE concatenated text, the same string the compliance
//  report scans, and writes the accepted sites back through the run planner. A
//  per-run decision would read a different string than the report and could
//  name the wrong party at a site the report calls untouched.
//
//  Offset convention: Replacement.span offsets are UTF-16 code units into the
//  text produced by DocxImporter, matching Span in CoreTypes.swift.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

public enum DocxRedactor {

    // MARK: - Redact

    /// Apply replacements to the runs of original's document.xml and write a new
    /// .docx to out. Spans that cross multiple runs put the token in the first
    /// overlapped run and delete the covered text from the others.
    ///
    /// The body is always redacted. When `nonBody` is supplied (a detector plus
    /// the body mapping), every other text-bearing part (headers, footers,
    /// footnotes, endnotes, comments) is also redacted, the docProps author/title
    /// metadata is scrubbed, and external mailto:/tel: hyperlink Targets are
    /// neutralized, all in the same single rewrite. Any token minted for a surface
    /// found only in a non-body part is returned so the caller can fold it into the
    /// mapping sidecar (and therefore restore it). When `nonBody` is nil the
    /// behavior is exactly the body-only legacy path.
    @discardableResult
    public static func redact(
        original: URL,
        replacements: [Replacement],
        to out: URL,
        nonBody: (mapping: Mapping, detect: (String) -> [Span])? = nil
    ) throws -> [MappingEntry] {
        let data = try DocxZip.readEntry(docxMainPartPath, from: original)
        var layout = try DocxDocumentXML.parse(data)

        // Plan every per-run edit against the ORIGINAL run offsets first, then
        // apply edits one segment at a time from the highest local offset down.
        // Planning against original offsets keeps multi-run spans and multiple
        // distinct spans inside the same run correct, because no edit observes a
        // length already changed by another edit.
        let edits = try planRunEdits(replacements, runs: layout.runs, segments: layout.segments)

        for (segmentIndex, segmentEdits) in edits {
            try applyRunEdits(segmentEdits, atSegment: segmentIndex, in: &layout)
        }

        var rewriteParts: [String: Data] = [docxMainPartPath: DocxDocumentXML.serialize(layout)]
        var newEntries: [MappingEntry] = []

        if let nonBody {
            let result = DocxParts.redactNonBodyParts(
                url: original,
                mapping: nonBody.mapping,
                detect: nonBody.detect
            )
            // The body part is never produced by DocxParts, so this merge never
            // clobbers the body rewrite computed above.
            for (path, bytes) in result.replacements {
                rewriteParts[path] = bytes
            }
            newEntries = result.newEntries
        }

        try DocxZip.rewrite(
            source: original,
            replacing: rewriteParts,
            to: out
        )
        return newEntries
    }

    /// How many embedded media files (word/media/...) the package carries.
    /// These copy verbatim into the redacted output without PII scanning, so
    /// a non-zero count must be surfaced to the user as a warning (wet-ink
    /// signature scans and stamps live there).
    public static func embeddedMediaCount(in url: URL) -> Int {
        DocxParts.embeddedMediaPaths(in: url).count
    }

    /// A single run-local edit: replace the run-local UTF-16 range
    /// [localStart, localEnd) with insertText.
    struct RunEdit {
        var localStart: Int
        var localEnd: Int
        var insertText: String
    }

    /// One edit expressed against the concatenated document text: replace the
    /// UTF-16 range [start, end) with insertText. Redaction writes tokens over
    /// detected spans, restoration writes values over replacement sites, and
    /// both land on the runs through the same planner.
    struct TextEdit {
        var start: Int
        var end: Int
        var insertText: String
    }

    /// Turn replacements into a map of segment index to the list of run-local
    /// edits for that segment. The FIRST overlapped run of each replacement gets
    /// the token; every other overlapped run has its covered text deleted.
    ///
    /// Exposed at internal access so DocxParts can reuse the exact same run-edit
    /// planning for non-body parts, keeping cross-run behavior identical.
    static func planRunEdits(
        _ replacements: [Replacement],
        runs: [DocxRun],
        segments: [DocxSegment]
    ) throws -> [(Int, [RunEdit])] {
        try planRunEdits(
            replacements.map {
                TextEdit(start: $0.span.start, end: $0.span.end, insertText: $0.token)
            },
            runs: runs,
            segments: segments
        )
    }

    /// Turn document-text edits into per-segment run-local edits. The FIRST
    /// overlapped run of each edit receives the inserted text; every other
    /// overlapped run has its covered text deleted.
    static func planRunEdits(
        _ edits: [TextEdit],
        runs: [DocxRun],
        segments: [DocxSegment]
    ) throws -> [(Int, [RunEdit])] {
        var bySegment: [Int: [RunEdit]] = [:]

        for edit in edits {
            let spanStart = edit.start
            let spanEnd = edit.end
            guard spanEnd > spanStart else { continue }

            // Runs that overlap the span, in document order.
            let overlapped = runs.filter { run in
                let runStart = run.charStart
                let runEnd = run.charStart + run.charLength
                return max(spanStart, runStart) < min(spanEnd, runEnd)
            }
            guard !overlapped.isEmpty else { continue }

            for (offset, run) in overlapped.enumerated() {
                let runStart = run.charStart
                let runEnd = run.charStart + run.charLength
                let localStart = max(spanStart, runStart) - runStart
                let localEnd = min(spanEnd, runEnd) - runStart
                let insert = offset == 0 ? edit.insertText : ""
                bySegment[run.textSegmentIndex, default: []].append(
                    RunEdit(localStart: localStart, localEnd: localEnd, insertText: insert)
                )
            }
        }

        // Validate every targeted segment is a run-text segment.
        for index in bySegment.keys {
            guard case .runText = segments[index] else {
                throw DocumentIOError.corrupt("edit targets a non-text segment")
            }
        }

        // Deterministic segment order.
        return bySegment.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// Apply a list of run-local edits to a single run-text segment. Edits are
    /// applied from the highest localStart down so earlier offsets stay valid.
    ///
    /// Exposed at internal access so DocxParts can reuse it for non-body parts.
    static func applyRunEdits(
        _ edits: [RunEdit],
        atSegment segmentIndex: Int,
        in layout: inout DocxLayout
    ) throws {
        guard case .runText(let original) = layout.segments[segmentIndex] else {
            throw DocumentIOError.corrupt("run segment index does not point at run text")
        }

        var current = original as NSString
        let ordered = edits.sorted { $0.localStart > $1.localStart }
        for edit in ordered {
            let prefix = current.substring(to: edit.localStart)
            let suffix = current.substring(from: edit.localEnd)
            current = (prefix + edit.insertText + suffix) as NSString
        }
        layout.segments[segmentIndex] = .runText(current as String)
    }

    // MARK: - Restore

    /// Replace every token in a redacted .docx with its value and write to out.
    /// Each token lives entirely within one run, so a per-run find/replace using
    /// the token grammar is correct and safe.
    ///
    /// Tokens are restored in the body AND in every other text-bearing part
    /// (headers, footers, footnotes, endnotes, comments), so a value redacted in a
    /// header round-trips back. The docProps metadata scrub and external-link
    /// neutralization done at redact time are destructive and are not reversed.
    public static func restore(
        redactedDocx: URL,
        tokenToValue: [String: String],
        to out: URL
    ) throws {
        let data = try DocxZip.readEntry(docxMainPartPath, from: redactedDocx)
        var layout = try DocxDocumentXML.parse(data)

        let tokenRegex = try NSRegularExpression(pattern: TokenGrammar.placeholderPattern)

        for index in layout.segments.indices {
            guard case .runText(let text) = layout.segments[index] else { continue }
            guard text.contains("{") else { continue }

            let replaced = replaceTokens(in: text, using: tokenRegex, tokenToValue: tokenToValue)
            if replaced != text {
                layout.segments[index] = .runText(replaced)
            }
        }

        var rewriteParts: [String: Data] = [docxMainPartPath: DocxDocumentXML.serialize(layout)]
        // Restore tokens in the non-body text parts too.
        let nonBody = DocxParts.restoreNonBodyParts(url: redactedDocx, tokenToValue: tokenToValue)
        for (path, bytes) in nonBody {
            rewriteParts[path] = bytes
        }

        try DocxZip.rewrite(
            source: redactedDocx,
            replacing: rewriteParts,
            to: out
        )
    }

    /// What a literal restore did to one part, in the same terms the
    /// whole-document report uses, so caller and report can be compared.
    public struct LiteralRestoreOutcome: Sendable, Equatable {
        /// Occurrences substituted with their original value.
        public let restoredCount: Int
        /// Replacements left verbatim because their site could not be
        /// attributed to one entity, in first-seen document order.
        public let ambiguousReplacements: [String]

        /// Nothing was substituted and nothing was refused.
        static let unchanged = LiteralRestoreOutcome(
            restoredCount: 0,
            ambiguousReplacements: []
        )
    }

    /// Replace every literal replacement string in a redacted .docx with its
    /// value and write to out. The literal-style counterpart of restore: used
    /// for pseudonym and asterisk mappings, whose replacements are ordinary
    /// strings rather than grammar tokens.
    ///
    /// The plan (Restorer.literalRestorePlan) carries which replacements may
    /// be substituted and whether the style refuses a prefix conflict at a
    /// site, so an ambiguous asterisk mask stays verbatim in the document and
    /// this surface reaches the same verdicts as the report.
    ///
    /// Returns what the BODY part did. The report scans the body text, so the
    /// returned outcome is directly comparable with it; the other text parts
    /// are restored on the same plan but have never been part of that report.
    @discardableResult
    public static func restoreLiteral(
        redactedDocx: URL,
        plan: Restorer.LiteralRestorePlan,
        to out: URL
    ) throws -> LiteralRestoreOutcome {
        let data = try DocxZip.readEntry(docxMainPartPath, from: redactedDocx)
        var layout = try DocxDocumentXML.parse(data)
        let outcome = try restoreLiteralInLayout(&layout, plan: plan)

        var rewriteParts: [String: Data] = [docxMainPartPath: DocxDocumentXML.serialize(layout)]
        // Restore literal replacements in the non-body text parts too.
        let nonBody = DocxParts.restoreNonBodyPartsLiteral(url: redactedDocx, plan: plan)
        for (path, bytes) in nonBody {
            rewriteParts[path] = bytes
        }

        try DocxZip.rewrite(
            source: redactedDocx,
            replacing: rewriteParts,
            to: out
        )
        return outcome
    }

    /// Restore literal replacements across one whole parsed part.
    ///
    /// The decision runs over the part's CONCATENATED text, which is exactly
    /// the string the report scan reads, and the accepted sites are written
    /// back into the runs they cover. Deciding run by run instead is the
    /// defect this closes in both directions: a mask split across runs looked
    /// unambiguous on an isolated run, so the writer named a person the report
    /// reported as never guessed, and a replacement split across runs matched
    /// nowhere, so the writer restored nothing the report had counted.
    ///
    /// Exposed at internal access so DocxParts restores the non-body parts the
    /// same way.
    static func restoreLiteralInLayout(
        _ layout: inout DocxLayout,
        plan: Restorer.LiteralRestorePlan
    ) throws -> LiteralRestoreOutcome {
        let sites = Restorer.literalRestoreSites(in: layout.text, plan: plan)
        guard !sites.isEmpty else { return .unchanged }

        var edits: [TextEdit] = []
        var restoredCount = 0
        var refusedSeen: Set<String> = []
        var refused: [String] = []

        for site in sites {
            guard let value = site.value else {
                if refusedSeen.insert(site.replacement).inserted {
                    refused.append(site.replacement)
                }
                continue
            }
            guard runsCover(site.range, runs: layout.runs) else { continue }
            edits.append(
                TextEdit(
                    start: site.range.location,
                    end: site.range.location + site.range.length,
                    insertText: value
                )
            )
            restoredCount += 1
        }

        for (segmentIndex, segmentEdits) in try planRunEdits(
            edits,
            runs: layout.runs,
            segments: layout.segments
        ) {
            try applyRunEdits(segmentEdits, atSegment: segmentIndex, in: &layout)
        }

        return LiteralRestoreOutcome(
            restoredCount: restoredCount,
            ambiguousReplacements: refused
        )
    }

    /// Whether run text covers `range` end to end with no gap.
    ///
    /// Every character of a part's concatenated text is either run text or a
    /// synthetic paragraph newline that belongs to no run. A site straddling
    /// such a newline cannot be written back faithfully: the value would land
    /// in the first run while the newline stayed behind. Detected spans are
    /// split at line breaks before tokenization (see SpanSplitter), so no
    /// replacement the pipeline mints carries one and this guard never fires
    /// in practice. When it does, leaving the bytes alone is the safe
    /// direction: the document keeps the redacted text rather than gaining a
    /// value in the wrong place.
    private static func runsCover(_ range: NSRange, runs: [DocxRun]) -> Bool {
        let end = range.location + range.length
        var covered = range.location
        for run in runs where run.charStart <= covered
            && run.charStart + run.charLength > covered {
            covered = run.charStart + run.charLength
            if covered >= end { return true }
        }
        return false
    }

    /// Replace all grammar-matched tokens in a single run's text with their
    /// mapped values. Tokens absent from tokenToValue are left untouched so the
    /// orphan guard downstream can flag them.
    ///
    /// The scan is shared with Restorer (see TokenSubstitution): a docx run and
    /// a plain-text surface must agree on what a token is and on leaving an
    /// unknown one verbatim, or the same document restores differently
    /// depending on which surface it came back on.
    private static func replaceTokens(
        in text: String,
        using regex: NSRegularExpression,
        tokenToValue: [String: String]
    ) -> String {
        TokenSubstitution.substitute(in: text, matching: regex) { token in
            tokenToValue[token]
        }.text
    }
}
