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
    public static func redact(
        original: URL,
        replacements: [Replacement],
        to out: URL
    ) throws {
        let data = try DocxZip.readEntry(docxMainPartPath, from: original)
        var layout = try DocxDocumentXML.parse(data)

        // Plan every per-run edit against the ORIGINAL run offsets first, then
        // apply edits one segment at a time from the highest local offset down.
        // Planning against original offsets keeps multi-run spans and multiple
        // distinct spans inside the same run correct, because no edit observes a
        // length already changed by another edit.
        let edits = try planEdits(replacements, runs: layout.runs, segments: layout.segments)

        for (segmentIndex, segmentEdits) in edits {
            try applyEdits(segmentEdits, atSegment: segmentIndex, in: &layout)
        }

        let newXML = DocxDocumentXML.serialize(layout)
        try DocxZip.rewrite(
            source: original,
            replacing: [docxMainPartPath: newXML],
            to: out
        )
    }

    /// A single run-local edit: replace the run-local UTF-16 range
    /// [localStart, localEnd) with insertText.
    private struct RunEdit {
        var localStart: Int
        var localEnd: Int
        var insertText: String
    }

    /// Turn replacements into a map of segment index to the list of run-local
    /// edits for that segment. The FIRST overlapped run of each replacement gets
    /// the token; every other overlapped run has its covered text deleted.
    private static func planEdits(
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
    private static func applyEdits(
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

        let newXML = DocxDocumentXML.serialize(layout)
        try DocxZip.rewrite(
            source: redactedDocx,
            replacing: [docxMainPartPath: newXML],
            to: out
        )
    }

    /// Replace all grammar-matched tokens in a single run's text with their
    /// mapped values. Tokens absent from tokenToValue are left untouched so the
    /// orphan guard downstream can flag them.
    private static func replaceTokens(
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
            // Copy the text between the previous match and this one.
            if range.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            }
            let token = ns.substring(with: range)
            if let value = tokenToValue[token] {
                result += value
            } else {
                result += token
            }
            cursor = range.location + range.length
        }
        if cursor < ns.length {
            result += ns.substring(from: cursor)
        }
        return result
    }
}
