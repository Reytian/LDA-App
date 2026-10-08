//
//  LDAV4Extractor.swift
//  LDACore
//
//  The built-in LDA V4 model as a fuzzy-entity source. LDA V4 is a token
//  tagger (Multilingual-MiniLM-L12-H384, Core ML int8, 29 BIOES labels) that
//  ships inside the app, so detection works from the first launch with no
//  download. The TinyPII target reproduces its training pipeline exactly
//  (tokenizer, 256-token windows, constrained BIOES Viterbi, window merge).
//
//  The tagger's spans become values, and the values go through
//  LLMExtractor.locate: the same kept types, legal boilerplate and defined-term
//  filters, and the same EntityLocator anchoring at every occurrence. That is
//  the configuration LDA V4 was evaluated in ("value mode + rules"), so the
//  app reproduces the measured behaviour rather than a variant of it.
//
//  Labels: PERSON, COMPANY and ADDRESS map to their own types. TRADEMARK and
//  VESSEL are redaction classes LDA has no placeholder type for yet, so they
//  are replaced as COMPANY. KEEP_ORG (courts, agencies) and KEEP_PLACE
//  (jurisdictions) are never redacted.
//
//  The model directory holds runtime.json, the tokenizer assets and the
//  compiled model (LDA-V4.mlmodelc). One Tagger per directory is loaded per
//  process and reused; predictions are serialized because one Core ML model
//  instance serves them all.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import CoreML
import Foundation
import TinyPII

public final class LDAV4Extractor: EntityExtracting {
    /// The display name of the built-in model.
    public static let displayName = "LDA V4"
    /// The folder the packaged app carries the model in (Contents/Resources).
    public static let bundleFolderName = "LDA-V4"
    /// The compiled Core ML model inside that folder.
    public static let compiledModelName = "LDA-V4.mlmodelc"
    /// Runtime settings exported with the model (labels, window, tokenizer).
    public static let runtimeFileName = "runtime.json"

    public enum LoadError: Error, Equatable {
        /// The folder lacks runtime.json, the tokenizer or the compiled model.
        case incompleteModelDirectory(String)
    }

    private let tagger: Tagger
    private let cancelToken: ExtractionCancelToken?

    /// - Parameters:
    ///   - modelDirectory: a folder laid out as described above.
    ///   - cancelToken: optional stop flag, checked before and after the pass.
    public init(modelDirectory: URL, cancelToken: ExtractionCancelToken? = nil) throws {
        guard Self.isModelDirectory(modelDirectory.path) else {
            throw LoadError.incompleteModelDirectory(modelDirectory.lastPathComponent)
        }
        tagger = try Self.sharedTagger(for: modelDirectory)
        self.cancelToken = cancelToken
    }

    /// True when path is a folder with everything the tagger loads.
    public static func isModelDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let required = [
            runtimeFileName,
            compiledModelName,
            "tokenizer/vocab.json",
            "tokenizer/charsmap.bin",
            "tokenizer/tables.json",
        ]
        return required.allSatisfy {
            FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
        }
    }

    /// The LDA type a tagger label is replaced as, or nil for a keep label.
    public static func entityType(forTaggerLabel label: String) -> EntityType? {
        switch label {
        case "PERSON":
            return .person
        case "COMPANY", "TRADEMARK", "VESSEL":
            return .company
        case "ADDRESS":
            return .address
        default:
            return nil
        }
    }

    public func extract(from text: String, onProgress: ((Int, Int) -> Void)?) throws -> [Span] {
        try extractDetailed(from: text, onProgress: onProgress).spans
    }

    public func extractDetailed(from text: String, onProgress: ((Int, Int) -> Void)?) throws -> ExtractionResult {
        onProgress?(0, 1)
        try throwIfCancelled()
        let predicted = try Self.predict(text, with: tagger)
        try throwIfCancelled()
        let ns = text as NSString
        var entities: [ExtractedEntity] = []
        for item in predicted {
            guard let type = Self.entityType(forTaggerLabel: item.span.label),
                  item.end16 > item.start16 else { continue }
            let value = ns.substring(with: NSRange(location: item.start16, length: item.end16 - item.start16))
            entities.append(ExtractedEntity(value: value, type: type))
        }
        onProgress?(1, 1)
        // The tagger reads every window of the document, so nothing is left
        // unscanned; anchoring figures come from the shared locator.
        return LLMExtractor.locate(entities, in: text, incompleteSegmentCount: 0)
    }

    private func throwIfCancelled() throws {
        if let cancelToken, cancelToken.isCancelled {
            throw ExtractionCancelled()
        }
    }

    // MARK: - Shared model instances

    private static let cacheLock = NSLock()
    private static var cache: [String: Tagger] = [:]
    private static let predictLock = NSLock()

    private static func sharedTagger(for directory: URL) throws -> Tagger {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let key = directory.standardizedFileURL.path
        if let loaded = cache[key] {
            return loaded
        }
        // CPU only: this is the configuration in which the Swift runtime
        // matches the reference pipeline bit for bit, and it loads in about
        // half a second, where the Neural Engine first compiles for seconds.
        let loaded = try Tagger(
            assets: directory,
            model: directory.appendingPathComponent(compiledModelName),
            computeUnits: .cpuOnly
        )
        cache[key] = loaded
        return loaded
    }

    private static func predict(_ text: String, with tagger: Tagger) throws -> [DocumentSpan] {
        predictLock.lock()
        defer { predictLock.unlock() }
        return try tagger.predict(text)
    }
}
