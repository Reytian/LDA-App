//
//  RestorePreviewSheet.swift
//  LDAUI
//
//  Restore shows the document before it writes it.
//
//  The old order was resolveMapping, then NSSavePanel, then write, then
//  report. So the destination was chosen before the reader had seen a single
//  character of the result, the write was unconditional, and every warning the
//  report carries (an unmatched placeholder, one damaged by editing, a masked
//  form nobody owns) arrived only after the file was on disk. The data a
//  preview needs existed the whole time; it was simply reported too late.
//
//  The new order is resolveMapping, restorePreview, this sheet, and only on
//  approval the save panel and the write. Cancel writes nothing.
//
//  Two controls live here. The narrow amendment field, for the real "a name in
//  my mapping is wrong" case, whose policy and reasoning are in
//  RestorePreviewModel. And the output format picker, which is the first time
//  the Markdown-to-Word restore has been reachable without retyping an
//  extension in the save dialog.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import SwiftUI
import LDACore

// MARK: - The pending restore

/// One restore waiting for the reader's approval.
///
/// Identifiable so `.sheet(item:)` presents it, which also means a second
/// restore started while one is pending replaces it rather than stacking.
struct PendingRestore: Identifiable {
    let id = UUID()
    /// The edited redacted file that came back.
    let file: URL
    /// The mapping that opened it, before any amendment.
    let mapping: Mapping
    /// Which key opened it, for the result sentence afterwards.
    let keySource: RestoreResultPresentation.KeySource
    /// What the restore would produce, computed without writing.
    let preview: RestorePreview

    /// The file's fingerprint at the moment `preview` was computed, so the
    /// approval can prove the write reads that same file. See
    /// RestoreSourceGuard.swift.
    let previewedSource: SourceFingerprint

    /// The edit surface's extension, which decides the offered formats.
    var inputExtension: String { file.pathExtension.lowercased() }
}

// MARK: - The sheet

struct RestorePreviewSheet: View {
    @Environment(\.appLanguage) private var language

    let request: PendingRestore

    /// Called with the reader's amendments and chosen format.
    let onApprove: ([String: String], RestoreOutputFormat) -> Void
    let onCancel: () -> Void

    /// Entry key to amended value. Seeded with every amendable entry's
    /// recorded value, so an untouched row is an amendment equal to what is
    /// already there, which RestorePreviewModel treats as a no-op.
    @State private var amendments: [String: String]

    @State private var format: RestoreOutputFormat

    /// The rows the reader may edit, and the warnings they may not. Computed
    /// ONCE from the mapping and the original preview: an amendment changes a
    /// value, and neither the amendable set nor any warning list depends on
    /// values. See RestorePreviewModel.recomputed for why.
    private let amendable: [RestorePreviewModel.AmendableEntry]

