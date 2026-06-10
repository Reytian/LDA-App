//
//  LLMExtractor.swift
//  LDACore
//
//  Orchestrates the on-device LLM into fuzzy entity spans (PERSON, COMPANY,
//  ADDRESS) that fill SpanMerger's currently-empty llm input. It chunks the text
//  (Chunker), runs each chunk through the v2 single-shot extraction prompt
//  (PromptStore + a TextCompleter), parses the JSON (EntityJSONParser), keeps
//  only the fuzzy types LDA owns from the LLM, and re-anchors values to spans
//  (EntityLocator).
//
//  The completer is injected via the TextCompleter protocol so this orchestrator
//  is unit-testable without loading the 2.7 GB GGUF model. In production the
//  completer is an LLMEngine.
//
//  Phase 2b scaffold: the interface is frozen here; the orchestration body lands
//  in a later phase.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

// MARK: - ExtractionResult

/// The outcome of an extraction run: the located fuzzy spans plus whether the
/// whole document was fully scanned.
///
/// A segment whose model completion was cut off at the token cap (and could not
/// be recovered by a larger-cap retry or by splitting) is counted as incomplete.
/// When `incompleteSegmentCount > 0` the spans are still the best salvage, but
/// the document MUST NOT be presented as cleanly anonymized: an un-scanned
/// segment may still contain un-redacted PERSON/COMPANY/ADDRESS (LJE-001).
public struct ExtractionResult: Sendable {
    /// The located spans (PERSON, COMPANY, ADDRESS) suitable for SpanMerger.
    public let spans: [Span]
    /// How many segments could not be fully scanned even after retry/splitting.
    public let incompleteSegmentCount: Int

    public init(spans: [Span], incompleteSegmentCount: Int) {
        self.spans = spans
        self.incompleteSegmentCount = incompleteSegmentCount
    }

    /// True when every segment was fully scanned. False means at least one
    /// segment was truncated and the document is not guaranteed PII-free.
    public var fullyCovered: Bool { incompleteSegmentCount == 0 }
}

// MARK: - LLMExtractor

/// Drives the on-device LLM to produce fuzzy spans for SpanMerger's llm input.
public final class LLMExtractor {
    /// The fuzzy types LDA keeps from the LLM. The DeterministicEngine owns the
    /// structured types (EMAIL/PHONE/DATE/AMOUNT/BANK_ACCOUNT/USCC/NATIONAL_ID)
    /// and wins conflicts via SpanMerger priority, so they are dropped here.
    public static let keptTypes: Set<EntityType> = [.person, .company, .address]

    private let completer: TextCompleter
    private let prompts: PromptStore

    /// - Parameters:
    ///   - completer: the text-completion backend (an LLMEngine in production, a
    ///     fake in tests).
    ///   - prompts: the editable prompt store. Defaults to a fresh PromptStore.
    public init(completer: TextCompleter, prompts: PromptStore = PromptStore()) {
        self.completer = completer
        self.prompts = prompts
    }

    /// Extract fuzzy entity spans (PERSON, COMPANY, ADDRESS) from text.
    ///
    /// - Parameter text: the source document text.
    /// - Returns: located spans suitable for SpanMerger's llm input.
    /// - Parameters:
    ///   - text: the source document text.
    ///   - onProgress: optional callback invoked as (segmentsDone, segmentsTotal)
    ///     after each model call, so a UI can show a determinate progress bar and
    ///     estimate the remaining time. Called once with (0, total) up front.
    public func extract(
        from text: String,
        onProgress: ((Int, Int) -> Void)? = nil
    ) throws -> [Span] {
        return try extractDetailed(from: text, onProgress: onProgress).spans
    }

