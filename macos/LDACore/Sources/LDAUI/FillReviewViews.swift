//
//  FillReviewViews.swift
//  LDAUI
//
//  Fill-review subviews for FillShell. Split from FillShellViews.swift to
//  respect the 800-line file cap.
//
//  Contains:
//  - FillReviewBody: the NavigationSplitView for the fill review stage.
//  - BlankSidebar: the blank review list with keyboard bindings.
//  - BlankRow: one blank row with status icon, label, value, and picker popover.
//  - FieldPickerPopover: popover for repointing a blank to a different field.
//  - BlankDocumentPane: full-text DOCX view with blank highlights; PDF placeholder.
//  - FillReportPane: done-state report (filled count, skipped, manual widgets).
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import AppKit
import SwiftUI
import LDACore

// MARK: - FillReviewBody

/// The NavigationSplitView for the fill review stage: a blank sidebar on the
/// leading side and the document / report pane in the detail.
struct FillReviewBody: View {
    @ObservedObject var model: FillModel
    @Binding var pickerOpenForBlankID: UUID?
    @Binding var applyMessage: String?

    var body: some View {
        NavigationSplitView {
            BlankSidebar(
                model: model,
                pickerOpenForBlankID: $pickerOpenForBlankID
            )
            .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        } detail: {
            VStack(spacing: 0) {
                detailContent
            }
            .background(CounselTheme.paper)
        }
        .background(CounselTheme.appSurface)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch model.stage {
        case .done(let report):
            FillReportPane(
                report: report,
                manualWidgetNames: model.manualWidgetNames
            )
        case .reviewing:
            BlankDocumentPane(model: model)
        case .planning:
            planningPlaceholder
        case .failed:
            failedPlaceholder
        default:
            Spacer()
        }
    }

