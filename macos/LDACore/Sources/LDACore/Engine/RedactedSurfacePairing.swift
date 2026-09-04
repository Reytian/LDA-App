//
//  RedactedSurfacePairing.swift
//  LDACore
//
//  The public pairing seam over Tokenizer's emit walk: which offsets of a
//  redacted rendering are text the ORIGINAL document holds, and where that
//  text sits in the original.
//
//  Why this exists. A face that shows the redacted surface and lets the user
//  act on a selection in it holds an offset in the WRONG COORDINATE SPACE.
//  Reading a redacted offset against the original text takes whatever
//  characters happen to live there, and if that text is then protected, the
//  mapping is keyed on a fragment the user never chose. Nothing crashes: the
//  damage appears at restore, as text put back in the wrong place. The
//  reverse mistake is worse. Where the redacted text shows a replacement, the
//  original holds the value that replacement stands for, so protecting the
//  selection would mint a mapping KEYED ON A REPLACEMENT, and the literal
//  restore scan can no longer tell a substitution site from a key.
//
//  So a caller must be able to ask a question with three answers, never two:
//  this selection is the document's own text (and here is where), or it is
//  part of a replacement, or the pairing cannot be established and the
//  question has no answer. The third answer is not "yes".
//
//  How it is decided. PseudonymSeamGuard.renderProvisional already walks the
//  original text exactly the way Tokenizer's emit walk does and reports where
//  each span's emitted piece landed. Re-rendering and comparing is what makes
//  the pairing provable rather than assumed: if the rendering is byte
//  identical to the redacted text that was actually displayed, then every run
//  between two pieces IS the original substring the walk copied there, and
//  the pairing's claim holds whatever the replacement strings were. If the
//  comparison fails, or the walk's own arithmetic does not add up, this type
//  refuses to exist. That is SessionSeamVerifier's precedent (it answers
//  `.unverifiable` rather than a silent all clear when the same equality
//  fails), and it is the only honest answer: an empty answer here would be
//  indistinguishable from "the selection is safe to protect".
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// A proven offset pairing between a redacted rendering and the original text
/// it was built from.
///
/// The runs tile the whole redacted text in order, with no gaps and no
/// overlaps, and alternate between text carried through from the original and
/// the replacements emitted for protected spans.
public struct RedactedSurfacePairing: Equatable {

    /// What one run of the redacted text stands for.
    public enum Origin: String, Equatable {
        /// Text copied through from the original, character for character.
        case carriedThrough
        /// A replacement emitted in place of a protected value.
        case replacement
    }

    /// One run of the redacted text and where it came from.
    public struct Run: Equatable {
        /// The run's place in the redacted text, in UTF-16 offsets.
        public let redacted: NSRange
        /// For a carried-through run, the same characters' place in the
        /// original. For a replacement run, the span the replacement stands
        /// for, whose length is unrelated to the run's own.
        public let original: NSRange
        public let origin: Origin

        public init(redacted: NSRange, original: NSRange, origin: Origin) {
            self.redacted = redacted
            self.original = original
            self.origin = origin
        }
    }

    /// What a selection in the redacted text resolves to.
    public enum Resolution: Equatable {
        /// The selection is the original document's own text; the range is
        /// its place THERE, ready to be read against the original.
        case carriedThrough(NSRange)
        /// The selection covers part or all of a replacement, so it is not
        /// text the original holds at that place.
        case replacement
        /// Empty, out of bounds, or not described by these runs. The caller
        /// must refuse rather than guess.
        case undecidable
    }

    /// The runs, in redacted order.
    public let runs: [Run]
    /// UTF-16 length of the redacted text the runs tile.
    public let redactedLength: Int
    /// UTF-16 length of the original text they pair with.
    public let originalLength: Int

    init(runs: [Run], redactedLength: Int, originalLength: Int) {
        self.runs = runs
        self.redactedLength = redactedLength
        self.originalLength = originalLength
    }

    // MARK: - Building

