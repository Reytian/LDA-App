//
//  ProfileExtractor.swift
//  LDACore
//
//  Drives the on-device LLM to extract company-profile facts from one or more
//  source documents (certificates of incorporation, articles, business
//  licenses). Each document is chunked with Chunker, each chunk is sent to the
//  model using the PromptStore profile prompts assembled identically to how
//  LLMExtractor assembles its extraction prompts (same ChatML builder, same
//  stop token), and the JSON response is parsed with ProfileJSONParser.
//
//  Retry/split/incomplete strategy mirrors LLMExtractor: a chunk whose
//  response cannot be parsed (nil from parseProfileRowsDetailed) is retried
//  once with doubled maxTokens; if still unparseable the chunk is split at its
//  UTF-16 midpoint (clamped to a grapheme boundary) and each half is attempted
//  once; any half still failing increments incompleteSegmentCount.
//
//  Grounding: each parsed row's snippet is searched case-insensitively in the
//  WHOLE source text (not just the current chunk). Found means snippetVerified
//  = true; not found (or empty snippet) means snippetVerified = false and
//  confidence is capped at ungroundedConfidenceCap (0.4).
//
//  Merge: fields are merged across chunks and sources in first-seen order.
//  Two rows with the same key AND the same normalizedValue collapse to one;
//  when collapsing, the entry with the higher confidence is kept.
//
//  Progress contract: called once with (0, total) before any model call; then
//  after each model call (retries and split sub-calls each count). This mirrors
//  LLMExtractor's per-segment onProgress pattern.
//
//  Completer errors (thrown by complete(prompt:maxTokens:stop:)) propagate to
//  the caller; parse-nil is NOT an error, it is the retry/split path.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

// MARK: - ProfileExtractionResult

/// The outcome of a profile extraction run: the merged fields and a count of
/// how many chunks could not be parsed even after retry/splitting.
public struct ProfileExtractionResult: Sendable {
    /// Extracted and merged profile fields, in first-seen order.
    public let fields: [ProfileField]
    /// How many segments were still unparseable after retry and splitting.
    public let incompleteSegmentCount: Int
}

// MARK: - ProfileExtractor

/// Drives the on-device LLM to extract company-profile facts from source
/// documents and merge them into a flat list of ProfileFields.
public final class ProfileExtractor {

    /// Default generation cap for one chunk completion.
    public static let defaultMaxTokens = 1024

    /// Confidence ceiling applied to any row whose snippet could not be
    /// located verbatim (case-insensitive) in the full source text.
    public static let ungroundedConfidenceCap = 0.4

    private let completer: TextCompleter
    private let prompts: PromptStore

    /// - Parameters:
    ///   - completer: the text-completion backend (an LLMEngine in production,
    ///     a fake in tests).
    ///   - prompts: the editable prompt store. Defaults to a fresh PromptStore.
    public init(completer: TextCompleter, prompts: PromptStore = PromptStore()) {
        self.completer = completer
        self.prompts = prompts
    }

    /// Extract company-profile fields from one or more source documents.
    ///
    /// - Parameters:
    ///   - sources: the source documents as (name, plain text) pairs. The
    ///     name is recorded in ProfileField.sourceDocument.
    ///   - onProgress: optional callback invoked as (segmentsDone,
    ///     segmentsTotal). Called once with (0, total) up front, then after
    ///     each individual model call (retries and split sub-calls each
    ///     increment segmentsDone).
    /// - Returns: merged fields and an incomplete-segment count.
    /// - Throws: any error thrown by the completer.
    public func extract(
        sources: [(name: String, text: String)],
        onProgress: ((Int, Int) -> Void)? = nil
    ) throws -> ProfileExtractionResult {

        // 1. Pre-compute the full flat list of (documentName, sourceText, chunk)
        //    tuples so we have a stable total count before any model calls.
        struct WorkItem {
            let documentName: String
            let sourceText: String
            let chunkText: String
        }
        var work: [WorkItem] = []
        for source in sources {
            let chunks = Chunker.chunk(source.text)
            for chunk in chunks {
                work.append(WorkItem(
                    documentName: source.name,
                    sourceText: source.text,
                    chunkText: chunk.text
                ))
            }
        }

        let total = work.count
        var segmentsDone = 0
        onProgress?(0, total)

        // 2. Process each chunk, accumulating raw parsed rows.
        //    Completer errors propagate immediately.
        var rawRows: [(row: ProfileRow, documentName: String, sourceText: String)] = []
        var incompleteSegmentCount = 0

        for item in work {
            let outcome = try scanChunk(
                item.chunkText,
                documentName: item.documentName,
                sourceText: item.sourceText,
                segmentsDone: &segmentsDone,
                total: total,
                onProgress: onProgress
            )
            rawRows.append(contentsOf: outcome.rows.map { ($0, item.documentName, item.sourceText) })
            if outcome.incomplete {
                incompleteSegmentCount += 1
            }
        }

        // 3. Ground each row, build ProfileFields, and merge.
        var mergedFields: [ProfileField] = []

        for (row, documentName, sourceText) in rawRows {
            let verified = groundSnippet(row.snippet, in: sourceText)
            let effectiveConfidence = verified
                ? row.confidence
                : min(row.confidence, ProfileExtractor.ungroundedConfidenceCap)

            let key = ProfileFieldKey(rawKey: row.key)
            let newField = ProfileField(
                key: key,
                value: row.value,
                sourceDocument: documentName,
                sourceSnippet: row.snippet,
                snippetVerified: verified,
                confidence: effectiveConfidence,
                userEdited: false
            )

            mergeField(newField, into: &mergedFields)
        }

        return ProfileExtractionResult(
            fields: mergedFields,
            incompleteSegmentCount: incompleteSegmentCount
        )
    }

