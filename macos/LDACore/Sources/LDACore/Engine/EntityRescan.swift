//
//  EntityRescan.swift
//  LDACore
//
//  Full-document literal rescan (the second recall pass). Chunked LLM
//  detection can catch an entity in one window and miss mentions elsewhere,
//  and defined short names (以下简称) may never be reported at all. After the
//  merge produces the confirmed span list, this pass takes every confirmed
//  PERSON and COMPANY surface, plus the document's defined aliases bound to
//  those entities, and literally scans the ENTIRE text for further
//  occurrences. No model calls: pure string search via EntityLocator, which
//  already enforces Latin word boundaries (so "Li" never fires inside
//  "Client") and CJK exact-literal matching.
//
//  Safety posture:
//  - Occurrences overlapping ANY already-confirmed span (of any type) are
//    skipped; overlaps among the rescan hits themselves resolve longest-first.
//  - Very short surfaces are never used as needles (see the threshold
//    constants below): mass false positives shred documents.
//  - Role labels and legal boilerplate are never used as needles, whatever
//    source confirmed them.
//  - Aliases must be BOUND to a confirmed entity (the definition parenthetical
//    directly follows that entity's span) and DERIVED from its name, so a
//    generic defined term (本协议, "the Target") never becomes a needle.
//
//  This pass also resolves the alias grouping (全称/简称归并) for the mapping
//  layer: linkAliases stamps each alias entry with its canonical entry's
//  token. The alias keeps its own token and value, so restore stays
//  byte-identical at every site; the data model's token-to-value restore is
//  strictly one-to-one, which rules out sharing one token across two
//  different surfaces.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

// MARK: - AliasPair

/// A resolved short-name relationship: a confirmed canonical entity surface
/// and the derived alias surface a definition parenthetical binds to it.
public struct AliasPair: Equatable, Sendable {
    /// The canonical entity surface exactly as confirmed in the document.
    public let canonical: String
    /// The alias surface exactly as defined in the document.
    public let alias: String
    /// The canonical entity's type (PERSON or COMPANY).
    public let type: EntityType

    public init(canonical: String, alias: String, type: EntityType) {
        self.canonical = canonical
        self.alias = alias
        self.type = type
    }
}

// MARK: - EntityRescan

/// The engine-level recall rescan. Pure and deterministic: no clock, no IO,
/// no model calls.
public enum EntityRescan {

    // MARK: - Thresholds

    /// Minimum Character count for a rescan needle that contains CJK. One
    /// ideograph alone (a bare surname, a single 字) is too ambiguous to
    /// rescan; two, a full short name or a two-character given name, is safe
    /// because CJK matches are exact literals.
    public static let minimumCJKNeedleCharacters = 2

    /// Minimum Character count for a purely non-CJK needle. Short Latin
    /// fragments ("Li", "Wu", "Kim") collide with too much prose even with
    /// word boundaries enforced, so they are left to the model's own
    /// per-mention detection.
    public static let minimumLatinNeedleCharacters = 4

    /// Minimum Character count for an acronym-shaped needle (all uppercase
    /// letters or digits, like "IBM"). Document-defined acronym aliases are a
    /// strong identity signal, so they are allowed one character below the
    /// Latin minimum; two-letter acronyms stay out ("GE" would collide with
    /// the syllable "ge" under case-insensitive search).
    public static let minimumAcronymNeedleCharacters = 3

    /// Maximum UTF-16 code units between a confirmed entity span's end and the
    /// opening parenthesis of a definition parenthetical for the two to bind.
    /// The gap may hold only whitespace and closing quotes.
    public static let maximumBindingGapUTF16 = 6

    // MARK: - Expand