    /// Extract fuzzy entity spans, also reporting whether every segment was fully
    /// scanned.
    ///
    /// Unlike extract(from:), this surfaces truncation: a segment whose completion
    /// was cut off at the token cap is retried once with a larger cap and, if it
    /// still truncates, split into smaller sub-segments. Any complete entity
    /// objects emitted before a cut are always salvaged. A segment that still
    /// cannot be fully scanned is counted in
    /// ExtractionResult.incompleteSegmentCount so the caller does not present the
    /// document as cleanly anonymized when PII may have been left un-scanned
    /// (LJE-001).
    ///
    /// - Parameters:
    ///   - text: the source document text.
    ///   - onProgress: optional callback invoked as (segmentsDone, segmentsTotal).
    public func extractDetailed(
        from text: String,
        onProgress: ((Int, Int) -> Void)? = nil
    ) throws -> ExtractionResult {
        // 1. Split the document into the windows the v2 model was trained to see.
        let chunks = Chunker.chunk(text)

        // 2. Determine the unique paragraph-delimited segments to send to the
        //    model. Consecutive chunks overlap, so the overlap tail of chunk N
        //    re-appears at the head of chunk N+1; deduplicating by content avoids
        //    re-processing it. Sending each paragraph segment independently
        //    ensures a throwing segment never suppresses its neighbors.
        //    Precomputing the full list gives a stable total for progress.
        var segmentsToProcess: [String] = []
        var seenSegments = Set<String>()
        for chunk in chunks {
            for segment in LLMExtractor.paragraphSegments(of: chunk.text) {
                let key = segment.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty, seenSegments.insert(key).inserted else { continue }
                segmentsToProcess.append(segment)
            }
        }

        // 3. Run each segment. A segment that fails to complete or returns
        //    unparseable JSON is skipped, never failing the whole extraction.
        //    EntityLocator always searches the full source text, so entity values
        //    found in any segment are correctly anchored across the whole document.
        //    A truncated segment is retried with a larger cap and, if still cut
        //    off, split into smaller sub-segments; complete entities are always
        //    salvaged and a still-incomplete segment is counted (not silently
        //    dropped).
        let total = segmentsToProcess.count
        onProgress?(0, total)

        var rawEntities: [ExtractedEntity] = []
        var incompleteSegmentCount = 0
        for (index, segment) in segmentsToProcess.enumerated() {
            let outcome = scanSegment(segment)
            rawEntities.append(contentsOf: outcome.entities)
            if outcome.incomplete {
                incompleteSegmentCount += 1
            }
            onProgress?(index + 1, total)
        }

        // 4. Keep only the fuzzy types LDA owns from the LLM, and drop any value
        //    that is a contract role label (a term of art that must never be
        //    redacted).
        let kept = rawEntities.filter { entity in
            guard LLMExtractor.keptTypes.contains(entity.type) else { return false }
            let trimmed = entity.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !RoleLabels.isRoleLabel(trimmed)
        }

        // 5. Canonicalize and dedup by (lowercased value, type) so the same
        //    entity reported in several chunks is located only once. Then anchor
        //    each unique value back to every occurrence in the FULL original
        //    text, deduping identical spans.
        var seenEntities = Set<CanonicalKey>()
        var spans: [Span] = []
        var seenSpans = Set<SpanKey>()

        for entity in kept {
            let key = CanonicalKey(
                value: entity.value.lowercased(),
                type: entity.type
            )
            guard seenEntities.insert(key).inserted else { continue }

            let located = EntityLocator.spans(
                forValue: entity.value,
                type: entity.type,
                in: text
            )
            for span in located {
                let spanKey = SpanKey(start: span.start, end: span.end, type: span.type)
                if seenSpans.insert(spanKey).inserted {
                    spans.append(span)
                }
            }
        }

        return ExtractionResult(spans: spans, incompleteSegmentCount: incompleteSegmentCount)
    }

    // MARK: - Per-segment scanning

    /// The result of scanning one segment: the salvaged entities and whether the
    /// segment could not be fully scanned (still truncated after retry/splitting).
    private struct SegmentOutcome {
        let entities: [ExtractedEntity]
        let incomplete: Bool
    }

