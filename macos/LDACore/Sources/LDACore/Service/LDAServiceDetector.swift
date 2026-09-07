//
//  LDAServiceDetector.swift
//  LDACore
//
//  The detector every LDAService entry point runs: one LLM engine loaded at
//  most once, a primary text pass that surfaces incomplete scans, and a
//  secondary image-PII pass that stays best-effort.
//
//  The model gate lives here too. A caller who passes a model path is asking
//  for PERSON, COMPANY, and ADDRESS detection. When that model cannot run (the
//  file is missing, or llama.cpp cannot load it), the only honest answer is a
//  refusal before anything is written. The previous behaviour built a
//  pattern-only detector instead, so the compiled CLI accepted a nonexistent
//  --model, exited 0, and wrote "Alice Smith signed for Acme Corporation."
//  with every name still in it and no warning. A nil model path is the
//  deliberate pattern-only path and is never refused.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

extension LDAService {

    /// A detector that loads the LLM engine at most once and offers two entry
    /// points over it: the primary text pass (which surfaces incomplete scans) and
    /// the secondary image-PII pass (which stays non-throwing for the resolver).
    /// Internal (not private) so LDASessionService.swift can reuse it.
    internal struct Detector {
        let extractor: LLMExtractor?

        /// Primary detection over the main document text. Throws when the
        /// result cannot be presented as cleanly anonymized (LJE-001), so a
        /// document that is not guaranteed PII-free is never written out as
        /// clean. Two distinct failures qualify and each gets its own error, so
        /// the caller's message names the one that happened.
        ///
        /// Coverage is checked first: when a segment was never scanned the
        /// unanchored count is drawn from an incomplete sample and reporting it
        /// would be misleading.
        ///
        /// After the merge, the confirmed spans seed the full-document literal
        /// rescan (EntityRescan.expand): repeat mentions of every confirmed
        /// PERSON and COMPANY surface, and of the document's defined short
        /// names bound to them, are swept in with pure string search. This is
        /// engine-level so the CLI, MCP, and app UI all benefit identically.
        func detectText(_ text: String) throws -> [Span] {
            let llm: [Span]
            if let extractor {
                let result = try extractor.extractDetailed(from: text)
                guard result.fullyCovered else {
                    throw LDAServiceError.incompleteExtraction(
                        incompleteSegmentCount: result.incompleteSegmentCount
                    )
                }
                guard result.fullyAnchored else {
                    throw LDAServiceError.unanchoredEntities(
                        unlocatableEntityCount: result.unlocatableEntityCount
                    )
                }
                llm = result.spans
            } else {
                llm = []
            }
            let merged = SpanMerger.merge(deterministic: DeterministicEngine().detect(text), llm: llm)
            return EntityRescan.expand(merged, in: text)
        }

        /// Secondary detection over short OCR'd image-origin text for the image-PII
        /// channel. This re-uses the loaded engine but stays non-throwing: it is a
        /// best-effort supplement to the boxed regions, and the salvage path keeps
        /// any recovered entities. Truncation here does not gate the "clean" claim,
        /// which is owned by the primary text pass above.
        func detectForImages(_ text: String) -> [Span] {
            let llm: [Span]
            if let extractor {
                llm = (try? extractor.extract(from: text)) ?? []
            } else {
                llm = []
            }
            return SpanMerger.merge(deterministic: DeterministicEngine().detect(text), llm: llm)
        }
    }

    /// Build a detector that loads the LLM engine at most once and reuses it for
    /// every call (main text pass and image-PII pass).
    ///
    /// A nil modelPath is the deliberate pattern-only path. A non-nil path is a
    /// request for the model: when the file is missing or llama.cpp cannot load
    /// it, this throws LDAServiceError.modelUnavailable instead of quietly
    /// building a pattern-only detector, because the caller would otherwise get
    /// a document with every name still in it and an exit code that says the
    /// run succeeded. Internal (not private) so LDASessionService.swift can
    /// reuse it.
    internal static func makeDetector(modelPath: String?) throws -> Detector {
#if DEBUG
        // An installed seam stands in for the ENGINE LOAD and nothing else:
        // it wins whether or not the path resolves, which is what lets a test
        // drive the LLM paths with a bogus path, while the refusal policy
        // around it stays production code under test. This whole branch is
        // absent from release builds.
        if let factory = makeExtractorForTesting {
            return Detector(extractor: try seamExtractor(factory, modelPath: modelPath))
        }
#endif
        guard let modelPath else {
            return Detector(extractor: nil)
        }
        return Detector(extractor: try loadExtractor(modelPath: modelPath))
    }

    /// Load the engine at modelPath and wrap it in an extractor, or refuse.
    private static func loadExtractor(modelPath: String) throws -> LLMExtractor {
        do {
            return LLMExtractor(completer: try LLMEngine(config: .init(modelPath: modelPath)))
        } catch {
            throw LDAServiceError.modelUnavailable(
                path: modelPath,
                reason: modelUnavailableReason(for: error)
            )
        }
    }

    /// A short, path-free reason for a model that could not run, so every
    /// intake can show it without echoing the path a second time.
    private static func modelUnavailableReason(for error: Error) -> String {
        switch error {
        case LLMEngine.LLMError.modelFileMissing:
            return "the file does not exist"
        case LLMEngine.LLMError.modelLoadFailed:
            return "the file could not be loaded as a GGUF model"
        case LLMEngine.LLMError.contextCreationFailed:
            return "the model loaded but no inference context could be created"
        default:
            return String(describing: error)
        }
    }

#if DEBUG
    /// The seam replaces only the engine load. Nil from it stands in for a
    /// model that failed to load: with a model path that is the same refusal
    /// production raises, and with no path it is the pattern-only run the
    /// caller asked for.
    private static func seamExtractor(
        _ factory: (String) -> LLMExtractor?,
        modelPath: String?
    ) throws -> LLMExtractor? {
        if let extractor = factory(modelPath ?? "") {
            return extractor
        }
        guard let modelPath else {
            return nil
        }
        throw LDAServiceError.modelUnavailable(
            path: modelPath,
            reason: "the test seam stood in for a model that failed to load"
        )
    }
#endif
}
