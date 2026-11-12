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
//  the configuration LDA V4 was evaluated in ("value mode + rules"). Since the
//  2026-11-11 review (F2) the filters decide only whether a value is spread:
//  every span the tagger reported is also redacted where it was reported, so
//  a name the filters take for boilerplate is no longer deleted outright.
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
        onProgress?(1, 1)
        return Self.result(
            forTaggerSpans: predicted.map { (start: $0.start16, end: $0.end16, label: $0.span.label) },
            in: text
        )
    }

    /// What the tagger's spans (UTF-16 ranges and labels) become in `text`.
    /// Separate from the model so it can be tested without Core ML.
    static func result(
        forTaggerSpans predicted: [(start: Int, end: Int, label: String)],
        in text: String
    ) -> ExtractionResult {
        let ns = text as NSString
        var ranges: [(start: Int, end: Int, type: EntityType)] = []
        for item in predicted {
            guard let type = entityType(forTaggerLabel: item.label), item.end > item.start else { continue }
            let snapped = snappedToWords(item.start, item.end, in: ns)
            ranges.append((snapped.lowerBound, snapped.upperBound, type))
        }
        let reported = joiningTouchingSpans(ranges).map { range in
            (range: range, value: ns.substring(with: NSRange(location: range.start, length: range.end - range.start)))
        }
        let heads = NameHeads.heads(in: reported.map { (value: $0.value, type: $0.range.type) })
        let entities = reported
            .filter { !heads.contains($0.value) || !NameHeads.nameTypes.contains($0.range.type) }
            .map { ExtractedEntity(value: $0.value, type: $0.range.type) }
        // The tagger reads every window of the document, so nothing is left
        // unscanned; anchoring figures come from the shared locator, which
        // spreads each value to its other occurrences when the filters allow.
        let located = LLMExtractor.locate(entities, in: text, incompleteSegmentCount: 0)
        // Every span the tagger reported is redacted where it was reported
        // (review 2026-11-11, F2). The filters in locate were written for an
        // LLM that reports values with no position, so a value they drop
        // ("Hartwell Law" reads as a statute, "sam okafor" has no capital
        // letter) was deleted even where the tagger had located it exactly.
        // They now decide only whether a value is spread. A head (NameHeads)
        // is one such value: redacted where reported, never spread.
        let pinned = reported.compactMap { item -> Span? in
            guard let range = pinnableRange(item.range.start, item.range.end, in: ns),
                  !located.spans.contains(where: { $0.start <= range.lowerBound && $0.end >= range.upperBound }) else {
                return nil
            }
            return Span(
                start: range.lowerBound, end: range.upperBound, type: item.range.type,
                text: ns.substring(with: NSRange(location: range.lowerBound, length: range.count)),
                source: .llm, confidence: 0.7, priority: EntityLocator.llmPriority
            )
        }
        // A value glued to the word before or after it where the tagger
        // reported it, while it also stands on its own elsewhere: the locator
        // anchors the other mentions and takes "Okafor|and" or "BY|MAREK" for
        // an ordinary word, so this place was left in clear with nothing
        // refused (second independent review of T1). It is a run-in: its
        // value is unlocated, so the document is refused by default, and the
        // place is reported for --auto-protect and a batch to redact.
        let glued = reported.filter { item in
            isGluedPlace(item.range.start, item.range.end, in: ns)
                && !located.spans.contains { $0.start <= item.range.start && $0.end >= item.range.end }
        }
        guard !pinned.isEmpty || !glued.isEmpty else { return located }
        var unlocated = located.unlocatedEntities
        for item in glued {
            let entity = ExtractedEntity(value: item.value, type: item.range.type)
            if !unlocated.contains(entity) { unlocated.append(entity) }
        }
        return ExtractionResult(
            spans: located.spans + pinned,
            incompleteSegmentCount: located.incompleteSegmentCount,
            unlocatedEntities: unlocated,
            phantomEntityCount: located.phantomEntityCount,
            segmentCount: located.segmentCount,
            unansweredSegmentCount: located.unansweredSegmentCount,
            reportedRunIns: glued.map { item in
                Span(
                    start: item.range.start, end: item.range.end, type: item.range.type, text: item.value,
                    source: .llm, confidence: 0.7, priority: EntityLocator.llmPriority
                )
            }
        )
    }

    /// The reported range with each edge that falls inside a Latin word moved
    /// out to that word's boundary, at most 40 UTF-16 units each way.
    ///
    /// Review 2026-11-11 (T1): the tagger ended "Mr. Mateo Ash" inside
    /// "Ashdown" (inputs/perf/five.txt). The fragment could not be anchored,
    /// so the whole document was refused, even with --auto-protect. The whole
    /// word is the value.
    ///
    /// Only within one word: a letter beside a letter, except a lowercase
    /// letter before a capital ("by|Marek"), or a digit beside a digit. The
    /// independent review of T1 found the first version taking glued
    /// characters into the value ("signed byMarek Okafor2" became
    /// {PERSON_1} = "byMarek Okafor2" beside {PERSON_2} = "Marek Okafor").
    /// Such a span is left as reported, so its glued place stays a run-in:
    /// refused, or protected under --auto-protect with the name's own
    /// placeholder. CJK has no word boundaries and is never moved; an edge
    /// still inside a word after 40 units is left to pinnableRange.
    static func snappedToWords(_ start: Int, _ end: Int, in ns: NSString) -> Range<Int> {
        func scalar(_ index: Int) -> Unicode.Scalar? {
            guard index >= 0, index < ns.length else { return nil }
            return Unicode.Scalar(ns.character(at: index))
        }
        /// Whether `left` and `right`, side by side, are inside one word.
        func continuesWord(_ left: Unicode.Scalar?, _ right: Unicode.Scalar?) -> Bool {
            guard let left, let right, left.isASCII, right.isASCII else { return false }
            let letters = CharacterSet.letters
            let digits = CharacterSet.decimalDigits
            if digits.contains(left) && digits.contains(right) { return true }
            guard letters.contains(left), letters.contains(right) else { return false }
            return !(CharacterSet.lowercaseLetters.contains(left) && CharacterSet.uppercaseLetters.contains(right))
        }
        var lower = start
        var upper = end
        var steps = 0
        while steps < 40, continuesWord(scalar(lower - 1), scalar(lower)) {
            lower -= 1
            steps += 1
        }
        steps = 0
        while steps < 40, continuesWord(scalar(upper - 1), scalar(upper)) {
            upper += 1
            steps += 1
        }
        // The second independent review of T1 (probe t03_glue_right.txt): a
        // name glued to the next word ("Marek Okaforand witnessed") or in
        // capitals against the previous one ("BYMAREK OKAFOR") is one word to
        // the test above, so the glue went into the value. The characters
        // cannot tell it from "Mateo Ash" cut inside "Ashdown"; the document
        // can: a value that also stands on its own elsewhere is the whole
        // value, and its glued place is a run-in (isGluedPlace).
        if (lower != start || upper != end), standsAlone(start, end, elsewhereIn: ns) {
            return start..<end
        }
        return lower..<upper
    }

    /// Whether the tagger's range `start..<end` is a value glued to the word
    /// before or after it: an edge inside a word that snappedToWords leaves
    /// where it is, because the value also stands on its own elsewhere.
    static func isGluedPlace(_ start: Int, _ end: Int, in ns: NSString) -> Bool {
        pinnableRange(start, end, in: ns) == nil
            && snappedToWords(start, end, in: ns) == start..<end
            && standsAlone(start, end, elsewhereIn: ns)
    }

    /// Whether the text at `start..<end` also occurs elsewhere in `ns`, case
    /// aside, with neither a Latin letter nor a digit against either side.
    static func standsAlone(_ start: Int, _ end: Int, elsewhereIn ns: NSString) -> Bool {
        guard end > start else { return false }
        let value = ns.substring(with: NSRange(location: start, length: end - start))
        func isWordUnit(_ index: Int) -> Bool {
            guard index >= 0, index < ns.length, let scalar = Unicode.Scalar(ns.character(at: index)) else {
                return false
            }
            return scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)
        }
        var searchFrom = 0
        while searchFrom < ns.length {
            let found = ns.range(
                of: value,
                options: [.caseInsensitive, .literal],
                range: NSRange(location: searchFrom, length: ns.length - searchFrom)
            )
            guard found.location != NSNotFound else { return false }
            if found.location != start, !isWordUnit(found.location - 1), !isWordUnit(NSMaxRange(found)) {
                return true
            }
            searchFrom = found.location + 1
        }
        return false
    }

    /// The reported range with edge whitespace trimmed, or nil when nothing
    /// is left or when it starts or ends inside a word: a Latin letter or a
    /// digit on the far side of either edge. Such a span cannot be redacted
    /// at its place without leaving the rest of the word beside the token, so
    /// it is left to the locator, which reports it as a value it could not
    /// anchor. CJK has no word boundaries and is never refused here.
    static func pinnableRange(_ start: Int, _ end: Int, in ns: NSString) -> Range<Int>? {
        var lower = start
        var upper = end
        let whitespace = CharacterSet.whitespacesAndNewlines
        func scalar(_ index: Int) -> Unicode.Scalar? {
            guard index >= 0, index < ns.length else { return nil }
            return Unicode.Scalar(ns.character(at: index))
        }
        while lower < upper, let s = scalar(lower), whitespace.contains(s) { lower += 1 }
        while upper > lower, let s = scalar(upper - 1), whitespace.contains(s) { upper -= 1 }
        guard lower < upper else { return nil }
        func isWordScalar(_ s: Unicode.Scalar?) -> Bool {
            guard let s else { return false }
            return (CharacterSet.alphanumerics.contains(s)) && !DefinedTermScanner.containsCJK(String(s))
        }
        if isWordScalar(scalar(lower - 1)) && isWordScalar(scalar(lower)) { return nil }
        if isWordScalar(scalar(upper)) && isWordScalar(scalar(upper - 1)) { return nil }
        return lower..<upper
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
