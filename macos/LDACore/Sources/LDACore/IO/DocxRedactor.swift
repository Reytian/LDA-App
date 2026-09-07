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
//  restore: find tokens in each part's whole concatenated text and write values
//  back through the run planner. This also handles a token Word split across
//  runs after redaction.
//
//  Formatting of a cross-run entity (known limitation): the mapping records
//  values, not run boundaries, so a restored value is written whole into the
//  first run its token covers and takes that run's formatting. An email whose
//  first letters were bold and whose remainder was not comes back entirely
//  bold. Every other run keeps its own formatting. RestoreReport has no field
//  for this yet, so it is documented here rather than surfaced per document.
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

/// How much redaction happened, or would happen, in the DOCX parts outside
/// word/document.xml (headers, footers, footnotes, endnotes, comments).
///
/// Counts SITES, not distinct values, and is therefore usually LARGER than
/// the number of mapping entries those parts mint: a header that repeats a
/// body name reuses the body token and mints no entry, yet the redacted
/// package carries that replacement and a restore puts it back. Sites are
/// what makes a reported total agree with RestoreReport.restoredCount.
///
/// Counts only. No surface text, no offsets, and no part paths: a part path
/// can itself be PII, and a supplementary offset would collide with a body
/// offset if the two lists were ever flattened into one.
public struct DocxSupplementaryCoverage: Sendable, Equatable {
    /// Total replacements across every supplementary part.
    public var replacementCount: Int
    /// Those replacements' types and how many of each. Sums to
    /// replacementCount.
    public var countsByType: [EntityType: Int]

    /// Nothing outside the body: no such parts, or nothing detected in them.
    public static let none = DocxSupplementaryCoverage(replacementCount: 0, countsByType: [:])

    public init(replacementCount: Int, countsByType: [EntityType: Int]) {
        self.replacementCount = replacementCount
        self.countsByType = countsByType
    }

    /// Fold one part's accepted spans in.
    mutating func add(_ spans: [Span]) {
        replacementCount += spans.count
        for span in spans {
            countsByType[span.type, default: 0] += 1
        }
    }
}

/// What redacting the DOCX parts outside word/document.xml produced.
///
/// Empty when DocxRedactor.redact ran without a `nonBody` argument (the
/// body-only legacy path used to fill forms).
public struct DocxNonBodyOutcome: Sendable, Equatable {
    /// Tokens minted for surfaces found ONLY outside the body. The caller
    /// folds these into the mapping sidecar so they restore.
    public var newEntries: [MappingEntry]
    /// How much those parts received, for the caller's coverage report.
    public var coverage: DocxSupplementaryCoverage

    public static let empty = DocxNonBodyOutcome(newEntries: [], coverage: .none)

    public init(newEntries: [MappingEntry], coverage: DocxSupplementaryCoverage) {
        self.newEntries = newEntries
        self.coverage = coverage
    }
}

public enum DocxRedactor {

    // MARK: - Redact