    private var planningPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.regular)
            L10n.text("Planning fill")
                .font(.callout)
                .foregroundStyle(CounselTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var failedPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(CounselTheme.danger)
            if case .failed(let detail) = model.stage {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(CounselTheme.danger)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - BlankSidebar

/// The blank review list. Each row shows the blank label (or context preview),
/// the proposed value, and a status icon. The selected blank is emphasized.
///
/// Keyboard navigation (mode-aware commands, option b):
/// Cmd+J / Cmd+Shift+J advance or retreat through blanks. These shortcuts are
/// shared with the Anonymize review loop; LDAApp dispatches them to FillModel
/// when Fill mode is active. Space and Return accept the selected blank; Delete
/// rejects it. These local .onKeyPress bindings fire only when the sidebar list
/// has focus and do not conflict with the global CommandMenu shortcuts.
struct BlankSidebar: View {
    @ObservedObject var model: FillModel
    @Binding var pickerOpenForBlankID: UUID?

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        List(selection: $model.selectedBlankID) {
            if model.blanks.isEmpty {
                blankEmptyState
            } else {
                ForEach(model.blanks) { blank in
                    BlankRow(
                        blank: blank,
                        proposedFieldName: proposedFieldName(for: blank),
                        isSelected: model.selectedBlankID == blank.id,
                        pickerOpenForBlankID: $pickerOpenForBlankID,
                        model: model
                    )
                    .tag(blank.id)
                    .listRowBackground(rowBackground(for: blank.id))
                }
            }
        }
        .listStyle(.sidebar)
        .tint(CounselTheme.inkAccent)
        .scrollContentBackground(.hidden)
        .background(CounselTheme.appSurface)
        // Keyboard bindings: space and return accept the selected blank.
        .onKeyPress(.space) {
            guard let id = model.selectedBlankID else { return .ignored }
            model.acceptBlank(id: id)
            return .handled
        }
        .onKeyPress(.return) {
            guard let id = model.selectedBlankID else { return .ignored }
            model.acceptBlank(id: id)
            return .handled
        }
        // Delete key rejects.
        .onKeyPress(.delete) {
            guard let id = model.selectedBlankID else { return .ignored }
            model.rejectBlank(id: id)
            return .handled
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            sidebarFooter
        }
    }

    private var blankEmptyState: some View {
        L10n.text("No blanks detected")
            .font(.callout)
            .foregroundStyle(CounselTheme.textSecondary)
            .padding(12)
    }

    private var sidebarFooter: some View {
        HStack(spacing: 6) {
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(CounselTheme.textSecondary)
                    .frame(width: 30, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .l10nHelp("Settings")
            .l10nAccessibilityLabel("Settings")

            Spacer(minLength: 0)

            if !model.blanks.isEmpty {
                let confirmedCount = model.blanks.filter { $0.status == .confirmed }.count
                L10n.text("%lld/%lld", confirmedCount, model.blanks.count)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(CounselTheme.textSecondary)
                    .padding(.trailing, 4)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(CounselTheme.appSurface)
        .overlay(alignment: .top) {
            Rectangle().fill(CounselTheme.hairline).frame(height: 1)
        }
    }

    private func rowBackground(for id: UUID) -> Color {
        model.selectedBlankID == id ? CounselTheme.inkAccent.opacity(0.10) : Color.clear
    }

    private func proposedFieldName(for blank: Blank) -> String? {
        guard let fid = blank.proposedFieldID else { return nil }
        guard let key = model.profile?.fields.first(where: { $0.id == fid })?.key else {
            return nil
        }
        return ProfileFieldPresentation.localizedName(for: key)
    }
}

// MARK: - BlankRow

/// One blank row: label / context preview, proposed value (with verbatim
/// profile value when an adaptation was applied), and status icon. The field
/// picker popover is attached to this row and opens when pickerOpenForBlankID
/// matches this blank's id.
struct BlankRow: View {
    let blank: Blank
    let proposedFieldName: String?
    let isSelected: Bool
    @Binding var pickerOpenForBlankID: UUID?
    @ObservedObject var model: FillModel

    /// True when the picker popover is showing for this blank.
    @State private var isPickerShowing = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            statusIcon
                .frame(width: 16, height: 16)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 2 }

            VStack(alignment: .leading, spacing: 2) {
                labelLine
                valueLine
            }

            Spacer(minLength: 4)
        }
        .padding(.vertical, 3)
        .opacity(blank.status == .rejected ? 0.45 : 1.0)
        // Picker popover attached here.
        .popover(isPresented: $isPickerShowing, arrowEdge: .trailing) {
            FieldPickerPopover(
                blank: blank,
                model: model,
                onDismiss: {
                    isPickerShowing = false
                    model.clearPickerRequest()
                }
            )
        }
        // Watch for model-driven picker requests for this blank.
        .onChange(of: pickerOpenForBlankID) { _, id in
            if id == blank.id {
                isPickerShowing = true
            }
        }
        .contextMenu {
            L10n.button("Accept") { model.acceptBlank(id: blank.id) }
            L10n.button("Reject") { model.rejectBlank(id: blank.id) }
            L10n.button("Choose Field") {
                pickerOpenForBlankID = blank.id
                isPickerShowing = true
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch blank.status {
        case .proposed:
            Image(systemName: "circle.dotted")
                .foregroundStyle(CounselTheme.textSecondary)
        case .confirmed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(CounselTheme.inkAccent)
        case .rejected:
            Image(systemName: "xmark.circle")
                .foregroundStyle(CounselTheme.danger)
        case .unmatched:
            Image(systemName: "questionmark.circle")
                .foregroundStyle(CounselTheme.textSecondary.opacity(0.5))
        }
    }

    private var labelLine: some View {
        Text(verbatim: displayLabel)
            .font(.system(.callout, design: .serif))
            .foregroundStyle(CounselTheme.textPrimary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    @ViewBuilder
    private var valueLine: some View {
        if let proposed = blank.proposedValue {
            let verbatim = verbatimProfileValue
            if let verbatim, verbatim != proposed {
                // Format-adapted: show adapted value BESIDE the verbatim profile value.
                HStack(spacing: 6) {
                    Text(proposed)
                        .font(.caption.monospaced())
                        .foregroundStyle(CounselTheme.inkAccent)
                        .lineLimit(1)
                    L10n.text("(from %@)", verbatim)
                        .font(.caption2)
                        .foregroundStyle(CounselTheme.textSecondary)
                        .lineLimit(1)
                }
            } else {
                Text(proposed)
                    .font(.caption.monospaced())
                    .foregroundStyle(
                        blank.status == .confirmed
                            ? CounselTheme.inkAccent
                            : CounselTheme.textSecondary
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else {
            L10n.text(
                blank.status == .unmatched ? "No match" : "Tap to choose"
            )
                .font(.caption)
                .foregroundStyle(CounselTheme.textSecondary.opacity(0.7))
        }
    }

    private var displayLabel: String {
        let raw = blank.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty { return raw }
        let ctx = blank.context.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = ctx.prefix(40)
        return preview.isEmpty ? L10n.string("(blank)") : "\u{201C}\(preview)\u{201D}"
    }

    /// The verbatim value from the profile field this blank points at. Used to
    /// detect format adaptations (proposed != verbatim).
    private var verbatimProfileValue: String? {
        guard let fid = blank.proposedFieldID else { return nil }
        return model.profile?.fields.first(where: { $0.id == fid })?.value
    }
}

// MARK: - FieldPickerPopover

/// A popover listing all profile fields so the user can repoint a blank to a
/// different field. Opened automatically when pickerRequestID fires (blank has
/// nil proposedValue), or manually from the context menu.
struct FieldPickerPopover: View {
    let blank: Blank
    @ObservedObject var model: FillModel
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            L10n.text("Choose a field")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)

            Divider()

            if let profile = model.profile, !profile.fields.isEmpty {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(profile.fields) { field in
                            Button {
                                model.repointBlank(id: blank.id, fieldID: field.id)
                                onDismiss()
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(verbatim: ProfileFieldPresentation.localizedName(
                                            for: field.key
                                        ))
                                            .font(.callout)
                                            .foregroundStyle(CounselTheme.textPrimary)
                                        Text(field.value)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(CounselTheme.textSecondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer(minLength: 0)
                                    if blank.proposedFieldID == field.id {
                                        Image(systemName: "checkmark")
                                            .font(.caption)
                                            .foregroundStyle(CounselTheme.inkAccent)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 280)
            } else {
                L10n.text("No profile fields available")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .padding(16)
            }

            Divider()

            HStack {
                Spacer()
                L10n.button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
        }
        .frame(width: 320)
        .background(CounselTheme.raised)
    }
}

// MARK: - BlankDocumentPane

/// The document detail view for the fill review stage.
///
/// DOCX path: when FillModel.targetText is non-nil, renders the full imported
/// document text as a serif column (matching DocumentPane's visual styling)
/// with every blank's textSpan highlighted by status tint and the selected
/// blank emphasized with a stronger fill. UTF-16 offsets from BlankLocation
/// are converted to String indices via the same pattern used in DocumentPane.
/// Falls back to a context-list view when targetText is nil (import failed or
/// not yet available).
///
/// PDF path: shows a placeholder instructing the user to work in the sidebar
/// (full PDF rendering is a future feature).
///
/// Tint constants mirror DocumentPane.Style:
///   proposed / unmatched blanks: inkAccent at 0.10 opacity (candidate tint)
///   confirmed blanks: inkAccent at 0.20 opacity (sealed fill)
///   rejected blanks: no highlight
///   SELECTED blank: inkAccent at 0.30 opacity (emphasis over the status tint)
struct BlankDocumentPane: View {
    @ObservedObject var model: FillModel

    // MARK: Cached attributed strings
    //
    // Two-level cache mirroring DocumentPane's baseDocument pattern:
    //
    //   baseDocument  -- plain AttributedString built from targetText only;
    //                    rebuilt when targetText changes (expensive: allocates a
    //                    new AttributedString from the full document text).
    //
    //   styledFull    -- baseDocument copy with blank highlight spans applied;
    //                    rebuilt when blanks or selection changes, or when
    //                    baseDocument is refreshed.
    //
    // This avoids reconstructing the full attributed string from raw text on
    // every blank status flip or selection movement. For a 20,000-character
    // document with 30 blanks, rebuilding from text costs ~100 us while
    // copying the cached base and applying highlights costs ~10 us.

    /// The plain full-text AttributedString with no highlights. Rebuilt only
    /// when targetText changes.
    @State private var baseDocument = AttributedString("")

    /// The highlighted AttributedString rendered to screen. Rebuilt by applying
    /// blank highlights over a copy of baseDocument.
    @State private var styledFull = AttributedString("")

    // MARK: Body

    var body: some View {
        Group {
            if let url = model.targetURL, url.pathExtension.lowercased() == "pdf" {
                pdfV1Placeholder
            } else if model.targetText != nil {
                fullTextDocxView
            } else {
                fallbackContextList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Rebuild base only when the raw text changes (expensive allocation).
        .onChange(of: model.targetText) { _, _ in
            rebuildBase()
            applyHighlights()
        }
        // Apply highlights over the cached base when blanks or selection change.
        .onChange(of: model.blanks) { _, _ in applyHighlights() }
        .onChange(of: model.selectedBlankID) { _, _ in applyHighlights() }
        .onAppear {
            rebuildBase()
            applyHighlights()
        }
    }

    // MARK: - Full-text DOCX view

    private var fullTextDocxView: some View {
        ScrollView(.vertical) {
            Text(styledFull)
                .font(.system(.body, design: .serif))
                .foregroundStyle(CounselTheme.textPrimary)
                .textSelection(.enabled)
                .lineSpacing(6)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 48)
                .padding(.vertical, 56)
        }
        .background(CounselTheme.paper)
    }

    // MARK: - Cache rebuild helpers

    /// Rebuild baseDocument from targetText. Call only when targetText changes.
    private func rebuildBase() {
        guard let text = model.targetText else {
            baseDocument = AttributedString("")
            return
        }
        baseDocument = AttributedString(text)
    }

    /// Apply blank textSpan highlights over a copy of baseDocument and store
    /// the result in styledFull. Call whenever blanks or selection change (or
    /// immediately after rebuildBase when text changes).
    ///
    /// Only .textSpan locations are rendered; .acroFormField blanks have no
    /// text position and are skipped in this view. Highlights are applied
    /// back-to-front so UTF-16 index math stays valid.
    private func applyHighlights() {
        guard let text = model.targetText else {
            styledFull = AttributedString("")
            return
        }

        // Copy the cached base to avoid accumulating highlights across calls.
        var attributed = baseDocument
        let utf16 = text.utf16
        let total = utf16.count

        // Collect textSpan blanks, sort descending by start offset.
        let textSpanBlanks = model.blanks.compactMap { blank -> (Blank, Int, Int)? in
            guard case .textSpan(let start, let end) = blank.location else { return nil }
            return (blank, start, end)
        }.sorted { $0.1 > $1.1 }

        for (blank, start, end) in textSpanBlanks {
            guard start >= 0, end <= total, start < end else { continue }
            guard
                let startIdx = utf16.index(utf16.startIndex, offsetBy: start, limitedBy: utf16.endIndex),
                let endIdx   = utf16.index(utf16.startIndex, offsetBy: end,   limitedBy: utf16.endIndex),
                let lower = startIdx.samePosition(in: text),
                let upper = endIdx.samePosition(in: text),
                let range = Range<AttributedString.Index>(lower..<upper, in: attributed)
            else { continue }

            let isSelected = blank.id == model.selectedBlankID
            let bg: Color
            switch blank.status {
            case .confirmed:
                bg = CounselTheme.inkAccent.opacity(isSelected ? 0.35 : 0.20)
            case .proposed, .unmatched:
                bg = CounselTheme.inkAccent.opacity(isSelected ? 0.30 : 0.10)
            case .rejected:
                // No highlight for rejected blanks; keep the selection emphasis
                // to indicate which blank is focused even when rejected.
                bg = isSelected ? CounselTheme.inkAccent.opacity(0.12) : .clear
            }
            attributed[range].backgroundColor = bg
        }

        styledFull = attributed
    }

    // MARK: - Fallback context-list (targetText nil)

    /// Shown when targetText is nil: PDF targets, import failures, or during
    /// the brief window between planFill completing and the display import
    /// finishing. Renders each blank's context snippet so the user can still
    /// orient themselves in the document without the full text.
    private var fallbackContextList: some View {
        ScrollView(.vertical) {
            Text(contextListAttributed)
                .font(.system(.body, design: .serif))
                .foregroundStyle(CounselTheme.textPrimary)
                .textSelection(.enabled)
                .lineSpacing(6)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 48)
                .padding(.vertical, 56)
        }
        .background(CounselTheme.paper)
    }

    private var contextListAttributed: AttributedString {
        var base = AttributedString(FillTargetPresentation.contextList(
            targetFileName: model.targetURL?.lastPathComponent,
            blanks: model.blanks
        ))
        if let selected = model.blanks.first(where: { $0.id == model.selectedBlankID }) {
            if let range = base.range(of: selected.context) {
                base[range].backgroundColor = CounselTheme.inkAccent.opacity(0.18)
            }
        }
        return base
    }

    // MARK: - PDF V1 placeholder

    private var pdfV1Placeholder: some View {
        VStack(spacing: 18) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(CounselTheme.inkAccent.opacity(0.7))

            VStack(spacing: 6) {
                L10n.text("PDF target")
                    .font(.system(.title3, design: .serif))
                    .foregroundStyle(CounselTheme.textPrimary)
                L10n.text("Review and confirm blanks in the sidebar. Full PDF rendering is planned for a future version.")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 400)
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CounselTheme.paper)
    }
}

// MARK: - FillReportPane

/// The done-state report pane: filled count, skipped blanks with reasons, and
/// any manual AcroForm widgets that need human attention.
struct FillReportPane: View {
    let report: FillReport
    let manualWidgetNames: [String]

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 24) {
                // Summary header
                HStack(spacing: 16) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(CounselTheme.inkAccent)

                    VStack(alignment: .leading, spacing: 4) {
                        L10n.text("Fill complete")
                            .font(.system(.title2, design: .serif))
                            .foregroundStyle(CounselTheme.textPrimary)
                        Text(verbatim: FillStatusPresentation.completed(
                            filled: report.filledCount,
                            fileName: report.outputURL.lastPathComponent,
                            skipped: 0
                        ))
                            .font(.callout)
                            .foregroundStyle(CounselTheme.textSecondary)
                    }
                }

                // Skipped blanks
                if !report.skipped.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        L10n.text("Skipped (%lld)", report.skipped.count)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(CounselTheme.textSecondary)

                        ForEach(report.skipped, id: \.label) { skipped in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "minus.circle")
                                    .font(.caption)
                                    .foregroundStyle(CounselTheme.textSecondary)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 1) {
                                    let label = skipped.label.isEmpty
                                        ? FillServicePresentation.locationDescription(
                                            skipped.locationDescription
                                        )
                                        : skipped.label
                                    Text(verbatim: label)
                                        .font(.callout)
                                        .foregroundStyle(CounselTheme.textPrimary)
                                    Text(verbatim: FillServicePresentation.skippedReason(
                                        skipped.reason
                                    ))
                                        .font(CounselTheme.Typography.supporting)
                                        .foregroundStyle(CounselTheme.textSecondary)
                                }
                            }
                        }
                    }
                }

                // Manual widgets
                if !manualWidgetNames.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        L10n.text("Manual input required (%lld)", manualWidgetNames.count)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(CounselTheme.danger)

                        L10n.text("The following AcroForm fields were not auto-filled (checkboxes, radio buttons, and drop-downs require manual input):")
                            .font(.callout)
                            .foregroundStyle(CounselTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        ForEach(manualWidgetNames, id: \.self) { name in
                            HStack(spacing: 8) {
                                Image(systemName: "pencil.and.scribble")
                                    .font(.caption)
                                    .foregroundStyle(CounselTheme.danger)
                                Text(name)
                                    .font(.callout.monospaced())
                                    .foregroundStyle(CounselTheme.textPrimary)
                            }
                        }
                    }
                }
            }
            .padding(48)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(CounselTheme.paper)
    }
}
