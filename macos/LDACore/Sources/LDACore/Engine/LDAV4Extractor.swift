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
//  Labels: PERSON, COMPANY, ADDRESS and TRADEMARK map to their own types.
//  VESSEL is a redaction class LDA has no placeholder type for yet, so it is
//  replaced as COMPANY. KEEP_ORG (courts, agencies) and KEEP_PLACE
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

    /// The model folder inside the running LDA.app, or nil outside the app.
    /// Found from the app itself (Contents/Resources) or from a helper tool
    /// in it (Contents/Helpers/lda, through any symlink), so the app and its
    /// command-line tool resolve the same folder.
    public static func bundledModelPath(bundle: Bundle = .main) -> String? {
        var candidates: [URL] = []
        if let resources = bundle.resourceURL {
            candidates.append(resources.appendingPathComponent(bundleFolderName))
        }
        if let executable = bundle.executableURL?.resolvingSymlinksInPath() {
            candidates.append(
                executable
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("Resources")
                    .appendingPathComponent(bundleFolderName)
            )
        }
        return candidates.map { $0.path }.first { isModelDirectory($0) }
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
        case "COMPANY", "VESSEL":
            return .company
        case "TRADEMARK":
            return .trademark
        case "ADDRESS":
            return .address
        default:
            return nil
        }
    }

    /// Spans the tagger reports end to end, with no character between them,
    /// joined into one when they are the same type, or a company and a brand.
    /// The decoder sometimes ends a name early and starts a second span on its
    /// tail ("金莎TRESOR DORE" then "巧克力", or the brand "费列罗" then
    /// "巧克力" as a company). Value mode then anchors that tail at every
    /// occurrence, so a generic word was redacted throughout the document as a
    /// company of its own. A joined company and brand take the later span's
    /// type: a Chinese name ends in its head (费列罗巧克力 is a chocolate,
    /// 星巴克公司 a company).
    static func joiningTouchingSpans(
        _ ranges: [(start: Int, end: Int, type: EntityType)]
    ) -> [(start: Int, end: Int, type: EntityType)] {
        let names: Set<EntityType> = [.company, .trademark]
        var joined: [(start: Int, end: Int, type: EntityType)] = []
        for range in ranges.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
            if let last = joined.last, last.end == range.start,
               last.type == range.type || (names.contains(last.type) && names.contains(range.type)) {
                joined[joined.count - 1].end = range.end
                joined[joined.count - 1].type = range.type
            } else {
                joined.append(range)
            }
        }
        return joined
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
        var ranges: [(start: Int, end: Int, type: EntityType)] = []
        for item in predicted {
            guard let type = Self.entityType(forTaggerLabel: item.span.label),
                  item.end16 > item.start16 else { continue }
            ranges.append((item.start16, item.end16, type))
        }
        let reported = Self.joiningTouchingSpans(ranges).map { range in
            (range: range, value: ns.substring(with: NSRange(location: range.start, length: range.end - range.start)))
        }
        let heads = NameHeads.heads(in: reported.map { (value: $0.value, type: $0.range.type) })
        let entities = reported
            .filter { !heads.contains($0.value) || !NameHeads.nameTypes.contains($0.range.type) }
            .map { ExtractedEntity(value: $0.value, type: $0.range.type) }
        onProgress?(1, 1)
        // The tagger reads every window of the document, so nothing is left
        // unscanned; anchoring figures come from the shared locator.
        let located = LLMExtractor.locate(entities, in: text, incompleteSegmentCount: 0)
        // A head (NameHeads) stays redacted where the model reported it, and
        // only there.
        let headSpans = reported.compactMap { item -> Span? in
            guard heads.contains(item.value), NameHeads.nameTypes.contains(item.range.type),
                  !LegalBoilerplate.shouldDrop(item.value, type: item.range.type) else { return nil }
            return Span(
                start: item.range.start, end: item.range.end, type: item.range.type, text: item.value,
                source: .llm, confidence: 0.7, priority: EntityLocator.llmPriority
            )
        }
        guard !headSpans.isEmpty else { return located }
        return ExtractionResult(
            spans: located.spans + headSpans,
            incompleteSegmentCount: located.incompleteSegmentCount,
            unlocatedEntities: located.unlocatedEntities,
            phantomEntityCount: located.phantomEntityCount,
            segmentCount: located.segmentCount,
            unansweredSegmentCount: located.unansweredSegmentCount
        )
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