    // MARK: - Per-chunk scanning

    private struct ChunkOutcome {
        let rows: [ProfileRow]
        let incomplete: Bool
    }

    /// Send one chunk to the model and recover from an unparseable response.
    ///
    /// Strategy: complete at defaultMaxTokens; if the parse returns nil, retry
    /// once at doubled maxTokens; if still nil, split the chunk at its UTF-16
    /// midpoint and process each half once; any half still failing increments
    /// incomplete.
    private func scanChunk(
        _ chunkText: String,
        documentName: String,
        sourceText: String,
        segmentsDone: inout Int,
        total: Int,
        onProgress: ((Int, Int) -> Void)?
    ) throws -> ChunkOutcome {

        // First attempt at the default cap.
        let firstCompletion = try completeChunk(chunkText, documentName: documentName, maxTokens: ProfileExtractor.defaultMaxTokens)
        segmentsDone += 1
        onProgress?(segmentsDone, total)

        if let firstRows = ProfileJSONParser.parseProfileRowsDetailed(firstCompletion) {
            return ChunkOutcome(rows: firstRows, incomplete: false)
        }

        // Retry once with doubled maxTokens.
        let retryCompletion = try completeChunk(chunkText, documentName: documentName, maxTokens: ProfileExtractor.defaultMaxTokens * 2)
        segmentsDone += 1
        onProgress?(segmentsDone, total)

        if let retryRows = ProfileJSONParser.parseProfileRowsDetailed(retryCompletion) {
            return ChunkOutcome(rows: retryRows, incomplete: false)
        }

        // Still unparseable: split at UTF-16 midpoint and try each half once.
        let halves = splitAtUTF16Midpoint(chunkText)
        guard halves.count > 1 else {
            // Cannot split further; mark incomplete, return no rows.
            return ChunkOutcome(rows: [], incomplete: true)
        }

        var allRows: [ProfileRow] = []
        var anyIncomplete = false

        for half in halves {
            let halfCompletion = try completeChunk(half, documentName: documentName, maxTokens: ProfileExtractor.defaultMaxTokens)
            segmentsDone += 1
            onProgress?(segmentsDone, total)

            if let halfRows = ProfileJSONParser.parseProfileRowsDetailed(halfCompletion) {
                allRows.append(contentsOf: halfRows)
            } else {
                anyIncomplete = true
            }
        }

        return ChunkOutcome(rows: allRows, incomplete: anyIncomplete)
    }

    /// Build the prompt for one chunk and call the completer. Errors propagate.
    private func completeChunk(
        _ chunkText: String,
        documentName: String,
        maxTokens: Int
    ) throws -> String {
        let prompt = LLMEngine.buildChatMLPrompt(
            system: prompts.currentProfileSystem,
            user: prompts.profileUser(documentName: documentName, chunk: chunkText)
        )
        return try completer.complete(
            prompt: prompt,
            maxTokens: maxTokens,
            stop: [ProfileExtractor.imEndMarker]
        )
    }

    // MARK: - Snippet grounding

    /// Returns true when snippet is non-empty and found case-insensitively in
    /// the full source text.
    private func groundSnippet(_ snippet: String, in sourceText: String) -> Bool {
        guard !snippet.isEmpty else { return false }
        let range = (sourceText as NSString).range(
            of: snippet,
            options: .caseInsensitive
        )
        return range.location != NSNotFound
    }

    // MARK: - Merge

    /// Merge a new ProfileField into the accumulator using first-seen order.
    ///
    /// Rule: when an existing field has the same key AND the same normalizedValue
    /// as the new field, collapse to one entry, keeping whichever has higher
    /// confidence (replacing the stored entry if the new one wins). Otherwise
    /// append (different value for the same key is a legitimate conflict and both
    /// are kept).
    private func mergeField(_ newField: ProfileField, into fields: inout [ProfileField]) {
        for index in fields.indices {
            let existing = fields[index]
            guard existing.key == newField.key,
                  existing.normalizedValue == newField.normalizedValue else {
                continue
            }
            // Same key and same normalized value: keep the higher-confidence one.
            if newField.confidence > existing.confidence {
                fields[index] = newField
            }
            return
        }
        // No duplicate found: append in first-seen order.
        fields.append(newField)
    }

    // MARK: - UTF-16 midpoint split

    /// Split a string into two halves at its UTF-16 midpoint, clamping the cut
    /// to a grapheme cluster boundary. Returns the original as a one-element
    /// array when it is too short to split.
    private func splitAtUTF16Midpoint(_ text: String) -> [String] {
        let utf16 = text.utf16
        guard utf16.count > 1 else { return [text] }

        let midUTF16 = utf16.count / 2
        let midIndex = utf16.index(utf16.startIndex, offsetBy: midUTF16)

        // Advance to the nearest valid String.Index (grapheme boundary).
        guard let validIndex = midIndex.samePosition(in: text) ?? text.index(before: text.endIndex).samePosition(in: text) else {
            return [text]
        }

        let first = String(text[text.startIndex..<validIndex])
        let second = String(text[validIndex...])

        if first.isEmpty || second.isEmpty { return [text] }
        return [first, second]
    }

    // MARK: - Constants

    /// The ChatML end-of-turn marker. Mirrors LLMExtractor.imEndMarker.
    private static let imEndMarker = "<|im_end|>"
}