    /// Apply replacements to the runs of original's document.xml and write a new
    /// .docx to out. Spans that cross multiple runs put the token in the first
    /// overlapped run and delete the covered text from the others.
    ///
    /// The body is always redacted. When `nonBody` is supplied (a detector plus
    /// the body mapping), every other text-bearing part (headers, footers,
    /// footnotes, endnotes, comments) is also redacted, the docProps author/title
    /// metadata is scrubbed, external mailto:/tel: hyperlink Targets are
    /// neutralized, and the markup-borne PII of every part is scrubbed
    /// (mailto:/tel: field instruction targets, revision and comment authors,
    /// word/people.xml; see DocxMarkupScrub), all in the same single rewrite.
    /// Any token minted for a surface found only in a non-body part is returned
    /// so the caller can fold it into the mapping sidecar (and therefore restore
    /// it), together with how many replacements those parts received so the
    /// caller can report coverage that matches what the file carries. When
    /// `nonBody` is nil the behavior is exactly the body-only legacy path used
    /// to fill forms: run text is rewritten, nothing else changes, and the
    /// outcome is empty.
    @discardableResult
    public static func redact(
        original: URL,
        replacements: [Replacement],
        to out: URL,
        nonBody: (mapping: Mapping, detect: (String) -> [Span])? = nil,
        budget: ArchiveBudget = ArchiveBudget()
    ) throws -> DocxNonBodyOutcome {
        // ONE ledger for this whole pass: the body, every supplementary part,
        // and the members the rewrite inflates to copy all spend it. A ledger
        // per read would give each part the full ceiling, which is the
        // non-compounding bug ArchiveBudget exists to prevent. Replaced
        // members are charged once, on the read, never again on the write.
        let data = try DocxZip.readEntry(docxMainPartPath, from: original, budget: budget)
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

        let bodyXML = DocxDocumentXML.serializeXML(layout)
        var rewriteParts: [String: Data] = [docxMainPartPath: Data(bodyXML.utf8)]
        var outcome = DocxNonBodyOutcome.empty
        // Members the privacy export removes. Empty on the body-only fill
        // path: filling a form is not a privacy export, so the package the
        // user keeps stays whole.
        var removals: Set<String> = []

        if let nonBody {
            // The redacted copy also loses the PII the body keeps in markup:
            // mailto:/tel: field targets and revision authors.
            rewriteParts[docxMainPartPath] = Data(DocxMarkupScrub.scrubRedactedPart(bodyXML).utf8)
            let result = try DocxParts.redactNonBodyParts(
                url: original,
                mapping: nonBody.mapping,
                detect: nonBody.detect,
                budget: budget
            )
            // A supplementary part that could not be parsed or rewritten would
            // copy into the output verbatim, PII included, while the caller
            // reported success. Refuse before anything is written. The message
            // carries the count, never a path: a part path can itself be PII.
            guard result.failedParts.isEmpty else {
                let count = result.failedParts.count
                let noun = count == 1 ? "part" : "parts"
                throw DocumentIOError.corrupt(
                    "\(count) supplementary \(noun) (header, footer, notes, or comments) "
                        + "could not be redacted, so the package was not written"
                )
            }
            // A member the export can neither redact nor drop would copy into
            // the output verbatim while the caller reported a clean
            // redaction. Refuse before anything is written; the message
            // carries the count, never a path.
            guard result.unsupportedParts.isEmpty else {
                throw DocxPackagePolicy.unsupportedPartsError(count: result.unsupportedParts.count)
            }
            // The body part is never produced by DocxParts, so this merge never
            // clobbers the body rewrite computed above.
            for (path, bytes) in result.replacements {
                rewriteParts[path] = bytes
            }
            removals = Set(result.removedParts)
            outcome = DocxNonBodyOutcome(
                newEntries: result.newEntries,
                coverage: result.coverage
            )
        }

        try DocxZip.rewrite(
            source: original,
            replacing: rewriteParts,
            removing: removals,
            to: out,
            budget: budget
        )
        return outcome
    }

    /// What the supplementary parts of `original` WOULD receive, writing
    /// nothing. Runs the same detection, break splitting, and dominance filter
    /// redact runs, so a preview and the redaction it predicts cannot drift.
    ///
    /// This is the only public way to ask the question without producing an
    /// artifact; the window uses it to state honest coverage while the user is
    /// still reviewing, and LDAService.detectSummary uses it for the same
    /// reason on the CLI and MCP edges.
    public static func supplementaryCoverage(
        in original: URL,
        detect: (String) -> [Span],
        budget: ArchiveBudget = ArchiveBudget()
    ) -> DocxSupplementaryCoverage {
        DocxParts.supplementaryCoverage(url: original, detect: detect, budget: budget)
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
        let rewritten = current as String
        layout.segments[segmentIndex] = .runText(rewritten)

        // A rewrite that leaves whitespace at either edge of the run (the tail
        // of an email whose head sat in a bold run, a value restored ahead of
        // a following space) must mark its element xml:space="preserve", or
        // Word drops that space. Runs the rewrite did not touch keep their
        // start tag byte for byte.
        guard DocxRunText.needsSpacePreserve(rewritten) else { return }
        try preserveSpace(onTextElementBefore: segmentIndex, in: &layout)
    }

    /// Rewrite the start tag of the text element whose content is segment
    /// `segmentIndex` so it carries xml:space="preserve". The parser emits a
    /// text element's start tag as the markup segment immediately before its
    /// runText segment, so that is the segment rewritten. Any other shape means
    /// the layout did not come from DocxDocumentXML.parse, an internal error
    /// that is reported rather than papered over.
    private static func preserveSpace(
        onTextElementBefore segmentIndex: Int,
        in layout: inout DocxLayout
    ) throws {
        guard segmentIndex > 0,
              case .markup(let openTag) = layout.segments[segmentIndex - 1],
              DocxRunText.isTextOpenTag(openTag) else {
            throw DocumentIOError.corrupt(
                "run text segment is not preceded by its text element start tag"
            )
        }
        layout.segments[segmentIndex - 1] = .markup(DocxRunText.openTagPreservingSpace(openTag))
    }

    // MARK: - Restore

    /// Replace every token in a redacted .docx with its value and write to out.
    /// Token sites are found in whole-part text and written through the shared
    /// run planner, so later Word formatting cannot strand a split token that
    /// the package-wide restore report counted.
    ///
    /// Tokens are restored in the body AND in every other text-bearing part
    /// (headers, footers, footnotes, endnotes, comments), so a value redacted in a
    /// header round-trips back. The docProps metadata scrub and external-link
    /// neutralization done at redact time are destructive and are not reversed.
    ///
    /// A bare token table carries nothing from another style; a mapping that
    /// does goes through restoreTokenStyle(redactedDocx:plan:to:).
    public static func restore(
        redactedDocx: URL,
        tokenToValue: [String: String],
        to out: URL
    ) throws {
        try restoreTokenStyle(
            redactedDocx: redactedDocx,
            plan: Restorer.tokenStyleRestorePlan(tokenToValue: tokenToValue),
            to: out
        )
    }

