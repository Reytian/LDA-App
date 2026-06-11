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
//  once per original chunk after scanChunk returns. Retries and split sub-calls
//  are internal work and do not fire onProgress. Mirrors LLMExtractor exactly.
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

    /// Memberwise initializer. Mirrors ExtractionResult so LDAUI (and test
    /// fakes/previews) can construct values directly without going through the
    /// full extraction pipeline.
    public init(fields: [ProfileField], incompleteSegmentCount: Int) {
        self.fields = fields
        self.incompleteSegmentCount = incompleteSegmentCount
    }
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

    /// Extract profile fields from one or more source documents.
    ///
    /// - Parameters:
    ///   - sources: the source documents as (name, plain text) pairs. The
    ///     name is recorded in ProfileField.sourceDocument.
    ///   - kind: the portfolio kind that determines which keys the model is
    ///     instructed to look for. Defaults to .company for backward compatibility
    ///     with older callers (ProfileExtractorTests and internal integration tests)
    ///     that predate kind-aware extraction.
    ///   - onProgress: optional callback invoked as (segmentsDone,
    ///     segmentsTotal). Called once with (0, total) before any model call;
    ///     then once after each original chunk completes (retries and split
    ///     sub-calls are internal work and do not fire the callback). Mirrors
    ///     LLMExtractor exactly.
    /// - Returns: merged fields and an incomplete-segment count.
    /// - Throws: any error thrown by the completer.
    public func extract(
        sources: [(name: String, text: String)],
        kind: PortfolioKind = .company,
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
        onProgress?(0, total)

        // Render the kind-specific system prompt once for the whole run.
        let systemPrompt = prompts.profileSystem(for: kind)

        // 2. Process each chunk, accumulating raw parsed rows.
        //    Completer errors propagate immediately.
        //    onProgress fires exactly once per original chunk after scanChunk
        //    returns, mirroring LLMExtractor's outer-loop pattern.
        var rawRows: [(row: ProfileRow, documentName: String, sourceText: String)] = []
        var incompleteSegmentCount = 0

        for (index, item) in work.enumerated() {
            let outcome = try scanChunk(
                item.chunkText,
                documentName: item.documentName,
                sourceText: item.sourceText,
                systemPrompt: systemPrompt
            )
            rawRows.append(contentsOf: outcome.rows.map { ($0, item.documentName, item.sourceText) })
            if outcome.incomplete {
                incompleteSegmentCount += 1
            }
            onProgress?(index + 1, total)
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
    /// midpoint and process each half once; any half still failing marks the
    /// chunk incomplete. Progress is NOT reported here; the caller fires
    /// onProgress once after this method returns.
    private func scanChunk(
        _ chunkText: String,
        documentName: String,
        sourceText: String,
        systemPrompt: String
    ) throws -> ChunkOutcome {

        // First attempt at the default cap.
        let firstCompletion = try completeChunk(
            chunkText,
            documentName: documentName,
            maxTokens: ProfileExtractor.defaultMaxTokens,
            systemPrompt: systemPrompt
        )

        if let firstRows = ProfileJSONParser.parseProfileRowsDetailed(firstCompletion) {
            return ChunkOutcome(rows: firstRows, incomplete: false)
        }

        // Retry once with doubled maxTokens.
        let retryCompletion = try completeChunk(
            chunkText,
            documentName: documentName,
            maxTokens: ProfileExtractor.defaultMaxTokens * 2,
            systemPrompt: systemPrompt
        )

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
            let halfCompletion = try completeChunk(
                half,
                documentName: documentName,
                maxTokens: ProfileExtractor.defaultMaxTokens,
                systemPrompt: systemPrompt
            )

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
        maxTokens: Int,
        systemPrompt: String
    ) throws -> String {
        let prompt = LLMEngine.buildChatMLPrompt(
            system: systemPrompt,
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
    /// as the new field, collapse to one entry. The winner is selected by:
    ///   1. Prefer snippetVerified == true over unverified. A verified row at 0.35
    ///      beats an unverified row capped at 0.4 because the snippet grounds the
    ///      claim in the source text, which is stronger provenance than a bare
    ///      confidence number. This is a deliberate, documented deviation from the
    ///      plan's bare "higher confidence" rule.
    ///   2. If both have the same verified status, prefer higher confidence.
    ///
    /// When replacing: the WINNER adopts the LOSER's id so that any downstream
    /// reference held by incremental-merge callers (e.g. Blank.proposedFieldID)
    /// continues to resolve to the same field and does not dangle.
    ///
    /// Otherwise append (different value for the same key is a legitimate conflict
    /// and both are kept).
    /// Exposed as internal for direct unit testing of stable-id and verified-first
    /// tie-break behavior without requiring a full LLM pipeline.
    func mergeField(_ newField: ProfileField, into fields: inout [ProfileField]) {
        for index in fields.indices {
            let existing = fields[index]
            guard existing.key == newField.key,
                  existing.normalizedValue == newField.normalizedValue else {
                continue
            }
            // Same key and same normalized value: pick the better-provenance row.
            // verified > unverified; within the same verified status, higher confidence wins.
            let newWins: Bool
            if newField.snippetVerified != existing.snippetVerified {
                newWins = newField.snippetVerified
            } else {
                newWins = newField.confidence > existing.confidence
            }
            if newWins {
                // Adopt the existing field's id so no external reference dangles.
                let replacement = ProfileField(
                    id: existing.id,
                    key: newField.key,
                    value: newField.value,
                    sourceDocument: newField.sourceDocument,
                    sourceSnippet: newField.sourceSnippet,
                    snippetVerified: newField.snippetVerified,
                    confidence: newField.confidence,
                    userEdited: newField.userEdited
                )
                fields[index] = replacement
            }
            return
        }
        // No duplicate found: append in first-seen order.
        fields.append(newField)
    }

    // MARK: - UTF-16 midpoint split

    /// Split a string into two halves at its UTF-16 midpoint, clamping the cut
    /// AT OR BEFORE the midpoint to a grapheme cluster boundary. Uses the same
    /// NSString.rangeOfComposedCharacterSequence(at:).location idiom as Chunker
    /// to avoid the last-character fallback, which degenerates the first half
    /// to nearly the whole input when the midpoint lands in the middle of a
    /// multi-unit sequence. Returns the original as a one-element array when
    /// the string is one UTF-16 unit long or is a single grapheme cluster.
    private func splitAtUTF16Midpoint(_ text: String) -> [String] {
        let ns = text as NSString
        let total = ns.length
        guard total > 1 else { return [text] }

        let midUTF16 = total / 2

        // Clamp to the grapheme boundary AT OR BEFORE the midpoint: the
        // composed-sequence range that contains midUTF16 always starts at or
        // before midUTF16, so .location is the correct cut.
        let cutUTF16 = ns.rangeOfComposedCharacterSequence(at: midUTF16).location

        // If the clamp pushed the cut all the way to the start the string is a
        // single grapheme cluster that cannot be split further.
        guard cutUTF16 > 0 && cutUTF16 < total else { return [text] }

        let first  = ns.substring(with: NSRange(location: 0,        length: cutUTF16))
        let second = ns.substring(with: NSRange(location: cutUTF16, length: total - cutUTF16))

        if first.isEmpty || second.isEmpty { return [text] }
        return [first, second]
    }

    // MARK: - Constants

    /// The ChatML end-of-turn marker. Mirrors LLMExtractor.imEndMarker.
    private static let imEndMarker = "<|im_end|>"
}
