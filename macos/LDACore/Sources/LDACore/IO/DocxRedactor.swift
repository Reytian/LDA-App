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
        var bySegment: [Int: [RunEdit]] = [:]

        for replacement in replacements {
            let spanStart = replacement.span.start
            let spanEnd = replacement.span.end
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
                let insert = offset == 0 ? replacement.token : ""
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

    /// Replace every literal replacement string in a redacted .docx with its
    /// value and write to out. The literal-style counterpart of restore: used
    /// for pseudonym and asterisk mappings, whose replacements are ordinary
    /// strings rather than grammar tokens.
    ///
    /// The caller passes only the UNAMBIGUOUS replacements (see
    /// Restorer.unambiguousReplacementMap); a colliding asterisk mask stays
    /// verbatim in the document, never guessed. Like the token path this
    /// substitutes run by run, so a replacement split across runs by later
    /// editing does not restore (the whole-text report scan still counts it).
    public static func restoreLiteral(
        redactedDocx: URL,
        replacementToValue: [String: String],
        to out: URL
    ) throws {
        let data = try DocxZip.readEntry(docxMainPartPath, from: redactedDocx)
        var layout = try DocxDocumentXML.parse(data)

        for index in layout.segments.indices {
            guard case .runText(let text) = layout.segments[index] else { continue }
            let replaced = Restorer.substituteLiteralReplacements(
                in: text,
                replacementToValue: replacementToValue
            )
            if replaced != text {
                layout.segments[index] = .runText(replaced)
            }
        }

        var rewriteParts: [String: Data] = [docxMainPartPath: DocxDocumentXML.serialize(layout)]
        // Restore literal replacements in the non-body text parts too.
        let nonBody = DocxParts.restoreNonBodyPartsLiteral(
            url: redactedDocx,
            replacementToValue: replacementToValue
        )
        for (path, bytes) in nonBody {
            rewriteParts[path] = bytes
        }

        try DocxZip.rewrite(
            source: redactedDocx,
            replacing: rewriteParts,
            to: out
        )
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