    /// Pair a redacted rendering with the original text it came from, or
    /// return nil when the pairing cannot be established.
    ///
    /// Every assumption the walk makes is checked here, and any surprise
    /// returns nil rather than a partly trusted map:
    ///
    /// - the re-rendering must be byte identical to `redacted` (the proof),
    /// - every span must have produced a piece, so the spans must be
    ///   non-overlapping (Tokenizer resolves residual overlaps by longest
    ///   match; this refuses instead of reproducing that rule),
    /// - each piece must sit exactly where the run arithmetic says, and the
    ///   runs must tile the whole redacted text.
    ///
    /// - Parameters:
    ///   - original: the text before redaction.
    ///   - redacted: the text that was actually rendered and shown.
    ///   - spans: the spans that were redacted, in any order.
    ///   - mapping: the mapping the redaction produced. It is read only to
    ///     recover which replacement each surface received; a surface it does
    ///     not cover renders as its own text, which either breaks the
    ///     equality above or leaves that run marked as a replacement, and
    ///     both outcomes are refusals rather than a wrong allow.
    public static func pair(
        original: String,
        redacted: String,
        spans: [Span],
        mapping: Mapping
    ) -> RedactedSurfacePairing? {
        let nsOriginal = original as NSString
        let originalLength = nsOriginal.length
        let redactedLength = (redacted as NSString).length

        // Mirror Tokenizer's validity filter and emit order exactly. A span
        // the tokenizer would have dropped must be dropped here too, or the
        // rendering below could not match the text it produced.
        let ordered = spans
            .filter { $0.start >= 0 && $0.end <= originalLength && $0.start < $0.end }
            .sorted { lhs, rhs in
                lhs.start != rhs.start ? lhs.start < rhs.start : lhs.end < rhs.end
            }

        let rendered = PseudonymSeamGuard.renderProvisional(
            text: original,
            spans: ordered,
            replacementBySurface: replacementBySurface(in: mapping)
        )
        guard rendered.text == redacted,
              rendered.pieceRanges.count == ordered.count else {
            return nil
        }

        var runs: [Run] = []
        var cursor = 0
        var emitted = 0

        for (index, span) in ordered.enumerated() {
            guard let piece = rendered.pieceRanges[index], span.start >= cursor else {
                // A nil piece means the walk skipped the span as out of
                // order, which for a sorted list means it overlapped its
                // predecessor. The rendering is then not a tiling.
                return nil
            }
            if span.start > cursor {
                let gap = span.start - cursor
                guard piece.location == emitted + gap else { return nil }
                runs.append(
                    Run(
                        redacted: NSRange(location: emitted, length: gap),
                        original: NSRange(location: cursor, length: gap),
                        origin: .carriedThrough
                    )
                )
                emitted += gap
            }
            guard piece.location == emitted, piece.length > 0 else { return nil }
            runs.append(
                Run(
                    redacted: piece,
                    original: NSRange(location: span.start, length: span.end - span.start),
                    origin: .replacement
                )
            )
            emitted = NSMaxRange(piece)
            cursor = span.end
        }

        if cursor < originalLength {
            let tail = originalLength - cursor
            runs.append(
                Run(
                    redacted: NSRange(location: emitted, length: tail),
                    original: NSRange(location: cursor, length: tail),
                    origin: .carriedThrough
                )
            )
            emitted += tail
        }

        guard emitted == redactedLength else { return nil }
        return RedactedSurfacePairing(
            runs: runs,
            redactedLength: redactedLength,
            originalLength: originalLength
        )
    }

    /// Surface text to the replacement it received, recovered from a mapping
    /// the same way Tokenizer's seed walk reads one: keys in sorted order so
    /// the result is deterministic, and the first claim on a surface wins.
    ///
    /// A mapping can hold two entries for one surface, because a replacement
    /// carried in from another substitution style is never re-emitted: the
    /// entry stays in the union so older documents keep restoring, and the
    /// surface gets a fresh replacement in the mapping's own style. Reading
    /// the stale one would describe a rendering nobody produced, so entries
    /// whose replacement does not fit the style are skipped. That is the same
    /// brace-versus-not distinction TokenGrammar.isPlaceholderShaped exists
    /// for, not a second copy of the mint rules.
    private static func replacementBySurface(in mapping: Mapping) -> [String: String] {
        var map: [String: String] = [:]
        for key in mapping.entries.keys.sorted() {
            guard let entry = mapping.entries[key], !entry.token.isEmpty else { continue }
            // The regex only runs on a replacement that could be a token at
            // all, so a document full of pseudonyms does not pay for it.
            let braced = entry.token.hasPrefix("{") && entry.token.hasSuffix("}")
            let isToken = braced && TokenGrammar.isPlaceholderShaped(entry.token)
            guard isToken == (mapping.style == .token) else { continue }
            for surface in [entry.surfaceText, entry.value] + entry.aliases
            where !surface.isEmpty && map[surface] == nil {
                map[surface] = entry.token
            }
        }
        return map
    }

    // MARK: - Resolving

    /// Where a selection in the redacted text takes its characters from.
    ///
    /// A selection that touches a replacement resolves to `.replacement` even
    /// when most of it is ordinary text: the part that is not the document's
    /// own text is the part that matters, and a value spelled half by the
    /// document and half by a stand-in is not a value the document holds.
    public func resolve(selection: NSRange) -> Resolution {
        guard selection.location != NSNotFound,
              selection.location >= 0,
              selection.length > 0,
              NSMaxRange(selection) <= redactedLength else {
            return .undecidable
        }
        if runs.contains(where: { $0.origin == .replacement && intersects($0.redacted, selection) }) {
            return .replacement
        }
        for run in runs where run.origin == .carriedThrough && contains(run.redacted, selection) {
            let offset = selection.location - run.redacted.location
            return .carriedThrough(
                NSRange(location: run.original.location + offset, length: selection.length)
            )
        }
        // Unreachable for a pairing built above, whose runs tile the text:
        // a selection touching no replacement lies inside one carried-through
        // run. Reached only if that invariant is ever broken, and the answer
        // then has to be a refusal, never an allow.
        return .undecidable
    }

    private func intersects(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        lhs.location < NSMaxRange(rhs) && rhs.location < NSMaxRange(lhs)
    }

    private func contains(_ outer: NSRange, _ inner: NSRange) -> Bool {
        outer.location <= inner.location && NSMaxRange(inner) <= NSMaxRange(outer)
    }
}
