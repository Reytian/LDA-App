//
//  UnlocatedValuesPopover.swift
//  LDAUI
//
//  The values an AI pass found in the document and could not remove, listed
//  beside the warning that counts them, each with a Protect button.
//
//  Why a list. The warning used to give only a number ("AI detected 2 values
//  it could not locate exactly in this document"), and the values stayed in
//  the document with nothing saying which ones. LDA V4 reports each value as
//  an exact slice of the text, so the usual cause is an edge the locator
//  refuses: a name run into a neighbouring word or a footnote digit (see
//  EntityLocator.isWordBoundary). A value is listed too when its other
//  mentions were redacted and one more is written that way. Anchoring itself
//  is deliberately unchanged, because LDA V4 was evaluated with that guard in
//  place.
//
//  Protect redacts a value at the places it was refused for that reason
//  (UnlocatedValuePlacement.runIns), with its notice and Undo, and nowhere
//  else. It does not search the document by value: a value searched for by
//  its letters is found inside other words too ("li" in "compliance"), and a
//  value searched for literally misses its wrapped repeats.
//
//  Nothing here redacts on its own. A value becomes an entity only when the
//  user presses Protect.
//
//  The values are document contents. They are rendered here and nowhere
//  else: never logged, never in telemetry, never in a workspace or report.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import SwiftUI
import LDACore

/// The list behind the review summary's "Show N values" control.
struct UnlocatedValuesPopover: View {
    @ObservedObject var model: ReviewModel

    /// The window's undo manager, so a protection lands in Edit > Undo.
    let undoManager: UndoManager?

    /// Past this many rows the list scrolls instead of growing.
    private static let rowsBeforeScrolling = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            L10n.text("Values still in the document")
                .font(.headline)
                .foregroundStyle(CounselTheme.textPrimary)

            L10n.text("The AI found these values in the document but could not redact them in some places, usually because a letter or digit runs into them there. Protect redacts each one where it is written that way.")
                .font(.callout)
                .foregroundStyle(CounselTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            if model.aiUnlocatedPlacements.count > Self.rowsBeforeScrolling {
                ScrollView {
                    rows
                }
                .frame(height: 260)
            } else {
                rows
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(model.aiUnlocatedPlacements.enumerated()), id: \.offset) { _, placement in
                row(placement)
            }
        }
    }

    /// One value: its hue dot, the value as the model reported it (selectable,
    /// so it can be copied into a search), its kind, and what can be done.
    private func row(_ placement: UnlocatedValuePlacement) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Circle()
                .fill(CounselTheme.color(for: placement.value.type))
                .frame(width: 8, height: 8)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: placement.value.value)
                    .font(.system(.callout, design: .serif))
                    .foregroundStyle(CounselTheme.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                L10n.text(EntityTypePresentation.key(for: placement.value.type))
                    .font(.caption)
                    .foregroundStyle(CounselTheme.textSecondary)
            }

            Spacer(minLength: 8)

            action(for: placement)
        }
    }

    /// Protect while a run-in place is exposed, a quiet confirmation once each
    /// one is covered, and a pointer to the document when there is no run-in
    /// place to protect.
    @ViewBuilder
    private func action(for placement: UnlocatedValuePlacement) -> some View {
        switch model.protection(of: placement) {
        case .protected:
            Label {
                L10n.text("Protected")
            } icon: {
                Image(systemName: "checkmark.shield")
            }
            .font(.caption)
            .foregroundStyle(CounselTheme.textSecondary)
            .fixedSize()
        case .exposed:
            Button {
                model.protectRunIns(of: placement, undoManager: undoManager)
            } label: {
                L10n.text("Protect")
            }
            .controlSize(.small)
            .fixedSize()
            .l10nHelp("Redact this value everywhere a letter or digit runs into it. Undo is in the Edit menu.")
            .l10nAccessibilityLabel("Protect “%@”", placement.value.value)
        case .insideOtherWords:
            L10n.text("Inside other words")
                .font(.caption)
                .foregroundStyle(CounselTheme.textSecondary)
                .fixedSize()
                .l10nHelp("LDA finds this value only inside longer words, so it leaves those words alone. If the value is a name there, select it in the document and use Protect.")
        case .writtenDifferently:
            L10n.text("Written differently")
                .font(.caption)
                .foregroundStyle(CounselTheme.textSecondary)
                .fixedSize()
                .l10nHelp("The document writes this value differently. Select it there, one line at a time, then use Protect.")
        }
    }
}