    /// Send one segment to the model, salvage entities, and recover from a
    /// truncated completion.
    ///
    /// Strategy: complete at the default cap; if the parse signals truncation,
    /// retry once at a larger cap; if it still truncates, split the segment into
    /// smaller sub-segments and scan each. The entities recovered before any cut
    /// are always kept. The segment is reported incomplete only if a leaf attempt
    /// still truncates with no possibility of finer splitting.
    private func scanSegment(_ segment: String) -> SegmentOutcome {
        // First attempt at the default cap.
        guard let first = complete(segment: segment, maxTokens: LLMExtractor.maxCompletionTokens) else {
            // The completer threw. Skip this segment as before; a backend failure
            // is not a truncation we can recover by retrying with a larger cap.
            return SegmentOutcome(entities: [], incomplete: false)
        }
        let firstParse = EntityJSONParser.parseDetailed(first)
        if !firstParse.truncated {
            return SegmentOutcome(entities: firstParse.entities, incomplete: false)
        }

        // Retry once with a larger cap: the most common cause is simply the output
        // budget, which a bigger cap fixes outright.
        if let retry = complete(segment: segment, maxTokens: LLMExtractor.retryCompletionTokens) {
            let retryParse = EntityJSONParser.parseDetailed(retry)
            if !retryParse.truncated {
                return SegmentOutcome(entities: retryParse.entities, incomplete: false)
            }
        }

        // Still truncating. Split into smaller sub-segments and scan each so the
        // per-call output stays well under the cap. Recurse so a sub-segment can
        // itself retry/split. If the segment cannot be split any further, salvage
        // whatever the larger-cap attempt recovered and mark it incomplete.
        let subSegments = LLMExtractor.splitSegment(segment)
        guard subSegments.count > 1 else {
            return SegmentOutcome(entities: firstParse.entities, incomplete: true)
        }

        var entities: [ExtractedEntity] = []
        var anyIncomplete = false
        for sub in subSegments {
            let outcome = scanSegment(sub)
            entities.append(contentsOf: outcome.entities)
            if outcome.incomplete { anyIncomplete = true }
        }
        return SegmentOutcome(entities: entities, incomplete: anyIncomplete)
    }

    /// Build the prompt for a segment and complete it, returning nil if the
    /// completer throws (a backend failure, not a truncation).
    private func complete(segment: String, maxTokens: Int) -> String? {
        let prompt = LLMEngine.buildChatMLPrompt(
            system: prompts.currentExtractionSystem,
            user: prompts.extractionUser(chunk: segment)
        )
        return try? completer.complete(
            prompt: prompt,
            maxTokens: maxTokens,
            stop: [LLMExtractor.imEndMarker]
        )
    }

    /// Split a segment into smaller pieces for re-scanning when a single call
    /// keeps truncating. Prefers line boundaries (so sentence/clause structure is
    /// preserved); if the segment is a single line, splits it in half on a word
    /// boundary. Returns the original segment as a one-element array when it
    /// cannot be split any finer.
    private static func splitSegment(_ segment: String) -> [String] {
        let lines = segment.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if lines.count > 1 {
            return lines
        }

        // Single line: split on the word boundary nearest the midpoint.
        let words = segment.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count > 1 else { return [segment] }
        let mid = words.count / 2
        let firstHalf = words[0..<mid].joined(separator: " ")
        let secondHalf = words[mid...].joined(separator: " ")
        return [firstHalf, secondHalf].filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: - Constants

    /// Generation cap for one chunk completion. Matches the value the production
    /// pipeline uses for the v2 single-shot extraction format.
    private static let maxCompletionTokens = 1024

    /// Larger generation cap used on a one-shot retry when the first completion
    /// was truncated. A bigger output budget recovers most cut-off completions
    /// outright; only segments that still overflow this are split (LJE-001).
    private static let retryCompletionTokens = 4096

    /// The ChatML end-of-turn marker. Generation stops once the model emits it.
    private static let imEndMarker = "<|im_end|>"

    // MARK: - Paragraph splitting

    /// Splits chunk text at double-newline paragraph breaks and returns each
    /// non-empty segment. A chunk with no paragraph breaks is returned as a
    /// single-element array. This lets the model-call loop treat each paragraph
    /// independently so a throwable paragraph does not suppress its neighbours.
    private static func paragraphSegments(of text: String) -> [String] {
        // Split at two or more consecutive newlines (paragraph break).
        let parts = text.components(separatedBy: "\n\n")
        return parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    // MARK: - Dedup keys

    /// Identity for canonicalizing an extracted entity: its lowercased value and
    /// its type. Two entities with the same key are located only once.
    private struct CanonicalKey: Hashable {
        let value: String
        let type: EntityType
    }

    /// Identity for a located span: its UTF-16 range and type. Two spans with the
    /// same key (the same value found via two different reports) collapse to one.
    private struct SpanKey: Hashable {
        let start: Int
        let end: Int
        let type: EntityType
    }
}
