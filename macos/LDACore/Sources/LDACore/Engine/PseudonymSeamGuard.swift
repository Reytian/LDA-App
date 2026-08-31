//
//  PseudonymSeamGuard.swift
//  LDACore
//
//  Seam-aware uniqueness for the literal substitution styles.
//
//  The pseudonym uniqueness contract is that every literal occurrence of a
//  replacement in the redacted document is a substitution site, which is what
//  lets Restorer's literal scan substitute blindly. The mint-time checks that
//  establish it (used replacements, reserved token literals, the document and
//  its companions) all read the ORIGINAL text. Restore reads the TOKENIZED
//  text, and those two views disagree at every seam: where an emitted
//  replacement meets the document text that follows it, the join can spell a
//  DIFFERENT replacement that was never emitted there.
//
//  Concretely, the Latin company scheme runs Company A .. Company Z and then
//  Company AA, so a document holding twenty seven companies mints Company A
//  first and Company AA last. If the first company is followed in the source
//  by the letter A, the redacted text reads "Company AA", and the
//  longest-match-wins literal scan restores the twenty seventh company over
//  the first one and eats the adjacent letter. Neither replacement occurs in
//  the natural text, so every pre-existing check passes.
//
//  This guard closes that shape in both mint orders:
//  - renderProvisional gives the mint loop the document as the restore scan
//    will see it, so a candidate that the already-emitted seams already spell
//    is rejected (the longer replacement minted after the shorter one).
//  - completesLongerReplacement rejects a candidate that is a strict prefix
//    of a replacement already in use whose remaining tail is exactly what
//    follows one of the candidate's own sites (the shorter replacement minted
//    after the longer one).
//
//  User-supplied replacement text (overrides) reaches the same analysis
//  through overrideSeamConflict, which renders the corpus with the forced
//  text in place and checks that the restore scan still attributes every
//  emission site to the override that produced it. Forced text has no next
//  candidate, so its caller rejects rather than advances.
//
//  Every rule here only ever rejects text that the finite document spells at
//  an actual emission site, so the generator's unbounded candidate sequence
//  always escapes them. A rule keyed on the abstract prefix RELATION between
//  two replacement strings must never be added to the mint path: once the
//  short candidates are spent it blocks every longer one and mint stops
//  terminating.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// Seam-aware checks over the document the literal restore scan will read.
enum PseudonymSeamGuard {

    /// A rendering of the document part way through minting, plus where each
    /// span's emitted piece landed in it.
    struct ProvisionalDocument {
        /// The document as the restore scan will see it: assigned surfaces
        /// rendered as their replacement, everything else verbatim.
        let text: String
        /// One entry per input span, in the order the spans were given. The
        /// range locates that span's piece in `text` in UTF-16 offsets, and
        /// is nil for a span that was skipped as out of order.
        let pieceRanges: [NSRange?]
    }

    /// Render the document as it currently stands.
    ///
    /// A span whose surface text already has a replacement renders as that
    /// replacement; every other span renders as its own surface text, which
    /// is what the original document already held there. The walk mirrors
    /// Tokenizer's emit walk exactly, so the rendering of a fully assigned
    /// span set is byte-identical to the tokenized output.
    ///
    /// - Parameters:
    ///   - text: the original document text.
    ///   - spans: accepted spans, sorted by start and non-overlapping (the
    ///     shape Tokenizer's accept step produces). An out-of-order span is
    ///     skipped and reported as a nil piece range.
    ///   - replacementBySurface: surface text to replacement, for the
    ///     surfaces decided so far.
    static func renderProvisional(
        text: String,
        spans: [Span],
        replacementBySurface: [String: String]
    ) -> ProvisionalDocument {
        // Slicing goes through NSString rather than
        // String.Index(utf16Offset:in:), which walks from the start of the
        // string on every call. The mint loop renders once per surface, so an
        // offset walk per span would make tokenization quadratic in the span
        // count on a document with many entities.
        let nsText = text as NSString
        let utf16Count = nsText.length
        var pieces: [String] = []
        var pieceRanges: [NSRange?] = []
        var cursor = 0
        var renderedLength = 0

        for span in spans {
            guard span.start >= cursor, span.end <= utf16Count else {
                pieceRanges.append(nil)
                continue
            }
            if span.start > cursor {
                let gap = nsText.substring(
                    with: NSRange(location: cursor, length: span.start - cursor)
                )
                pieces.append(gap)
                renderedLength += gap.utf16.count
            }
            let piece = replacementBySurface[span.text]
                ?? nsText.substring(
                    with: NSRange(location: span.start, length: span.end - span.start)
                )
            pieces.append(piece)
            pieceRanges.append(
                NSRange(location: renderedLength, length: piece.utf16.count)
            )
            renderedLength += piece.utf16.count
            cursor = span.end
        }

        if cursor < utf16Count {
            pieces.append(nsText.substring(from: cursor))
        }

        return ProvisionalDocument(text: pieces.joined(), pieceRanges: pieceRanges)
    }

