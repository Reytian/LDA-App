//
//  Tokenizer.swift
//  LDACore
//
//  Mints opaque tokens for detected spans and builds the tokenized text in a
//  single left-to-right walk over the original text, in UTF-16 offset space.
//
//  Ported from the proven Python execute_replacement algorithm in
//  core/anonymizer.py. The Python version computes candidate spans against the
//  original text, resolves overlaps (longest match wins, earliest start breaks
//  ties), then walks left-to-right so no inserted token is ever re-scanned. The
//  Swift version assumes spans are already overlap-resolved by SpanMerger, but
//  keeps the same longest-then-earliest tie-break as a defensive guard against
//  any overlaps that slip through.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// Builds tokenized text and the token map from a set of located spans.
///
/// The tokenizer is a pure function: it never reads the clock and never touches
/// the file system. The caller supplies the creation timestamp and source file
/// name so that the result is deterministic and testable.
public enum Tokenizer {
    /// Tokenize the given text against the supplied spans.
    ///
    /// One unique token is minted per DISTINCT surface text. The same surface
    /// text always reuses the same token (the one-string-one-original
    /// invariant). Tokens have the form "{TYPE_N}" where TYPE is
    /// `TokenGrammar.sanitizeType(type.rawValue)` and N is a per-type counter
    /// starting at 1.
    ///
    /// The tokenized text is built by a single left-to-right walk over the
    /// ORIGINAL text using the provided spans. Spans are assumed to be
    /// overlap-resolved by SpanMerger; if any overlaps remain, the longest span
    /// wins and the earliest start breaks ties, and the rest are skipped.
    /// Inserted tokens are never re-scanned because the walk only ever reads the
    /// original text.
    ///
    /// All offsets are treated as UTF-16 code-unit offsets, consistent with
    /// `Span.start` and `Span.end` and with NSRange semantics.
    ///
    /// - Parameters:
    ///   - text: The original source text.
    ///   - spans: Located candidate detections in UTF-16 offset space.
    ///   - sourceFile: The source file this mapping is built from.
    ///   - createdAtISO8601: The caller-supplied ISO-8601 creation timestamp.
    ///   - seedMapping: An optional existing mapping to extend (a prior document
    ///     in the same session, or a client profile's stored mapping). A surface
    ///     text known to the seed (its value, surfaceText, or an alias) reuses
    ///     the seed's token, per-type counters continue past the seed's maxima,
    ///     and the returned mapping is the union of seed and new entries. A seed
    ///     replacement whose shape does not fit the requested style (a brace
    ///     token seeding a pseudonym run, or the reverse) is never re-emitted:
    ///     the entry is carried in the union for restore, and the surface gets
    ///     a fresh replacement in the requested style.
    ///   - style: how replacements are rendered. The default .token preserves
    ///     the historical "{TYPE_N}" output byte for byte.
    ///   - uniquenessCorpus: additional texts (the other documents of a
    ///     session) a pseudonym must not occur in. Ignored by other styles.
    /// - Returns: The tokenized text plus the mapping needed to restore it.
    public static func tokenize(
        text: String,
        spans: [Span],
        sourceFile: String,
        createdAtISO8601: String,
        seedMapping: Mapping? = nil,
        style: SubstitutionStyle = .token,
        uniquenessCorpus: [String] = []
    ) -> TokenizeResult {
        tokenizeCore(
            text: text,
            spans: spans,
            sourceFile: sourceFile,
            createdAtISO8601: createdAtISO8601,
            seedMapping: seedMapping,
            style: style,
            uniquenessCorpus: uniquenessCorpus,
            overrides: [:]
        )
    }

