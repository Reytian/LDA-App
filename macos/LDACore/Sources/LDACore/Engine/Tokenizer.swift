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
    ///     and the returned mapping is the union of seed and new entries.
    /// - Returns: The tokenized text plus the mapping needed to restore it.
    public static func tokenize(
        text: String,
        spans: [Span],
        sourceFile: String,
        createdAtISO8601: String,
        seedMapping: Mapping? = nil
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
        // Seed entries are visited in sorted-token order because dictionary
        // iteration is unordered and the walk must stay deterministic.
        if let seedMapping {
            for token in seedMapping.entries.keys.sorted() {
                guard let entry = seedMapping.entries[token], !entry.token.isEmpty else {
                    continue
                }
                entries[entry.token] = entry

                if let parsed = parseToken(entry.token) {
                    typeCounters[parsed.type] = max(typeCounters[parsed.type] ?? 0, parsed.number)
                }

                // A seed token that already exists as a literal in THIS text
                // must not be emitted again (the literal and the reused token
                // would be byte-identical); leave those surfaces unseeded so a
                // fresh token is minted for this document instead.
                guard !reservedLiterals.contains(entry.token) else { continue }

                for surface in [entry.value, entry.surfaceText] + entry.aliases
                where !surface.isEmpty && textToToken[surface] == nil {
                    textToToken[surface] = entry.token
                }
            }
        }

        for span in accepted {
            let surfaceText = span.text
            if textToToken[surfaceText] != nil {
                continue
            }

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

            textToToken[surfaceText] = token

            entries[token] = MappingEntry(
                token: token,
                value: surfaceText,
                type: span.type,
                surfaceText: surfaceText,
                aliases: []
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
            sourceFile: sourceFile
        )

        return TokenizeResult(tokenizedText: tokenizedText, mapping: mapping)
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
