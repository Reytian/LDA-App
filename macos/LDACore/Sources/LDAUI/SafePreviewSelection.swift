//
//  SafePreviewSelection.swift
//  LDAUI
//
//  Protecting a missed value while looking at Safe Preview.
//
//  Safe Preview shows the REDACTED surface, which is where a lawyer actually
//  notices a leak: the eye stops on the one name that is still readable among
//  the stand-ins. So the text there is selectable. But two very different
//  things are visible in it, and they must never be confused:
//
//  - text carried through from the document, which is either untouched prose
//    or exactly the missed value the user wants to protect, and
//  - a stand-in written in place of a value that is ALREADY protected.
//
//  A selection is reported in the preview's own offsets. Read against the
//  original text those offsets address different characters entirely, so the
//  reported range is paired back through RedactedSurfacePairing before
//  anything is protected. Selecting a stand-in is refused: minting a mapping
//  keyed on a replacement is the defect this project has already paid for
//  twice, and it fails silently at restore rather than loudly here.
//
//  When the surface cannot be paired at all the answer is a refusal too, with
//  a sentence, following SessionSeamVerifier: a pass that could not check
//  must not answer the way a clean pass does.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import LDACore

// MARK: - The surface

/// The Safe Preview text the pane is showing, with the pairing that says
/// which of its offsets are the document's own text.
///
/// The two travel together on purpose. A pairing held next to a different
/// rendering than the one on screen would answer about text nobody selected,
/// so there is no way to store one without the other.
public struct SafePreviewSurface: Equatable {
    /// The redacted text as rendered.
    public let text: String
    /// nil when the rendering could not be paired with the original, which
    /// makes every selection in it undecidable rather than protectable.
    public let pairing: RedactedSurfacePairing?

    /// No preview has been built yet.
    public static let unavailable = SafePreviewSurface(text: "", pairing: nil)

    public init(text: String, pairing: RedactedSurfacePairing?) {
        self.text = text
        self.pairing = pairing
    }
}

// MARK: - Answers

/// Where a Protect action would take its text from, for one reported range.
///
/// The four cases are the whole point: an unpairable surface and a stand-in
/// are their own answers, not a variety of "nothing selected", because each
/// owes the user a different sentence.
public enum ProtectSelectionSource: Equatable {
    /// The document's own text. The range is its place in the ORIGINAL text,
    /// which is the only space the entity list and the mapping speak.
    case original(NSRange)
    /// A stand-in the redaction wrote, carrying the selected characters so
    /// the refusal can quote them.
    case standIn(String)
    /// The surface on screen could not be paired with the original text.
    case undecidable
    /// Nothing usable is selected, or the range is out of bounds.
    case nothing
}

/// The same answer as a menu or a footer button needs it: trimmed text, or
/// the reason there is none.
public enum ProtectableSelection: Equatable {
    /// Trimmed text the document holds, ready to protect.
    case value(String)
    /// A stand-in, trimmed for quoting in the refusal.
    case standIn(String)
    /// The surface could not be paired with the original text.
    case undecidable
    /// Nothing usable is selected.
    case nothing
}

// MARK: - Building the surface

extension ReviewModel {

    /// Build the Safe Preview surface: the protected body text plus its
    /// pairing back to the original.
    ///
    /// Existing token assignments from a client or session handoff are used
    /// as a seed so the preview stays aligned after Export for AI. Before the
    /// first handoff, the tokenizer mints deterministic provisional tokens
    /// using the same rules as export. Rejected entities are omitted from the
    /// span list and therefore remain visible in the preview.
    ///
    /// An unresolved seam yields the explanatory sentence and NO pairing,
    /// because the text shown is then not a rendering of the document at all.
    nonisolated static func redactedPreviewSurface(
        text: String,
        entities: [ReviewEntity],
        style: SubstitutionStyle = .token,
        language: AppLanguage? = nil
    ) -> SafePreviewSurface {
        let accepted = entities.filter(\.accepted)
        var seedEntries: [String: MappingEntry] = [:]

        for entity in accepted {
            guard let token = entity.token else { continue }
            if var existing = seedEntries[token] {
                let surface = entity.span.text
                if surface != existing.value,
                   surface != existing.surfaceText,
                   !existing.aliases.contains(surface) {
                    existing.aliases.append(surface)
                    seedEntries[token] = existing
                }
            } else {
                seedEntries[token] = MappingEntry(
                    token: token,
                    value: entity.span.text,
                    type: entity.span.type,
                    surfaceText: entity.span.text,
                    aliases: []
                )
            }
        }

        let seed = seedEntries.isEmpty
            ? nil
            : Mapping(
                entries: seedEntries,
                createdAtISO8601: "preview",
                sourceFile: "preview",
                style: style
            )

        let spans = accepted.map(\.span)
        let tokenized = Tokenizer.tokenize(
            text: text,
            spans: spans,
            sourceFile: "preview",
            createdAtISO8601: "preview",
            seedMapping: seed,
            style: style
        )
        guard tokenized.unresolvedSeams.isEmpty else {
            return SafePreviewSurface(
                text: L10n.string(
                    "Safe Preview unavailable: restoration could not be verified.",
                    language: language
                ),
                pairing: nil
            )
        }
        return SafePreviewSurface(
            text: tokenized.tokenizedText,
            pairing: RedactedSurfacePairing.pair(
                original: text,
                redacted: tokenized.tokenizedText,
                spans: spans,
                mapping: tokenized.mapping
            )
        )
    }
}