    /// Tokenize with caller-forced replacement text for specific surfaces
    /// (pseudonym style only).
    ///
    /// `overrides` maps exact surface text to the replacement the caller
    /// wants emitted verbatim wherever that surface is tokenized (for
    /// example forcing 买受人 for one company name). Overrides do not create
    /// detections: a surface with no accepted span emits nothing, but its
    /// forced replacement is still reserved so nothing else can mint it.
    ///
    /// The whole override set is validated up front by
    /// PseudonymOverrideValidator (see its typed errors). A non-pseudonym
    /// style with a non-empty override set is rejected with
    /// styleNotPseudonym: forcing arbitrary text under the token style would
    /// recreate the mixed-style trap where the token-grammar restore scan
    /// cannot see non-brace replacements and values silently fail to
    /// restore. An empty override set is valid for every style and behaves
    /// exactly like the non-throwing entry point.
    ///
    /// - Throws: PseudonymOverrideError when any override is rejected.
    public static func tokenize(
        text: String,
        spans: [Span],
        sourceFile: String,
        createdAtISO8601: String,
        seedMapping: Mapping? = nil,
        style: SubstitutionStyle,
        uniquenessCorpus: [String] = [],
        overrides: [String: String]
    ) throws -> TokenizeResult {
        try PseudonymOverrideValidator.validate(
            overrides: overrides,
            style: style,
            corpus: [text] + uniquenessCorpus,
            existingEntries: seedMapping?.entries ?? [:]
        )
        return tokenizeCore(
            text: text,
            spans: spans,
            sourceFile: sourceFile,
            createdAtISO8601: createdAtISO8601,
            seedMapping: seedMapping,
            style: style,
            uniquenessCorpus: uniquenessCorpus,
            overrides: overrides
        )
    }