    /// Replace every site of a token-style mapping in a redacted .docx and
    /// write to out: the brace tokens and, for a mapping that carries
    /// pseudonym entries from another style, those literals too.
    ///
    /// Every part is decided over its whole text in ONE pass by
    /// Restorer.tokenStyleRestoreSites, the decision the text report takes,
    /// so a carried literal is never written inside a value the tokens
    /// restored and the writer reaches the sites the report counted.
    ///
    /// Returns what the body part did; LDAService reports over the
    /// package-wide pre-restore text independently.
    @discardableResult
    public static func restoreTokenStyle(
        redactedDocx: URL,
        plan: Restorer.TokenStyleRestorePlan,
        to out: URL,
        budget: ArchiveBudget = ArchiveBudget()
    ) throws -> LiteralRestoreOutcome {
        let data = try DocxZip.readEntry(docxMainPartPath, from: redactedDocx, budget: budget)
        var layout = try DocxDocumentXML.parse(data)
        let outcome = try restoreTokenStyleInLayout(&layout, plan: plan)

        var rewriteParts: [String: Data] = [docxMainPartPath: DocxDocumentXML.serialize(layout)]
        // Restore the same sites in the non-body text parts too.
        let nonBody = try DocxParts.restoreNonBodyPartsTokenStyle(
            url: redactedDocx,
            plan: plan,
            budget: budget
        )
        for (path, bytes) in nonBody {
            rewriteParts[path] = bytes
        }

        try DocxZip.rewrite(
            source: redactedDocx,
            replacing: rewriteParts,
            to: out,
            budget: budget
        )
        return outcome
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
    /// Returns what the body part did. LDAService reports over the package-wide
    /// pre-restore text independently, while this outcome remains useful to
    /// callers that operate directly on DocxRedactor.
    @discardableResult
    public static func restoreLiteral(
        redactedDocx: URL,
        plan: Restorer.LiteralRestorePlan,
        to out: URL,
        budget: ArchiveBudget = ArchiveBudget()
    ) throws -> LiteralRestoreOutcome {
        let data = try DocxZip.readEntry(docxMainPartPath, from: redactedDocx, budget: budget)
        var layout = try DocxDocumentXML.parse(data)
        let outcome = try restoreLiteralInLayout(&layout, plan: plan)

        var rewriteParts: [String: Data] = [docxMainPartPath: DocxDocumentXML.serialize(layout)]
        // Restore literal replacements in the non-body text parts too.
        let nonBody = try DocxParts.restoreNonBodyPartsLiteral(
            url: redactedDocx,
            plan: plan,
            budget: budget
        )
        for (path, bytes) in nonBody {
            rewriteParts[path] = bytes
        }

        try DocxZip.rewrite(
            source: redactedDocx,
            replacing: rewriteParts,
            to: out,
            budget: budget
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
        try applyRestoreSites(
            Restorer.literalRestoreSites(in: layout.text, plan: plan),
            to: &layout
        )
    }

    /// Restore a token-style mapping across one whole parsed part: the mapped
    /// brace tokens plus any entries carried from another style, decided
    /// together over the part's concatenated text (the string the report
    /// scans) so a carried literal is never written inside a value a token
    /// restores. Exposed at internal access so DocxParts restores the
    /// non-body parts the same way.
    static func restoreTokenStyleInLayout(
        _ layout: inout DocxLayout,
        plan: Restorer.TokenStyleRestorePlan
    ) throws -> LiteralRestoreOutcome {
        try applyRestoreSites(
            Restorer.tokenStyleRestoreSites(in: layout.text, plan: plan),
            to: &layout
        )
    }

    /// Write already decided sites back into the runs they cover. A site
    /// carrying a value is substituted; a refused site (no single entity owns
    /// it) keeps its bytes and is reported. Every mapped site the report
    /// counts must be writable through the run coverage below.
    private static func applyRestoreSites(
        _ sites: [Restorer.LiteralRestoreSite],
        to layout: inout DocxLayout
    ) throws -> LiteralRestoreOutcome {
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
    /// synthetic break that belongs to no run: the paragraph newline, a w:br
    /// or w:cr line break, or a w:tab. A site straddling such a character
    /// cannot be written back faithfully: the value would land in the first
    /// run while the break element stayed behind. Detected spans are split at
    /// breaks before tokenization (see SpanSplitter), so no replacement the
    /// pipeline mints carries one and this guard never fires
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

}
