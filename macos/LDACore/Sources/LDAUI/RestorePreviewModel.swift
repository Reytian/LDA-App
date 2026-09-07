//
//  RestorePreviewModel.swift
//  LDAUI
//
//  What the reader may change on the Restore preview sheet, and what they may
//  not. Pure functions, so the policy is testable without presenting a view.
//
//  THE EDITABLE PART IS DELIBERATELY NARROW: the reader may amend the VALUE of
//  an existing mapping entry that this restore will substitute, which is the
//  real "a name in my mapping is wrong" case. They may not type values for
//  orphan tokens, damaged suspect placeholders, or ambiguous sites. Those are
//  shown and explained, and refused.
//
//  Why the mapping and not the text. Editing the OUTPUT TEXT is impossible
//  without re-merging the edits into the DOCX runs, which
//  SessionModel+RestoreFile.swift refuses by design (the fidelity floor is a
//  plain regenerated Word file, never a merge into an original document's
//  runs). Editing the MAPPING is safe because the restore keys entirely on the
//  replacement and never on the value: Restorer.literalRestorePlan builds its
//  replacement-to-value table from the entry tokens, and the token-style scan
//  looks tokens up by name, so changing a value cannot move, split, or
//  duplicate a single site.
//
//  Why the three refused kinds are not expressible as an amendment. An ORPHAN
//  is a token ABSENT from the mapping, so typing a value for it would MINT an
//  entry rather than correct one, and the restore would then write a value
//  nothing ever recorded. A SUSPECT is a DAMAGED placeholder, a shape rather
//  than an entry, so there is no entry whose value could be amended. An
//  AMBIGUOUS site is one whose masked form several entities share; the missing
//  fact there is WHICH entity owns the site, which is not a value at all.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import LDACore

/// The amendment policy for the Restore preview sheet.
enum RestorePreviewModel {

    // MARK: - What may be amended

    /// One mapping entry the reader may correct before the file is written.
    struct AmendableEntry: Identifiable, Equatable {
        /// The entry's KEY in `Mapping.entries`, which is what addresses
        /// exactly one entry. Asterisk-collision entries share a `token`
        /// while their keys stay distinct, so keying on the token would be
        /// ambiguous by construction.
        let key: String
        /// The replacement this document spells, shown so the reader can see
        /// which site they are correcting.
        let replacement: String
        /// The value the restore will write today.
        let value: String
        /// The entity type, for the row's heading.
        let type: EntityType

        var id: String { key }
    }

    /// Why an amendment cannot be accepted.
    ///
    /// An Error so it can be the failure half of a `Result`, but it is never
    /// thrown: a refusal is an answer the sheet renders, not a fault.
    enum AmendmentRefusal: Error, Equatable {
        /// The token is not in the mapping. Accepting a value here would mint
        /// an entry, not correct one.
        case notInMapping
        /// The string is a placeholder shape damaged by editing, not an
        /// entry, so it has no value to amend.
        case damagedPlaceholder
        /// Several entities share this replacement, so the missing fact is
        /// which entity owns the site, not what its value should read.
        case ambiguousSite
        /// The entry exists but this document does not spell its replacement,
        /// so amending it would change nothing that gets written.
        case notInThisDocument
        /// An empty value would erase the text at every site the replacement
        /// appears. Restoring to nothing is a deletion, not a correction.
        case emptyValue
    }

    /// Whether `key` may be amended, and why not when it may not.
    ///
    /// Order matters: the two "this is not an entry at all" cases are decided
    /// before the mapping is consulted, so a damaged placeholder is reported
    /// as damaged rather than as merely absent.
    static func refusal(
        forAmending key: String,
        mapping: Mapping,
        preview: RestorePreview
    ) -> AmendmentRefusal? {
        if preview.suspectPlaceholders.contains(key) { return .damagedPlaceholder }
        guard let entry = mapping.entries[key] else { return .notInMapping }
        if preview.ambiguousReplacements.contains(entry.token) { return .ambiguousSite }
        guard !entry.token.isEmpty, preview.sourceText.contains(entry.token) else {
            return .notInThisDocument
        }
        return nil
    }

    /// Every entry this restore will substitute, in a stable order.
    ///
    /// Sorted by replacement and then by key: `Mapping.entries` is a
    /// Dictionary, so without this the sheet's rows would shuffle between
    /// runs and the reader would lose their place.
    static func amendableEntries(
        mapping: Mapping,
        preview: RestorePreview
    ) -> [AmendableEntry] {
        mapping.entries
            .filter { refusal(forAmending: $0.key, mapping: mapping, preview: preview) == nil }
            .map { key, entry in
                AmendableEntry(
                    key: key,
                    replacement: entry.token,
                    value: entry.value,
                    type: entry.type
                )
            }
            .sorted { ($0.replacement, $0.key) < ($1.replacement, $1.key) }
    }