    /// True when emitting `candidate` for `surface` would be swallowed by a
    /// longer replacement already in use.
    ///
    /// The danger is a replacement that starts with the whole candidate: at
    /// the candidate's own site the restore scan sees the candidate followed
    /// by the document text, and if that text opens with the longer
    /// replacement's remaining tail then the longer one matches at the site
    /// and wins. The site would restore to the wrong entity and swallow the
    /// document characters that completed it.
    ///
    /// A replacement that merely CONTAINS the candidate elsewhere is
    /// harmless: at a candidate site the scan starts at the site, so only a
    /// replacement sharing the site's start position can outrank it.
    static func completesLongerReplacement(
        candidate: String,
        surface: String,
        spans: [Span],
        document: ProvisionalDocument,
        replacements: Set<String>
    ) -> Bool {
        let longer = replacements.filter {
            $0.count > candidate.count && $0.hasPrefix(candidate)
        }
        guard !longer.isEmpty else {
            return false
        }

        let rendered = document.text as NSString
        for (index, span) in spans.enumerated() where span.text == surface {
            guard index < document.pieceRanges.count,
                  let range = document.pieceRanges[index] else {
                continue
            }
            // The text that follows this site is the same whether the piece
            // currently holds the surface or the candidate, so the seam can
            // be read off the rendering as it stands.
            let tailStart = range.location + range.length
            for replacement in longer {
                let tail = String(replacement.dropFirst(candidate.count))
                let tailLength = tail.utf16.count
                guard tailStart + tailLength <= rendered.length else {
                    continue
                }
                let following = rendered.substring(
                    with: NSRange(location: tailStart, length: tailLength)
                )
                if following == tail {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Forced text (overrides)

    /// One override emission site the literal restore scan would not
    /// attribute to the override that produced it.
    struct OverrideSeamConflict: Equatable {
        /// The surface whose forced replacement lands on the bad site.
        let surface: String
        /// The forced replacement emitted there.
        let replacement: String
        /// The replacement the restore scan matches over that site instead.
        let other: String
    }

    /// One override emission in the rendered document.
    private struct OverrideSite {
        let range: NSRange
        let surface: String
        let replacement: String
    }

    /// The first override site in `text` that the literal restore scan would
    /// attribute to something other than the override that produced it.
    ///
    /// `text` is first rendered as the redacted document will read it: every
    /// occurrence of an override surface becomes its forced replacement, the
    /// longest surface winning at any shared position, exactly as Tokenizer
    /// emits. That rendering is then scanned with the SAME accept rule the
    /// restorer uses, and every emission site must come back as an exact
    /// match for its own replacement. A site the scan misses, or attributes
    /// to another replacement, is a seam: the document text before or after
    /// the site runs together with the emitted replacement and spells
    /// something else, which then wins the site.
    ///
    /// One condition covers both seam directions, because a match can only
    /// take a site by starting at or before it. Minted pseudonyms answer a
    /// seam by advancing to the next candidate; forced text has no next
    /// candidate, so a caller rejects it instead.
    ///
    /// This reads only what the finite corpus spells at actual emission
    /// sites, never the abstract relation between two replacement strings, so
    /// it must never be wired into the unbounded mint loop: a rule keyed on
    /// that relation blocks every longer candidate once the short ones are
    /// spent, and minting stops terminating.
    static func overrideSeamConflict(
        in text: String,
        overrides: [String: String],
        otherReplacements: Set<String>
    ) -> OverrideSeamConflict? {
        let rendered = renderOverrides(in: text, overrides: overrides)
        guard !rendered.sites.isEmpty else { return nil }

        let scanned = otherReplacements.union(overrides.values)
        let accepted = Restorer.acceptedLiteralMatches(
            in: rendered.text,
            replacements: Array(scanned)
        )
        var acceptedByLocation: [Int: String] = [:]
        for match in accepted {
            acceptedByLocation[match.range.location] = match.replacement
        }

        for site in rendered.sites {
            if acceptedByLocation[site.range.location] == site.replacement {
                continue
            }
            guard let stealer = accepted.first(where: {
                NSIntersectionRange($0.range, site.range).length > 0
            }) else { continue }
            return OverrideSeamConflict(
                surface: site.surface,
                replacement: site.replacement,
                other: stealer.replacement
            )
        }
        return nil
    }

    /// The document with every override surface rendered as its forced
    /// replacement, plus where each emission landed.
    private struct RenderedOverrides {
        let text: String
        let sites: [OverrideSite]
    }

    /// Render every occurrence of every override surface as its replacement.
    ///
    /// Occurrences are found with the restorer's own accept rule, so the
    /// longest surface wins at a shared position and no emitted text is ever
    /// re-scanned. Rendering EVERY occurrence rather than only the detected
    /// spans is deliberate: the caller validates before detection has run,
    /// and a superset of the emission sites can only reject more.
    private static func renderOverrides(
        in text: String,
        overrides: [String: String]
    ) -> RenderedOverrides {
        let matches = Restorer.acceptedLiteralMatches(
            in: text,
            replacements: Array(overrides.keys)
        )
        guard !matches.isEmpty else {
            return RenderedOverrides(text: text, sites: [])
        }

        let nsText = text as NSString
        var pieces: [String] = []
        var sites: [OverrideSite] = []
        var cursor = 0
        var renderedLength = 0

        // The generic matcher searches for whatever strings it is handed, so
        // here match.replacement holds the override SURFACE it found.
        for match in matches {
            guard let replacement = overrides[match.replacement] else { continue }
            if match.range.location > cursor {
                let gap = nsText.substring(
                    with: NSRange(location: cursor, length: match.range.location - cursor)
                )
                pieces.append(gap)
                renderedLength += gap.utf16.count
            }
            pieces.append(replacement)
            sites.append(
                OverrideSite(
                    range: NSRange(location: renderedLength, length: replacement.utf16.count),
                    surface: match.replacement,
                    replacement: replacement
                )
            )
            renderedLength += replacement.utf16.count
            cursor = match.range.location + match.range.length
        }

        if cursor < nsText.length {
            pieces.append(nsText.substring(from: cursor))
        }
        return RenderedOverrides(text: pieces.joined(), sites: sites)
    }
}
