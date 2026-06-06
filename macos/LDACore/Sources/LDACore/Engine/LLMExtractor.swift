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
        let total = segmentsToProcess.count
        onProgress?(0, total)

        var rawEntities: [ExtractedEntity] = []
        for (index, segment) in segmentsToProcess.enumerated() {
            let prompt = LLMEngine.buildChatMLPrompt(
                system: prompts.currentExtractionSystem,
                user: prompts.extractionUser(chunk: segment)
            )
            do {
                let completion = try completer.complete(
                    prompt: prompt,
                    maxTokens: LLMExtractor.maxCompletionTokens,
                    stop: [LLMExtractor.imEndMarker]
                )
                rawEntities.append(contentsOf: EntityJSONParser.parse(completion))
            } catch {
                // Skip this segment but keep going with the rest.
            }
            onProgress?(index + 1, total)
        }

        // 3. Keep only the fuzzy types LDA owns from the LLM, and drop any value
        //    that is a contract role label (a term of art that must never be
        //    redacted).
        let kept = rawEntities.filter { entity in
            guard LLMExtractor.keptTypes.contains(entity.type) else { return false }
            let trimmed = entity.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !RoleLabels.isRoleLabel(trimmed)
        }

        // 4. Canonicalize and dedup by (lowercased value, type) so the same
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

        return spans
    }

    // MARK: - Constants

    /// Generation cap for one chunk completion. Matches the value the production
    /// pipeline uses for the v2 single-shot extraction format.
    private static let maxCompletionTokens = 1024

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