    // MARK: - Applying an amendment

    /// A copy of `mapping` with one existing entry's value replaced, or the
    /// reason the amendment was refused.
    ///
    /// `Mapping` is a value type, so `var amended = mapping` is a copy: the
    /// caller's mapping is never mutated and the original stays available for
    /// comparison.
    static func amending(
        _ mapping: Mapping,
        key: String,
        to value: String,
        preview: RestorePreview
    ) -> Result<Mapping, AmendmentRefusal> {
        if value.isEmpty { return .failure(.emptyValue) }
        if let refusal = refusal(forAmending: key, mapping: mapping, preview: preview) {
            return .failure(refusal)
        }
        var amended = mapping
        amended.entries[key]?.value = value
        return .success(amended)
    }

    /// The mapping the write should use, given every amendment the sheet
    /// collected.
    ///
    /// Each amendment is checked against the ORIGINAL preview, so an accepted
    /// one cannot carry a refused one in behind it, and a refused amendment
    /// leaves the mapping exactly as it was rather than failing the whole
    /// restore. An amendment equal to the recorded value is a no-op.
    static func amended(
        _ mapping: Mapping,
        with amendments: [String: String],
        preview: RestorePreview
    ) -> Mapping {
        amendments
            .sorted { $0.key < $1.key }
            .reduce(mapping) { partial, amendment in
                switch amending(
                    partial,
                    key: amendment.key,
                    to: amendment.value,
                    preview: preview
                ) {
                case .success(let next): return next
                case .failure: return partial
                }
            }
    }

    // MARK: - Re-previewing without touching the file

    /// The preview again, over the SAME source text, with an amended mapping.
    ///
    /// Pure: no file is read a second time, so the sheet can update as the
    /// reader types. Faithful for the same reason the original preview is:
    /// both the write path and this call hand the identical source text to the
    /// identical `Restorer.restore`.
    ///
    /// Only the restored TEXT can differ. Which entries are amendable, how
    /// many sites will be substituted, and every warning list are functions of
    /// the replacements and the source text, neither of which an amendment
    /// touches, so the sheet's lists are computed once and stay put while the
    /// text follows the typing.
    static func recomputed(_ preview: RestorePreview, mapping: Mapping) -> RestorePreview {
        let report = Restorer.restore(text: preview.sourceText, mapping: mapping)
        return RestorePreview(
            sourceText: preview.sourceText,
            restoredText: report.text,
            restoredCount: report.restoredCount,
            orphanTokens: report.orphanTokens,
            suspectPlaceholders: report.suspectPlaceholders,
            ambiguousReplacements: report.ambiguousReplacements
        )
    }
}

// MARK: - The approval step

/// What happens after the reader approves the preview, with its two side
/// effects handed in: where the file goes, and how it is written.
///
/// The shell passes an NSSavePanel and SessionModel.restoreFile. A test passes
/// closures. Without this seam the two claims that matter most about the new
/// order, that cancelling writes NOTHING and that approving writes exactly one
/// file at the chosen path, could only be checked by clicking.
enum RestoreApproval {

    /// How the approval step ended.
    enum Outcome {
        /// The reader backed out at the save panel. Nothing was written, and
        /// the amendments are still on the sheet.
        case cancelled
        /// The document was written, and this is its report.
        case written(RestoreReport)
        /// The write was attempted and failed.
        case failed(Error)
    }

    /// Apply the amendments, ask for a destination, and write there.
    ///
    /// The destination is asked for LAST, which is the whole point of the new
    /// order: the reader has already seen what they are saving, so the save
    /// panel is the final step rather than the first.
    ///
    /// - Parameter previewedSource: the fingerprint of `file` taken when
    ///   `preview` was computed. Required, not optional: the whole claim this
    ///   step makes is that the written document is the previewed one, and a
    ///   caller that could omit the evidence could omit the claim. It is
    ///   checked immediately before the write, after the save panel, so the
    ///   modal's own duration is inside the window that is checked. See
    ///   RestoreSourceGuard.swift.
    static func run(
        file: URL,
        mapping: Mapping,
        preview: RestorePreview,
        previewedSource: SourceFingerprint,
        amendments: [String: String],
        format: RestoreOutputFormat,
        chooseOutput: (_ suggestedName: String, _ format: RestoreOutputFormat) -> URL?,
        write: (_ file: URL, _ mapping: Mapping, _ output: URL) throws -> RestoreReport
    ) -> Outcome {
        let amendedMapping = RestorePreviewModel.amended(
            mapping,
            with: amendments,
            preview: preview
        )
        guard let output = chooseOutput(format.suggestedName(for: file), format) else {
            return .cancelled
        }
        do {
            try RestoreSourceGuard.requireUnchanged(file, matches: previewedSource)
            return .written(try write(file, amendedMapping, output))
        } catch {
            return .failed(error)
        }
    }
}
