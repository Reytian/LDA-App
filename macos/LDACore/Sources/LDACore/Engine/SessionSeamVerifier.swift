//
//  SessionSeamVerifier.swift
//  LDACore
//
//  Post-emit seam verification for a whole session assignment.
//
//  PseudonymSeamGuard closes the seam shapes it can see while a document is
//  being tokenized. It cannot see across documents, because SessionTokenizer
//  folds one document at a time and two things happen behind the guard's
//  back:
//
//  - A surface first seen in document 1 is REUSED in document 2 straight out
//    of the seed mapping. Reuse skips the mint loop, so document 2's seams
//    are never examined. Where the reused replacement meets document 2's own
//    following text, the join can spell another replacement of the shared
//    mapping.
//  - A pseudonym minted while document 5 is folded can retroactively give a
//    meaning to a seam that document 1 already emitted. The guard cleared
//    that seam against the replacements in use AT THE TIME, and the set kept
//    growing afterwards.
//
//  Neither can be fixed by reminting inside the document where it shows up:
//  the surface has to keep ONE identity across every document of the session.
//  So this pass runs on the finished assignment, over the text the restore
//  scan will actually read, and reports what the scan would get wrong. The
//  caller's repair is to ban the offending pairing and fold the session
//  again, which changes that surface everywhere at once.
//
//  The invariant checked is the one the literal styles rest on: the accepted
//  match list of a tokenized document must be EXACTLY its list of emitted
//  pieces. Any other accepted match is either a longer replacement swallowing
//  a site (the prefix shape) or a replacement spelled across a piece boundary
//  (the adjacency shape), and both restore the wrong entity.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// Checks a committed session assignment against the redacted text.
enum SessionSeamVerifier {

#if DEBUG
    /// Debug-only forcing of the "could not verify" outcome, so the give-up
    /// path can be driven end to end. The precondition below holds in every
    /// real run, which is exactly why it cannot be reached by a fixture.
    ///
    /// Compiled out of release builds and lock guarded; see TestSeam.
    static let unverifiableSeam = TestSeam<Bool>()
#endif

    /// What one document's verification came to.
    ///
    /// The two fields are not redundant, and collapsing them back into a bare
    /// violation list is the defect this type exists to prevent: an empty
    /// `violations` means "checked, nothing wrong" ONLY when `couldNotVerify`
    /// is false. When it is true the pass never looked, and the caller must
    /// warn rather than read the empty list as an all clear.
    struct Report: Equatable {
        /// Positions where the restore scan disagrees with what was emitted.
        var violations: [Violation]
        /// True when the pass could not establish its own precondition, so
        /// nothing about this document was actually checked.
        var couldNotVerify: Bool

        static let verifiedClean = Report(violations: [], couldNotVerify: false)
        static let unverifiable = Report(violations: [], couldNotVerify: true)
    }

    /// One position where the literal restore scan disagrees with what
    /// tokenization emitted.
    struct Violation: Equatable {
        /// Index of the document in the session, for reporting.
        let documentIndex: Int
        /// The replacement the scan matched at the offending position. This
        /// is the string to remint: it is the one the document text spells
        /// somewhere it was never emitted, and the surface that owns it has
        /// an unbounded supply of other candidates to move to.
        let matchedReplacement: String
        /// The replacement legitimately emitted at the position the bad match
        /// starts on or runs into, when there is one. Reported so the caller
        /// has a second surface to fall back on, and for diagnostics.
        let shadowedReplacement: String?
    }

    /// Verify one document of the session.
    ///
    /// - Parameters:
    ///   - documentIndex: position in the session, carried into violations.
    ///   - tokenizedText: the document as tokenization emitted it.
    ///   - originalText: the document before tokenization.
    ///   - acceptedSpans: the spans the emit walk used, in emit order.
    ///   - replacementBySurface: the assignment the emit walk used.
    ///   - replacements: every replacement of the shared mapping, which is
    ///     exactly what the restore scan will search for.
    /// - Returns: the disagreements, earliest offending position first, or a
    ///   report marked `couldNotVerify` when the pass could not check at all.
    static func report(
        documentIndex: Int,
        tokenizedText: String,
        originalText: String,
        acceptedSpans: [Span],
        replacementBySurface: [String: String],
        replacements: [String]
    ) -> Report {
#if DEBUG
        if unverifiableSeam.value == true {
            return .unverifiable
        }
#endif
        // Re-render to recover where each emitted piece landed. A fully
        // assigned rendering is byte-identical to the tokenized output (that
        // is pinned by RestorerPrefixAdjacencyTests), so the equality below
        // holds in every run we know of.
        //
        // If it ever does not, the piece offsets are fiction and every
        // comparison below would be guesswork. The pass then reports that it
        // could not check, which is NOT the same as reporting nothing wrong:
        // an empty violation list is what a clean session returns and what
        // lets the redacted text out of the door, so answering "all clear"
        // here would turn the one defence against a literal-restore seam into
        // a silent no-op precisely when its own assumptions have broken.
        let rendered = PseudonymSeamGuard.renderProvisional(
            text: originalText,
            spans: acceptedSpans,
            replacementBySurface: replacementBySurface
        )
        guard rendered.text == tokenizedText else {
            return .unverifiable
        }

        // The emitted pieces, keyed by where they start. A span whose surface
        // had no assignment emitted its own text and is not a substitution
        // site, so it is deliberately absent.
        var emitted: [Int: Piece] = [:]
        for (index, span) in acceptedSpans.enumerated() {
            guard index < rendered.pieceRanges.count,
                  let range = rendered.pieceRanges[index],
                  let replacement = replacementBySurface[span.text],
                  !replacement.isEmpty else {
                continue
            }
            emitted[range.location] = Piece(range: range, replacement: replacement)
        }
        let inOrder = emitted.values.sorted { $0.range.location < $1.range.location }

        let accepted = Restorer.acceptedLiteralMatches(
            in: tokenizedText,
            replacements: replacements
        )

        var found: [Violation] = []
        for match in accepted {
            if let piece = emitted[match.range.location],
               piece.range.length == match.range.length,
               piece.replacement == match.replacement {
                // The scan will restore this site to the entity that was
                // substituted here. Agreement.
                continue
            }
            found.append(
                Violation(
                    documentIndex: documentIndex,
                    matchedReplacement: match.replacement,
                    shadowedReplacement: firstOverlapping(with: match.range, in: inOrder)
                )
            )
        }
        return Report(violations: found, couldNotVerify: false)
    }

    /// One replacement as tokenization emitted it, and where it landed.
    private struct Piece {
        let range: NSRange
        let replacement: String
    }

    /// The earliest emitted piece the bad match intersects.
    ///
    /// In the prefix shape that is the piece the match starts on; in the
    /// adjacency shape it is the piece the match runs into from the text
    /// before it. A match that overlaps nothing emitted has no shadowed
    /// replacement, which happens when the redacted text spells a
    /// replacement out of untouched document text on both sides.
    private static func firstOverlapping(
        with range: NSRange,
        in pieces: [Piece]
    ) -> String? {
        let end = range.location + range.length
        for piece in pieces {
            if piece.range.location >= end {
                break
            }
            if piece.range.location + piece.range.length > range.location {
                return piece.replacement
            }
        }
        return nil
    }
}