    /// Shared core behind both public entry points and SessionTokenizer.
    ///
    /// `overrides` must already be validated by PseudonymOverrideValidator
    /// against the FULL corpus this text belongs to; the core reserves and
    /// applies them without revalidating. Internal rather than private so
    /// SessionTokenizer can fold a session it validated once as a whole.
    static func tokenizeCore(
        text: String,
        spans: [Span],
        sourceFile: String,
        createdAtISO8601: String,
        seedMapping: Mapping?,
        style: SubstitutionStyle,
        uniquenessCorpus: [String],
        overrides: [String: String]
    ) -> TokenizeResult {
        let utf16Count = text.utf16.count

        // Step 1: keep only spans with valid, in-bounds, non-empty ranges.
        let validSpans = spans.filter { span in
            span.start >= 0
                && span.end <= utf16Count
                && span.start < span.end
        }

        // Step 2: resolve any residual overlaps. Prefer the longest span; on
        // equal length prefer the earliest start. Drop any span that overlaps an
        // already-accepted span. This mirrors the Python candidate_spans sort
        // (longest first, then earliest) followed by a greedy accept.
        let ordered = validSpans.sorted { lhs, rhs in
            let lhsLength = lhs.end - lhs.start
            let rhsLength = rhs.end - rhs.start
            if lhsLength != rhsLength {
                return lhsLength > rhsLength
            }
            return lhs.start < rhs.start
        }

        var accepted: [Span] = []
        for span in ordered {
            let overlaps = accepted.contains { other in
                span.start < other.end && span.end > other.start
            }
            if !overlaps {
                accepted.append(span)
            }
        }

        // Pre-scan the ORIGINAL text for token-shaped literals already present
        // (for example a template fill-in field "{AMOUNT_1}" or a leftover merge
        // field). A minted token must never reproduce one of these literals: the
        // copied-through literal and the minted token would be byte-identical, so
        // Restorer's substitution would overwrite the user's literal with the
        // entity value and the round-trip would silently corrupt the document.
        let reservedLiterals = sourceTokenLiterals(in: text)

        // Step 3: mint tokens. One token per DISTINCT surface text, with a
        // per-type counter starting at 1. The first span that registers a given
        // surface text wins its token; later spans with the identical surface
        // text reuse it. Iterate the accepted spans in document order so token
        // numbering is stable and reads naturally left-to-right.
        accepted.sort { $0.start < $1.start }

        var typeCounters: [String: Int] = [:]
        var textToToken: [String: String] = [:]
        var entries: [String: MappingEntry] = [:]

        // Seed the walk from an existing mapping: known surfaces reuse their
        // token, counters continue past the seed maxima, and the seed entries
        // are carried into the result so one mapping restores every document.
        // Seed entries are visited in sorted-key order because dictionary
        // iteration is unordered and the walk must stay deterministic. Entries
        // are carried under their seed key (not entry.token) so asterisk
        // collision keys survive the union.
        if let seedMapping {
            for key in seedMapping.entries.keys.sorted() {
                guard let entry = seedMapping.entries[key], !entry.token.isEmpty else {
                    continue
                }
                entries[key] = entry

                if style == .token, let parsed = parseToken(entry.token) {
                    typeCounters[parsed.type] = max(typeCounters[parsed.type] ?? 0, parsed.number)
                }

                for surface in [entry.value, entry.surfaceText] + entry.aliases
                where !surface.isEmpty && textToToken[surface] == nil {
                    guard canReuseSeedReplacement(
                        entry,
                        surface: surface,
                        style: style,
                        text: text,
                        reservedLiterals: reservedLiterals,
                        uniquenessCorpus: uniquenessCorpus
                    ) else { continue }
                    textToToken[surface] = entry.token
                }
            }
        }

        // Every replacement string already spoken for (seed entries included),
        // so a pseudonym can never collide with one.
        var usedReplacements = Set(entries.values.map { $0.token })
        registerOverrides(
            overrides,
            usedReplacements: &usedReplacements,
            textToToken: &textToToken
        )
        var pseudonyms = PseudonymGenerator()

        for span in accepted {
            let surfaceText = span.text
            if textToToken[surfaceText] != nil {
                continue
            }

            let replacement: String
            if let forced = overrides[surfaceText] {
                // Caller-forced text (pre-validated, pseudonym style only):
                // emitted verbatim. Already reserved by registerOverrides, so
                // no minted pseudonym can collide with it.
                replacement = forced
            } else {
                switch style {
                case .token:
                    let typeToken = TokenGrammar.sanitizeType(span.type.rawValue)

                    // Advance the per-type counter, skipping any value that would collide
                    // with a token-shaped literal already in the source. This keeps minted
                    // tokens in a numbering range disjoint from any literal {TYPE_N}, so
                    // the tokenized edit surface is unambiguous and restore stays lossless.
                    var nextCount = (typeCounters[typeToken] ?? 0) + 1
                    var token = "{\(typeToken)_\(nextCount)}"
                    while reservedLiterals.contains(token) {
                        nextCount += 1
                        token = "{\(typeToken)_\(nextCount)}"
                    }
                    typeCounters[typeToken] = nextCount
                    replacement = token

                case .pseudonym:
                    // A pseudonym must be free four ways: never used by another
                    // entity, never a token literal, and never occurring in this
                    // document or in any companion document of the session, so
                    // the literal restore scan can only ever hit substitution
                    // sites.
                    replacement = pseudonyms.mint(type: span.type, surface: surfaceText) { candidate in
                        usedReplacements.contains(candidate)
                            || reservedLiterals.contains(candidate)
                            || text.contains(candidate)
                            || uniquenessCorpus.contains { $0.contains(candidate) }
                    }

                case .asterisk:
                    // Masking is a pure function of the surface. Collisions are
                    // allowed by design and preserved as distinct entries below;
                    // restore refuses the ambiguous ones.
                    replacement = AsteriskMasking.mask(surfaceText, type: span.type)
                }
            }

            usedReplacements.insert(replacement)
            textToToken[surfaceText] = replacement

            insertEntry(
                MappingEntry(
                    token: replacement,
                    value: surfaceText,
                    type: span.type,
                    surfaceText: surfaceText,
                    aliases: []
                ),
                into: &entries
            )
        }

        // Step 4: single left-to-right walk over the ORIGINAL text. Copy the
        // untouched original text before each span, then emit the span's token.
        // The cursor only ever advances over original-text UTF-16 offsets, so no
        // inserted token is re-scanned.
        var pieces: [String] = []
        var cursor = 0

        for span in accepted {
            // The span's surface text must already have a token. Every accepted
            // span registered one in step 3, so this lookup never misses.
            guard let token = textToToken[span.text] else {
                continue
            }

            if span.start > cursor {
                pieces.append(utf16Substring(of: text, from: cursor, to: span.start))
            }
            pieces.append(token)
            cursor = span.end
        }

        if cursor < utf16Count {
            pieces.append(utf16Substring(of: text, from: cursor, to: utf16Count))
        }

        let tokenizedText = pieces.joined()

        let mapping = Mapping(
            entries: entries,
            createdAtISO8601: createdAtISO8601,
            sourceFile: sourceFile,
            style: style
        )

        return TokenizeResult(tokenizedText: tokenizedText, mapping: mapping)
    }

    /// Whether a seed entry's replacement may be re-emitted for a known
    /// surface under the requested style.
    ///
    /// - token: only an exact grammar token is a valid token-style
    ///   replacement, and a seed token that already exists as a literal in
    ///   THIS text must not be emitted again (the literal and the reused
    ///   token would be byte-identical and restore would corrupt the
    ///   literal).
    /// - pseudonym: a grammar-token seed must not leak into a pseudonym
    ///   document (that is the failure mode this style fixes), and a
    ///   pseudonym occurring naturally in this document or a companion
    ///   document cannot be reused because the literal restore scan could
    ///   not tell the natural occurrence from the substitution.
    /// - asterisk: a replacement is reusable only when it equals this
    ///   surface's own mask (masking is deterministic, so this simply
    ///   filters out replacements carried over from other styles).
    private static func canReuseSeedReplacement(
        _ entry: MappingEntry,
        surface: String,
        style: SubstitutionStyle,
        text: String,
        reservedLiterals: Set<String>,
        uniquenessCorpus: [String]
    ) -> Bool {
        switch style {
        case .token:
            return parseToken(entry.token) != nil
                && !reservedLiterals.contains(entry.token)
        case .pseudonym:
            return parseToken(entry.token) == nil
                && !text.contains(entry.token)
                && !uniquenessCorpus.contains { $0.contains(entry.token) }
        case .asterisk:
            return entry.token == AsteriskMasking.mask(surface, type: entry.type)
        }
    }