    /// Expand a confirmed (merged, overlap-free) span list with every further
    /// literal occurrence of its PERSON and COMPANY surfaces and their bound
    /// aliases. Returns the union, sorted by start ascending, still
    /// overlap-free. Spans of other types are passed through untouched.
    ///
    /// - Parameters:
    ///   - confirmed: this document's merged, overlap-free spans.
    ///   - text: this document's full text.
    ///   - knownEntities: optional PERSON and COMPANY spans confirmed in OTHER
    ///     documents of the same session. Their surfaces join the needle set
    ///     (same safety filters) but they never block occurrences, since their
    ///     offsets belong to other documents. This closes the session-level
    ///     recall gap: a party detected in document 1 is swept in document 2
    ///     even when document 2's own detection missed it.
    public static func expand(
        _ confirmed: [Span],
        in text: String,
        knownEntities: [Span] = []
    ) -> [Span] {
        guard !confirmed.isEmpty || !knownEntities.isEmpty, !text.isEmpty else {
            return confirmed
        }

        // 1. Needles from confirmed PERSON and COMPANY surfaces, in document
        //    order so the type of a surface confirmed twice under different
        //    types follows its earliest span. Dedup is case-insensitive to
        //    match EntityLocator's case-insensitive search. Session-known
        //    surfaces follow the document's own, so a local confirmation wins
        //    the needle metadata.
        var needles: [Needle] = []
        var seenNeedles = Set<String>()
        let ordered = confirmed.sorted { lhs, rhs in
            lhs.start != rhs.start ? lhs.start < rhs.start : lhs.end < rhs.end
        }
        for span in ordered + knownEntities where span.type == .person || span.type == .company {
            let value = span.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = value.lowercased()
            guard !value.isEmpty, !seenNeedles.contains(key) else { continue }
            guard isSafeNeedle(value, type: span.type) else { continue }
            seenNeedles.insert(key)
            needles.append(
                Needle(value: value, type: span.type, source: span.source, confidence: span.confidence)
            )
        }

        // 2. Alias needles from definition parentheticals bound to confirmed
        //    entities. The alias inherits the canonical span's source and
        //    confidence so a deterministic-only run never mislabels its own
        //    derived spans as model output.
        let pairs = aliasPairs(in: text, confirmed: ordered)
        if !pairs.isEmpty {
            var spanBySurface: [String: Span] = [:]
            for span in ordered where spanBySurface[span.text] == nil {
                spanBySurface[span.text] = span
            }
            for pair in pairs {
                let key = pair.alias.lowercased()
                guard !seenNeedles.contains(key) else { continue }
                guard isSafeNeedle(pair.alias, type: pair.type) else { continue }
                seenNeedles.insert(key)
                let seed = spanBySurface[pair.canonical]
                needles.append(
                    Needle(
                        value: pair.alias,
                        type: pair.type,
                        source: seed?.source ?? .llm,
                        confidence: seed?.confidence ?? 0.7
                    )
                )
            }
        }

        guard !needles.isEmpty else { return confirmed }

        // 3. Locate every occurrence of every needle and drop hits that
        //    overlap ANY confirmed span (of any type). EntityLocator enforces
        //    the word-boundary and exact-literal rules.
        let blocked = ordered.map { (start: $0.start, end: $0.end) }
        var candidates: [Span] = []
        for needle in needles {
            let hits = EntityLocator.spans(
                forValue: needle.value,
                type: needle.type,
                in: text,
                source: needle.source,
                confidence: needle.confidence
            )
            for hit in hits where !overlapsAny(hit, sortedBlocked: blocked) {
                candidates.append(hit)
            }
        }
        guard !candidates.isEmpty else { return confirmed }

        // 4. Resolve overlaps among the rescan hits themselves: longest first,
        //    then earliest start, then earliest end (SpanMerger's tie-break),
        //    greedy accept.
        candidates.sort { lhs, rhs in
            let lhsLength = lhs.end - lhs.start
            let rhsLength = rhs.end - rhs.start
            if lhsLength != rhsLength {
                return lhsLength > rhsLength
            }
            if lhs.start != rhs.start {
                return lhs.start < rhs.start
            }
            return lhs.end < rhs.end
        }
        var accepted: [Span] = []
        for candidate in candidates {
            let clashes = accepted.contains { existing in
                candidate.start < existing.end && candidate.end > existing.start
            }
            if !clashes {
                accepted.append(candidate)
            }
        }

        // 5. Union in document order.
        return (ordered + accepted).sorted { lhs, rhs in
            lhs.start != rhs.start ? lhs.start < rhs.start : lhs.end < rhs.end
        }
    }

    // MARK: - Unswept surfaces (cross-document recall check)

    /// The knownEntities surfaces that expand() WOULD sweep into this text and
    /// that the confirmed span list does not already cover. In other words:
    /// the parties a partner document has confirmed and this document still
    /// holds in the clear.
    ///
    /// Read-only by design. It produces no spans and edits nothing, so a
    /// caller can report the gap to a human without putting an unreviewed
    /// redaction decision into the pipeline.
    ///
    /// It applies exactly the filters expand() applies, and that is the point:
    /// the needle-safety threshold, the case-insensitive dedup against the
    /// document's own confirmed surfaces, and the block on occurrences that
    /// overlap a confirmed span. A check that drifted from the sweep would
    /// send the user back to re-scan for something the re-scan would refuse to
    /// find.
    ///
    /// - Parameters:
    ///   - text: this document's full text.
    ///   - confirmed: this document's own confirmed spans, overlap-free (the
    ///     same precondition expand() carries).
    ///   - knownEntities: PERSON and COMPANY spans confirmed in OTHER
    ///     documents. Only their surfaces are read; their offsets belong to
    ///     other documents and are never used here.
    /// - Returns: the distinct uncovered surfaces, in knownEntities order.
    ///   Empty when the document is already covered.
    public static func unsweptSurfaces(
        in text: String,
        confirmed: [Span],
        knownEntities: [Span]
    ) -> [String] {
        unsweptNeedles(in: text, confirmed: confirmed, knownEntities: knownEntities)
            .map(\.value)
    }