    init(
        request: PendingRestore,
        onApprove: @escaping ([String: String], RestoreOutputFormat) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.request = request
        self.onApprove = onApprove
        self.onCancel = onCancel
        let entries = RestorePreviewModel.amendableEntries(
            mapping: request.mapping,
            preview: request.preview
        )
        self.amendable = entries
        self._amendments = State(
            initialValue: Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.value) })
        )
        self._format = State(
            initialValue: RestoreOutputFormat.initialChoice(
                forInputExtension: request.file.pathExtension.lowercased()
            )
        )
    }

    // MARK: Derived copy

    /// The mapping as amended so far. Rebuilt on every change rather than
    /// stored, so there is exactly one definition of what will be written.
    private var amendedMapping: Mapping {
        RestorePreviewModel.amended(
            request.mapping,
            with: amendments,
            preview: request.preview
        )
    }

    /// The restored text as it stands, recomputed purely from the original
    /// source text. No file is read again while the reader types.
    private var livePreview: RestorePreview {
        RestorePreviewModel.recomputed(request.preview, mapping: amendedMapping)
    }

    private var warnings: [String] {
        RestorePreviewPresentation.warnings(request.preview, language: language)
    }

    private var formats: [RestoreOutputFormat] {
        RestoreOutputFormat.choices(forInputExtension: request.inputExtension)
    }

    private var warnsAboutPlainWord: Bool {
        RestoreOutputFormat.warnsAboutPlainWordFormatting(
            inputExtension: request.inputExtension,
            format: format
        )
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: CounselTheme.Space.lg) {
            heading
            summary
            restoredTextPane
            if !amendable.isEmpty { amendmentSection }
            outputSection
            actions
        }
        .padding(CounselTheme.Space.xl)
        .frame(width: 640)
        .background(CounselTheme.paper)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: CounselTheme.Space.xs) {
            L10n.text("Review the restored document")
                .font(CounselTheme.Typography.sectionTitle)
                .foregroundStyle(CounselTheme.textPrimary)
            // Unbroken literals throughout this file: the localization scan
            // takes the FIRST string literal in an L10n call as the catalog
            // key, so a key split with + would ask for its opening fragment.
            L10n.text("Nothing has been written yet. Read the restored text, correct any value that is wrong, then choose where the document goes.")
                .font(CounselTheme.Typography.supporting)
                .foregroundStyle(CounselTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: CounselTheme.Space.xs) {
            Text(verbatim: RestorePreviewPresentation.pendingSentence(
                request.preview.restoredCount,
                language: language
            ))
                .font(CounselTheme.Typography.supporting)
                .foregroundStyle(CounselTheme.textSecondary)
            ForEach(warnings, id: \.self) { warning in
                Label {
                    Text(verbatim: warning)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                    .font(CounselTheme.Typography.supporting)
                    .foregroundStyle(CounselTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = RestorePreviewPresentation.refusalNote(
                request.preview,
                language: language
            ) {
                Text(verbatim: note)
                    .font(CounselTheme.Typography.metadata)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var restoredTextPane: some View {
        ScrollView {
            Text(verbatim: livePreview.restoredText)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(CounselTheme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(CounselTheme.Space.md)
        }
        .frame(height: 220)
        .background(CounselTheme.raised, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(CounselTheme.hairline, lineWidth: 1)
        )
        .l10nAccessibilityLabel("Restored document")
    }

    private var amendmentSection: some View {
        VStack(alignment: .leading, spacing: CounselTheme.Space.sm) {
            L10n.text("Values this restore will write")
                .font(CounselTheme.Typography.supporting)
                .foregroundStyle(CounselTheme.textPrimary)
            L10n.text("Correcting a value here changes the mapping, not the text of the document. The restore writes your correction at every site that placeholder appears.")
                .font(CounselTheme.Typography.metadata)
                .foregroundStyle(CounselTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: CounselTheme.Space.sm) {
                    ForEach(amendable) { entry in
                        amendmentRow(entry)
                    }
                }
                .padding(.vertical, CounselTheme.Space.xs)
            }
            .frame(height: amendable.count > 4 ? 160 : nil)
        }
    }

    private func amendmentRow(_ entry: RestorePreviewModel.AmendableEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: CounselTheme.Space.md) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: entry.replacement)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(CounselTheme.textPrimary)
                Text(verbatim: EntityTypePresentation.localizedName(
                    for: entry.type,
                    language: language
                ))
                    .font(CounselTheme.Typography.metadata)
                    .foregroundStyle(CounselTheme.textSecondary)
            }
            .frame(width: 200, alignment: .leading)
            L10n.textField("Value", text: binding(for: entry))
                .textFieldStyle(.roundedBorder)
                .l10nAccessibilityLabel("Value")
        }
    }

    private func binding(for entry: RestorePreviewModel.AmendableEntry) -> Binding<String> {
        Binding(
            get: { amendments[entry.key] ?? entry.value },
            set: { amendments[entry.key] = $0 }
        )
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: CounselTheme.Space.xs) {
            if formats.count > 1 {
                L10n.picker("Output format", selection: $format) {
                    ForEach(formats, id: \.self) { choice in
                        Text(verbatim: L10n.string(choice.labelKey, language: language))
                            .tag(choice)
                    }
                }
                .pickerStyle(.segmented)
            }
            if warnsAboutPlainWord {
                L10n.text("Word output from Markdown carries plain formatting.")
                    .font(CounselTheme.Typography.metadata)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Cancel and approve.
    ///
    /// Neither button claims Return. The cancel role already answers Escape,
    /// and Return is what a reader presses to commit a correction they just
    /// typed into a value field: making it approve as well would send someone
    /// mid-correction straight on to the save panel. Approval on this sheet is
    /// a click, deliberately.
    private var actions: some View {
        HStack {
            Spacer()
            L10n.button("Cancel", role: .cancel, action: onCancel)
            L10n.button("Choose Where to Save\u{2026}") {
                onApprove(amendments, format)
            }
                .buttonStyle(.borderedProminent)
                .tint(CounselTheme.inkAccentFill)
        }
    }
}
