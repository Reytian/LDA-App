//
//  LLMExtractor.swift
//  LDACore
//
//  Orchestrates the on-device LLM into fuzzy entity spans (PERSON, COMPANY,
//  ADDRESS) that fill SpanMerger's llm input. It splits the text into
//  word-aligned extraction windows (SegmentPacker), runs each window through
//  the v2 single-shot extraction prompt (PromptStore + a TextCompleter), parses
//  the JSON (EntityJSONParser), keeps only the fuzzy types LDA owns from the
//  LLM minus legal boilerplate (LegalBoilerplate), and re-anchors values to
//  word-boundary-valid spans (EntityLocator).
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
    /// How many distinct reported values are present in the source but could not
    /// be anchored there, even after repairing CJK script-boundary space drift.
    /// This is the leak: the text really does contain the value, in a surface
    /// form the literal locator cannot match, so it is detected and survives
    /// into the output. A non-zero count means the document is not guaranteed
    /// PII-free.
    public let unlocatableEntityCount: Int
    /// How many distinct reported values do not occur in the source at all, in
    /// any surface form. The model invented them. There is nothing in the
    /// document to redact, so this is a quality signal, NOT a safety one, and it
    /// deliberately does not gate: blocking output over a value the document
    /// does not contain would refuse clean work for no privacy benefit.
    public let phantomEntityCount: Int

    public init(
        spans: [Span],
        incompleteSegmentCount: Int,
        unlocatableEntityCount: Int = 0,
        phantomEntityCount: Int = 0
    ) {
        self.spans = spans
        self.incompleteSegmentCount = incompleteSegmentCount
        self.unlocatableEntityCount = unlocatableEntityCount
        self.phantomEntityCount = phantomEntityCount
    }

    /// True when every segment was fully scanned. False means at least one
    /// segment was truncated and the document is not guaranteed PII-free.
    public var fullyCovered: Bool { incompleteSegmentCount == 0 }

    /// True when no value that the source actually contains was left unanchored.
    /// False means at least one value really in the document cannot be redacted,
    /// so the document is not guaranteed PII-free even though it was fully
    /// scanned. Invented values are excluded on purpose; see phantomEntityCount.
    public var fullyAnchored: Bool { unlocatableEntityCount == 0 }

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
    private let cancelToken: ExtractionCancelToken?

    /// - Parameters:
    ///   - completer: the text-completion backend (an LLMEngine in production, a
    ///     fake in tests).
    ///   - prompts: the editable prompt store. Defaults to a fresh PromptStore.
    ///   - cancelToken: optional stop flag. Checked between windows here and
    ///     once per generated token inside a CancelAwareCompleter, so a user's
    ///     stop lands within a fraction of a second. When it fires,
    ///     extractDetailed throws ExtractionCancelled.
    public init(
        completer: TextCompleter,
        prompts: PromptStore = PromptStore(),
        cancelToken: ExtractionCancelToken? = nil
    ) {
        self.completer = completer
        self.prompts = prompts
        self.cancelToken = cancelToken
        if let cancellable = completer as? CancelAwareCompleter {
            cancellable.cancelToken = cancelToken
        }
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
        // 1. Split the document into extraction windows. SegmentPacker emits
        //    word-aligned, structure-aware windows near the size the v2 model
        //    was trained to see: one window equals one model call. This replaced
        //    the old Chunker + per-paragraph re-split, which made almost twice
        //    as many calls, re-scanned the overlap text, and started segments
        //    mid-word so the model echoed clipped fragments ("laint") as
        //    entity values.
        //    Precomputing the full list gives a stable total for progress.
        var segmentsToProcess: [String] = []
        var seenSegments = Set<String>()
        for window in SegmentPacker.segments(of: text) {
            let key = window.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, seenSegments.insert(key).inserted else { continue }
            segmentsToProcess.append(window.text)
        }

        // 2. Run the segments. When the completer supports batched decoding
        //    (the production LLMEngine), ALL windows' first attempts stream
        //    through the engine's parallel slots in ONE call: the shared
        //    prompt prefix is prefilled once, and a finished window's slot is
        //    immediately refilled with the next one (continuous batching).
        //    A segment that fails to complete or returns unparseable JSON is
        //    skipped, never failing the whole extraction. EntityLocator always
        //    searches the full source text, so entity values found in any
        //    segment are correctly anchored across the whole document. A
        //    truncated segment is retried with a larger cap and, if still cut
        //    off, split into smaller sub-segments; complete entities are
        //    always salvaged and a still-incomplete segment is counted (not
        //    silently dropped). A cancellation throws ExtractionCancelled
        //    (and the engine aborts mid-generation), so a stop is
        //    near-immediate.
        let total = segmentsToProcess.count
        onProgress?(0, total)

        let outcomes = try scanAll(segmentsToProcess, onProgress: onProgress)

        var rawEntities: [ExtractedEntity] = []
        var incompleteSegmentCount = 0
        for outcome in outcomes {
            rawEntities.append(contentsOf: outcome.entities)
            if outcome.incomplete {
                incompleteSegmentCount += 1
            }
        }
        // A stop during the final window must also abort: a cancelled run
        // never returns results, however far it got.
        try throwIfCancelled()

        // 3. Keep only the fuzzy types LDA owns from the LLM, and drop legal
        //    boilerplate the model over-reports: role labels, defined terms
        //    ("Company", "Agreement"), titles ("CEO"), statutes, tribunals, and
        //    governing-law geography. LegalBoilerplate includes the RoleLabels
        //    check. On top of the static lists, the document's OWN quoted
        //    defined terms ("Electronic Media Systems" and the like) are
        //    scanned once and dropped; DefinedTermScanner keeps real-name
        //    aliases redactable.
        let documentTerms = DefinedTermScanner.droppableTerms(in: text)
        let kept = rawEntities.filter { entity in
            guard LLMExtractor.keptTypes.contains(entity.type) else { return false }
            if LegalBoilerplate.shouldDrop(entity.value, type: entity.type) {
                return false
            }
            return !DefinedTermScanner.covers(entity.value, terms: documentTerms)
        }

        // 4. Canonicalize and dedup by (lowercased value, type) so the same
        //    entity reported in several chunks is located only once. Then anchor
        //    each unique value back to every occurrence in the FULL original
        //    text, deduping identical spans.
        var seenEntities = Set<CanonicalKey>()
        var spans: [Span] = []
        var seenSpans = Set<SpanKey>()
        var unlocatableEntityCount = 0
        var phantomEntityCount = 0
        // Whitespace-stripped, lowercased copy of the document, built at most
        // once and only if some value fails to anchor. Used purely to classify a
        // failure; no span is ever derived from it, so it cannot cause a wrong
        // redaction.
        var foldedText: String?

        for entity in kept {
            let key = CanonicalKey(
                value: entity.value.lowercased(),
                type: entity.type
            )
            guard seenEntities.insert(key).inserted else { continue }

            // Anchor the value as reported. If that fails and the value carries
            // CJK script-boundary space drift, retry once with the tightened
            // form. The fallback ordering matters: a source that genuinely
            // spaces its digits still matches on the first, faithful attempt.
            var located = EntityLocator.spans(
                forValue: entity.value,
                type: entity.type,
                in: text
            )
            if located.isEmpty {
                let tightened = CJKSpacing.tightenScriptBoundaries(entity.value)
                if tightened != entity.value {
                    located = EntityLocator.spans(
                        forValue: tightened,
                        type: entity.type,
                        in: text
                    )
                }
            }
            if located.isEmpty {
                // Two very different failures look identical here, and only one
                // is a privacy problem. If the document really does contain this
                // value in some other surface form, it will survive into the
                // output: that is a leak. If the value appears nowhere at all,
                // the model invented it and there is nothing to redact.
                let folded: String
                if let cached = foldedText {
                    folded = cached
                } else {
                    folded = text.lowercased().filter { !$0.isWhitespace }
                    foldedText = folded
                }
                let foldedValue = entity.value.lowercased().filter { !$0.isWhitespace }
                if !foldedValue.isEmpty, folded.contains(foldedValue) {
                    unlocatableEntityCount += 1
                } else {
                    phantomEntityCount += 1
                }
            }
            for span in located {
                let spanKey = SpanKey(start: span.start, end: span.end, type: span.type)
                if seenSpans.insert(spanKey).inserted {
                    spans.append(span)
                }
            }
        }

        return ExtractionResult(
            spans: spans,
            incompleteSegmentCount: incompleteSegmentCount,
            unlocatableEntityCount: unlocatableEntityCount,
            phantomEntityCount: phantomEntityCount
        )
    }

    // MARK: - Per-segment scanning

    /// The result of scanning one segment: the salvaged entities and whether the
    /// segment could not be fully scanned (still truncated after retry/splitting).
    private struct SegmentOutcome {
        let entities: [ExtractedEntity]
        let incomplete: Bool
    }

    /// Throws ExtractionCancelled once the owner's stop flag fires.
    private func throwIfCancelled() throws {
        if cancelToken?.isCancelled == true {
            throw ExtractionCancelled()
        }
    }

    /// Scan every segment. When the completer supports batched decoding and
    /// there is more than one segment, the first attempts for ALL segments
    /// stream through the engine's slots in one continuous-batching call
    /// (progress ticks as each finishes); each segment's truncation recovery
    /// (bigger-cap retry, splitting) then proceeds individually and only
    /// where needed. A batch backend failure falls back to the per-segment
    /// path, so batching is purely an optimization.
    private func scanAll(
        _ segments: [String],
        onProgress: ((Int, Int) -> Void)?
    ) throws -> [SegmentOutcome] {
        var firstAttempts: [String?] = Array(repeating: nil, count: segments.count)
        var batchedProgress = false

        if segments.count > 1, let batcher = completer as? BatchTextCompleter {
            let prompts = segments.map { buildPrompt(for: $0) }
            var finished = 0
            let total = segments.count
            if let outputs = try? batcher.completeBatch(
                prompts: prompts,
                maxTokens: LLMExtractor.maxCompletionTokens,
                stop: [LLMExtractor.imEndMarker],
                onSequenceDone: { _ in
                    finished += 1
                    onProgress?(min(finished, total), total)
                }
            ), outputs.count == segments.count {
                firstAttempts = outputs
                batchedProgress = true
            }
            // A cancellation inside the batch surfaces as a thrown error that
            // the optional-try above swallows; re-check the flag so a stop is
            // honored rather than silently retried per segment.
            try throwIfCancelled()
        }

        var outcomes: [SegmentOutcome] = []
        for (index, segment) in segments.enumerated() {
            try throwIfCancelled()
            outcomes.append(scanSegment(segment, firstAttempt: firstAttempts[index]))
            if !batchedProgress {
                onProgress?(index + 1, segments.count)
            }
        }
        return outcomes
    }

    /// Send one segment to the model, salvage entities, and recover from a
    /// truncated completion.
    ///
    /// Strategy: complete at the default cap (or consume the batched first
    /// attempt when the group pass already produced one); if the parse signals
    /// truncation, retry once at a larger cap; if it still truncates, split
    /// the segment into smaller sub-segments and scan each. The entities
    /// recovered before any cut are always kept. The segment is reported
    /// incomplete only if a leaf attempt still truncates with no possibility
    /// of finer splitting.
    private func scanSegment(_ segment: String, firstAttempt: String? = nil) -> SegmentOutcome {
        // First attempt at the default cap, unless the batched group pass
        // already produced it.
        let firstCompletion = firstAttempt
            ?? complete(segment: segment, maxTokens: LLMExtractor.maxCompletionTokens)
        guard let first = firstCompletion else {
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

    /// Render the full ChatML prompt for one segment.
    private func buildPrompt(for segment: String) -> String {
        return LLMEngine.buildChatMLPrompt(
            system: prompts.currentExtractionSystem,
            user: prompts.extractionUser(chunk: segment)
        )
    }

    /// Build the prompt for a segment and complete it, returning nil if the
    /// completer throws (a backend failure, not a truncation).
    private func complete(segment: String, maxTokens: Int) -> String? {
        return try? completer.complete(
            prompt: buildPrompt(for: segment),
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
