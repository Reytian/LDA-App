//
//  EntityExtracting.swift
//  LDACore
//
//  The common face of the two fuzzy-entity sources that fill SpanMerger's llm
//  input: the on-device LLM (LLMExtractor, a downloadable GGUF tier) and the
//  built-in LDA V4 tagger (LDAV4Extractor, bundled with the app). Both report
//  values that pass the same filters and anchor through the same locator
//  (LLMExtractor.locate), so every caller treats them identically.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// A source of located fuzzy spans (PERSON, COMPANY, ADDRESS, NATIONAL_ID).
public protocol EntityExtracting: AnyObject {
    /// Located spans only; see extractDetailed.
    func extract(from text: String, onProgress: ((Int, Int) -> Void)?) throws -> [Span]

    /// Located spans plus the coverage figures the callers gate on.
    func extractDetailed(from text: String, onProgress: ((Int, Int) -> Void)?) throws -> ExtractionResult
}

extension LLMExtractor: EntityExtracting {}

/// Builds the extractor a model path asks for. A directory that holds the
/// LDA V4 tagger gets the tagger; anything else is loaded as a GGUF for the
/// LLM. Throwing is the caller's signal that the requested model cannot run;
/// callers turn it into their own refusal (LDAServiceError.modelUnavailable,
/// or the review's failure text).
public enum EntityExtractorFactory {
    public static func make(
        modelPath: String,
        cancelToken: ExtractionCancelToken? = nil
    ) throws -> EntityExtracting {
        if LDAV4Extractor.isModelDirectory(modelPath) {
            return try LDAV4Extractor(
                modelDirectory: URL(fileURLWithPath: modelPath, isDirectory: true),
                cancelToken: cancelToken
            )
        }
        return LLMExtractor(
            completer: try LLMEngine(config: .init(modelPath: modelPath)),
            cancelToken: cancelToken
        )
    }
}