    /// One surface unsweptNeedles() reports, carrying the entity type the
    /// sweep's needle would actually use: the type of the surface's FIRST
    /// knownEntities span, the same first-occurrence rule expand() applies to
    /// needle metadata. Callers that reason about per-type state (learned
    /// suppression keys are (value, type) pairs) must check this one type; a
    /// union over every type the partners confirmed drifts from what the
    /// sweep would mint for a homograph surface.
    public struct UnsweptSurface: Equatable, Sendable {
        /// The trimmed surface text.
        public let value: String
        /// The type the sweep's needle would carry.
        public let type: EntityType

        public init(value: String, type: EntityType) {
            self.value = value
            self.type = type
        }
    }

    /// The typed form of unsweptSurfaces(in:confirmed:knownEntities:): the
    /// same filters, the same order, plus the needle type per surface.
    public static func unsweptNeedles(
        in text: String,
        confirmed: [Span],
        knownEntities: [Span]
    ) -> [UnsweptSurface] {
        guard !text.isEmpty, !knownEntities.isEmpty else { return [] }

        // A surface this document confirmed for itself is already one of its
        // own needles in expand(), so it is never reported as unswept.
        var seen = Set<String>()
        for span in confirmed where span.type == .person || span.type == .company {
            let value = span.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            seen.insert(value.lowercased())
        }

        let blocked = confirmed
            .sorted { lhs, rhs in
                lhs.start != rhs.start ? lhs.start < rhs.start : lhs.end < rhs.end
            }
            .map { (start: $0.start, end: $0.end) }

        var unswept: [UnsweptSurface] = []
        for span in knownEntities where span.type == .person || span.type == .company {
            let value = span.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value.lowercased()).inserted else { continue }
            guard isSafeNeedle(value, type: span.type) else { continue }
            let hits = EntityLocator.spans(forValue: value, type: span.type, in: text)
            guard hits.contains(where: { !overlapsAny($0, sortedBlocked: blocked) }) else {
                continue
            }
            unswept.append(UnsweptSurface(value: value, type: span.type))
        }
        return unswept
    }

    // MARK: - Alias pairs

    /// Resolve the document's defined short names against the confirmed span
    /// list: an alias binds to the PERSON or COMPANY span that immediately
    /// precedes its definition parenthetical (whitespace and closing quotes
    /// may intervene), and it must be derived from that entity's surface
    /// (substring for CJK, word subset or acronym for Latin). One pair per
    /// distinct alias; the first binding in document order wins.
    public static func aliasPairs(in text: String, confirmed: [Span]) -> [AliasPair] {
        let bindings = DefinedTermScanner.aliasBindings(in: text)
        guard !bindings.isEmpty else { return [] }

        let entities = confirmed
            .filter { $0.type == .person || $0.type == .company }
            .sorted { lhs, rhs in
                lhs.start != rhs.start ? lhs.start < rhs.start : lhs.end < rhs.end
            }
        guard !entities.isEmpty else { return [] }

        let ns = text as NSString
        var pairs: [AliasPair] = []
        var seenAliases = Set<String>()

        for binding in bindings {
            let alias = binding.alias.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !alias.isEmpty else { continue }
            guard let canonical = bindingTarget(for: binding, in: ns, entities: entities) else {
                continue
            }
            guard alias != canonical.text else { continue }
            guard isSafeNeedle(alias, type: canonical.type) else { continue }
            guard DefinedTermScanner.isDerivedAlias(alias, of: canonical.text) else { continue }
            guard seenAliases.insert(alias.lowercased()).inserted else { continue }
            pairs.append(AliasPair(canonical: canonical.text, alias: alias, type: canonical.type))
        }
        return pairs
    }

    // MARK: - Mapping linkage

    /// Record the alias grouping in a token mapping: for every pair, the entry
    /// whose surface is the alias gets `canonicalToken` set to the KEY (in
    /// Mapping.entries) of the entry whose surface is the canonical name.
    /// The key, not the token field: keys are unique even for asterisk
    /// collision entries, whose token holds a shared mask while the key
    /// disambiguates. Values, tokens, and restore behavior are untouched, so
    /// restore stays byte-identical; only the grouping metadata is added.
    /// Returns a new Mapping (no mutation of the input). Entries already
    /// carrying a canonicalToken keep it.
    public static func linkAliases(in mapping: Mapping, pairs: [AliasPair]) -> Mapping {
        guard !pairs.isEmpty, !mapping.entries.isEmpty else { return mapping }

        // Case-insensitive surface -> token, first token in sorted order wins
        // so the linkage is deterministic.
        var tokenByFold: [String: String] = [:]
        for token in mapping.entries.keys.sorted() {
            guard let entry = mapping.entries[token] else { continue }
            for surface in [entry.value, entry.surfaceText] where !surface.isEmpty {
                let fold = surface.lowercased()
                if tokenByFold[fold] == nil {
                    tokenByFold[fold] = token
                }
            }
        }

        var updated = mapping
        for pair in pairs {
            guard let canonicalToken = tokenByFold[pair.canonical.lowercased()] else { continue }
            guard let aliasToken = tokenByFold[pair.alias.lowercased()],
                  aliasToken != canonicalToken,
                  var aliasEntry = updated.entries[aliasToken],
                  aliasEntry.canonicalToken == nil else { continue }
            aliasEntry.canonicalToken = canonicalToken
            updated.entries[aliasToken] = aliasEntry
        }
        return updated
    }

    // MARK: - Needle safety

    /// True when a surface is safe to use as a rescan needle: it meets the
    /// length threshold for its script and is neither a role label nor known
    /// legal boilerplate for its type.
    static func isSafeNeedle(_ value: String, type: EntityType) -> Bool {
        let characters = value.count
        if DefinedTermScanner.containsCJK(value) {
            guard characters >= minimumCJKNeedleCharacters else { return false }
        } else {
            let isAcronymShaped = characters >= minimumAcronymNeedleCharacters
                && value.allSatisfy { $0.isUppercase || $0.isNumber }
            guard characters >= minimumLatinNeedleCharacters || isAcronymShaped else {
                return false
            }
        }
        // shouldDrop includes the RoleLabels check.
        return !LegalBoilerplate.shouldDrop(value, type: type)
    }

    // MARK: - Private helpers

    /// A literal search needle: the surface to scan for and the metadata to
    /// stamp on the spans it produces.
    private struct Needle {
        let value: String
        let type: EntityType
        let source: DetectionSource
        let confidence: Double
    }

    /// Characters allowed between a confirmed entity span's end and the
    /// opening parenthesis of its definition parenthetical: whitespace plus
    /// closing quotes.
    private static let bindingGapCharacters = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\"\u{201D}\u{2019}'\u{300D}\u{300F}"))

    /// The PERSON or COMPANY span whose end sits directly before the
    /// binding's anchor, with only whitespace or closing quotes in between and
    /// a gap of at most maximumBindingGapUTF16 code units. The span with the
    /// largest qualifying end wins.
    private static func bindingTarget(
        for binding: AliasBinding,
        in ns: NSString,
        entities: [Span]
    ) -> Span? {
        let anchor = binding.anchorOffset
        var best: Span?
        for span in entities {
            guard span.end <= anchor, anchor - span.end <= maximumBindingGapUTF16 else { continue }
            if let current = best, current.end > span.end { continue }
            let gap = ns.substring(with: NSRange(location: span.end, length: anchor - span.end))
            let isClean = gap.unicodeScalars.allSatisfy { bindingGapCharacters.contains($0) }
            if isClean {
                best = span
            }
        }
        return best
    }

    /// True when the candidate overlaps any blocked interval. The blocked
    /// list holds the confirmed spans, which are overlap-free and sorted by
    /// start, so their ends are sorted too and a binary search finds the only
    /// interval that could overlap in O(log n) per candidate.
    private static func overlapsAny(
        _ candidate: Span,
        sortedBlocked: [(start: Int, end: Int)]
    ) -> Bool {
        // First interval whose end is greater than the candidate's start.
        var low = 0
        var high = sortedBlocked.count
        while low < high {
            let mid = (low + high) / 2
            if sortedBlocked[mid].end <= candidate.start {
                low = mid + 1
            } else {
                high = mid
            }
        }
        guard low < sortedBlocked.count else { return false }
        return sortedBlocked[low].start < candidate.end
    }
}