    /// Reserve pre-validated overrides before any minting happens.
    ///
    /// Every override replacement enters usedReplacements, so a minted
    /// pseudonym can never equal a forced replacement, including one whose
    /// surface appears only in a companion document of the session. An
    /// override also beats seed reuse for its surface: a stale binding is
    /// dropped so the mint loop emits the forced text instead (the seed ENTRY
    /// stays in the union, so earlier documents keep restoring). A binding
    /// that already equals the forced text is kept, which is what makes
    /// re-running a build with unchanged overrides idempotent: the mint loop
    /// then skips the surface and no duplicate entry is inserted.
    private static func registerOverrides(
        _ overrides: [String: String],
        usedReplacements: inout Set<String>,
        textToToken: inout [String: String]
    ) {
        for surface in overrides.keys.sorted() {
            guard let forced = overrides[surface] else {
                continue
            }
            usedReplacements.insert(forced)
            if textToToken[surface] != forced {
                textToToken[surface] = nil
            }
        }
    }

    /// Insert a freshly minted entry under a collision-free key.
    ///
    /// Token and pseudonym replacements are unique by construction, so the
    /// key is simply the replacement. Asterisk masks can collide across
    /// entities; the colliding entry is stored under "<mask>#N" so both
    /// originals are recorded and restore can detect the ambiguity.
    private static func insertEntry(
        _ entry: MappingEntry,
        into entries: inout [String: MappingEntry]
    ) {
        if entries[entry.token] == nil {
            entries[entry.token] = entry
            return
        }
        var suffix = 2
        while entries["\(entry.token)#\(suffix)"] != nil {
            suffix += 1
        }
        entries["\(entry.token)#\(suffix)"] = entry
    }

    /// Scan `text` for every token-shaped literal already present, using the
    /// shared `TokenGrammar.placeholderPattern` so emit and restore never drift.
    ///
    /// Returns the set of distinct matched strings (for example "{PERSON_1}").
    /// This stays a pure function: it only reads the in-memory text and never
    /// touches the clock or the file system. NSRegularExpression runs over the
    /// text as an NSString, matching the UTF-16 offset convention used elsewhere.
    private static func sourceTokenLiterals(in text: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(
            pattern: TokenGrammar.placeholderPattern
        ) else {
            return []
        }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var literals = Set<String>()
        regex.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
            guard let match = match else {
                return
            }
            literals.insert(nsText.substring(with: match.range))
        }
        return literals
    }

    /// Extract the substring of `text` between two UTF-16 code-unit offsets.
    ///
    /// Offsets are converted to `String.Index` via
    /// `String.Index(utf16Offset:in:)` so multibyte and CJK text slices at the
    /// correct grapheme boundaries that the UTF-16 offsets denote.
    private static func utf16Substring(of text: String, from: Int, to: Int) -> String {
        let lower = String.Index(utf16Offset: from, in: text)
        let upper = String.Index(utf16Offset: to, in: text)
        return String(text[lower..<upper])
    }

    /// Parse a grammar token "{TYPE_N}" into its TYPE string and number, or nil
    /// when the string is not an exact grammar token. Used to continue per-type
    /// counters past a seed mapping's maxima.
    private static func parseToken(_ token: String) -> (type: String, number: Int)? {
        guard let regex = try? NSRegularExpression(
            pattern: #"^\{([A-Z][A-Z0-9]*)_(\d+)\}$"#
        ) else {
            return nil
        }
        let nsToken = token as NSString
        let range = NSRange(location: 0, length: nsToken.length)
        guard let match = regex.firstMatch(in: token, options: [], range: range),
              match.numberOfRanges == 3,
              let number = Int(nsToken.substring(with: match.range(at: 2))) else {
            return nil
        }
        return (nsToken.substring(with: match.range(at: 1)), number)
    }
}
