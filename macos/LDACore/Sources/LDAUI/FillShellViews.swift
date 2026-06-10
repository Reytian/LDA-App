//
//  FillShellViews.swift
//  LDAUI
//
//  Subviews for FillShell that were factored out to keep FillShell.swift under
//  800 lines. Contains:
//
//  - ProfileBuilderBody: the left/right split for the profile builder stage.
//  - ProfileFieldTable: the editable field list with conflict resolve controls
//    and verified/unverified badges.
//  - SourceListPane: the imported source documents sidebar.
//  - FillReviewBody: the NavigationSplitView for the fill review stage.
//  - BlankSidebar: the blank review list with keyboard bindings.
//  - BlankDocumentPane: the document pane for the fill review stage.
//  - FillReportPane: the done-state report.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import AppKit
import SwiftUI
import LDACore

// MARK: - ProfileBuilderBody

/// The two-column layout for the profile builder: a source list on the left
/// and the editable field table on the right (or an empty-state prompt when
/// no profile exists yet).
struct ProfileBuilderBody: View {
    @ObservedObject var model: FillModel
    let sourcePaths: [URL]

    var body: some View {
        HStack(spacing: 0) {
            SourceListPane(sourcePaths: sourcePaths)
                .frame(width: 220)
                .background(CounselTheme.appSurface)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(CounselTheme.hairline).frame(width: 1)
                }

            if let profile = model.profile {
                ProfileFieldTable(model: model, profile: profile)
            } else {
                profileEmptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var profileEmptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(CounselTheme.inkAccent.opacity(0.8))

            VStack(spacing: 6) {
                Text("No profile yet")
                    .font(.system(.title3, design: .serif))
                    .foregroundStyle(CounselTheme.textPrimary)
                Text("Add source documents and click Extract, or load a saved .ldaprofile.")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 400)
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - SourceListPane

/// The narrow left pane showing the source document names added by the user.
struct SourceListPane: View {
    let sourcePaths: [URL]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sources")
                .font(.caption.weight(.semibold))
                .foregroundStyle(CounselTheme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(CounselTheme.hairline).frame(height: 1)
                }

            if sourcePaths.isEmpty {
                Text("No sources added")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .padding(12)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(sourcePaths, id: \.absoluteString) { url in
                            Label(url.lastPathComponent, systemImage: "doc.text")
                                .font(.callout)
                                .foregroundStyle(CounselTheme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - ProfileFieldTable

/// The main body of the profile builder: a list of profile fields, each with
/// an editable value, a source label, a confidence bar, and a verified badge.
/// Conflict rows add a Menu to pick the winning candidate.
struct ProfileFieldTable: View {
    @ObservedObject var model: FillModel
    let profile: CompanyProfile

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                // Header row
                fieldHeaderRow

                ForEach(profile.fields) { field in
                    ProfileFieldRow(
                        model: model,
                        field: field,
                        isConflicted: profile.conflictedKeys.contains(field.key),
                        conflictCandidates: profile.fields.filter { $0.key == field.key }
                    )
                    Rectangle()
                        .fill(CounselTheme.hairline)
                        .frame(height: 1)
                        .padding(.leading, 16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CounselTheme.paper)
    }

    private var fieldHeaderRow: some View {
        HStack(spacing: 0) {
            columnHeader("Field", width: 180)
            columnHeader("Value", minWidth: 200)
            columnHeader("Source", width: 160)
            columnHeader("Confidence", width: 100)
            columnHeader("", width: 24) // verified badge column
        }
        .background(CounselTheme.raised)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CounselTheme.hairline).frame(height: 1)
        }
    }

    private func columnHeader(_ text: String, width: CGFloat? = nil, minWidth: CGFloat? = nil) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(CounselTheme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(
                minWidth: minWidth ?? width,
                maxWidth: minWidth != nil ? .infinity : width,
                alignment: .leading
            )
    }
}

// MARK: - ProfileFieldRow

/// One row in the profile field table. The value cell is an editable
/// TextField bound back through model.updateField. The source snippet shows
/// on hover in a tooltip. Conflict rows show a Menu to pick the winning field.
struct ProfileFieldRow: View {
    @ObservedObject var model: FillModel
    let field: ProfileField
    let isConflicted: Bool
    let conflictCandidates: [ProfileField]

    @State private var editedValue: String

    init(
        model: FillModel,
        field: ProfileField,
        isConflicted: Bool,
        conflictCandidates: [ProfileField]
    ) {
        self.model = model
        self.field = field
        self.isConflicted = isConflicted
        self.conflictCandidates = conflictCandidates
        self._editedValue = State(initialValue: field.value)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Key / display name
            HStack(spacing: 6) {
                if isConflicted {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(CounselTheme.danger)
                }
                Text(field.key.displayName)
                    .font(.callout)
                    .foregroundStyle(isConflicted ? CounselTheme.danger : CounselTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 12)
            .frame(width: 180, alignment: .leading)

            // Value: editable text field
            Group {
                if isConflicted {
                    // Conflict: show value + a resolve menu
                    conflictValueCell
                } else {
                    TextField("", text: $editedValue)
                        .textFieldStyle(.plain)
                        .font(.callout.monospaced())
                        .foregroundStyle(
                            field.userEdited
                                ? CounselTheme.inkAccent
                                : CounselTheme.textPrimary
                        )
                        .onSubmit {
                            if editedValue != field.value {
                                model.updateField(id: field.id, value: editedValue)
                            }
                        }
                        .onChange(of: field.value) { _, newVal in
                            editedValue = newVal
                        }
                }
            }
            .padding(.horizontal, 12)
            .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)

            // Source document name
            Text(field.sourceDocument)
                .font(.caption)
                .foregroundStyle(CounselTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 12)
                .frame(width: 160, alignment: .leading)

            // Confidence bar
            ConfidenceBar(confidence: field.confidence)
                .padding(.horizontal, 12)
                .frame(width: 100, alignment: .leading)

            // Verified badge, with source snippet as tooltip
            verifiedBadge
                .frame(width: 24, alignment: .center)
                .padding(.trailing, 8)
        }
        .padding(.vertical, 6)
        .background(isConflicted ? CounselTheme.danger.opacity(0.05) : Color.clear)
    }

    private var conflictValueCell: some View {
        HStack(spacing: 8) {
            Text(field.value)
                .font(.callout.monospaced())
                .foregroundStyle(CounselTheme.danger)
                .lineLimit(1)
                .truncationMode(.middle)

            Menu {
                ForEach(conflictCandidates) { candidate in
                    Button {
                        model.resolveConflict(key: field.key, keepFieldID: candidate.id)
                    } label: {
                        HStack {
                            Text(candidate.value)
                            if candidate.id == field.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label("Resolve", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(CounselTheme.danger)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose which value to keep for \(field.key.displayName)")
        }
    }

    @ViewBuilder
    private var verifiedBadge: some View {
        if field.snippetVerified {
            Image(systemName: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(CounselTheme.inkAccent)
                .help(field.sourceSnippet.isEmpty
                    ? "Verified: the value was found verbatim in the source document"
                    : "Verified. Source: \(field.sourceSnippet)")
                .accessibilityLabel("Verified")
        } else {
            Image(systemName: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(CounselTheme.textSecondary.opacity(0.5))
                .help(field.sourceSnippet.isEmpty
                    ? "Unverified: the value was not confirmed verbatim in the source"
                    : "Unverified. Extracted from: \(field.sourceSnippet)")
                .accessibilityLabel("Unverified")
        }
    }
}

// MARK: - ConfidenceBar

/// A small horizontal bar showing extraction confidence.
struct ConfidenceBar: View {
    let confidence: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(CounselTheme.hairline)
                RoundedRectangle(cornerRadius: 2)
                    .fill(confidenceColor)
                    .frame(width: geo.size.width * max(0, min(1, confidence)))
            }
        }
        .frame(height: 4)
        .accessibilityLabel("Confidence \(Int((confidence * 100).rounded()))%")
    }

    private var confidenceColor: Color {
        if confidence >= 0.75 { return CounselTheme.inkAccent }
        if confidence >= 0.4 { return CounselTheme.textSecondary }
        return CounselTheme.danger
    }
}

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
            Text("Planning fill")
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
        Text("No blanks detected")
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
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Settings")
            .accessibilityLabel(Text("Settings"))

            Spacer(minLength: 0)

            if !model.blanks.isEmpty {
                let confirmedCount = model.blanks.filter { $0.status == .confirmed }.count
                Text("\(confirmedCount)/\(model.blanks.count)")
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
        return model.profile?.fields.first(where: { $0.id == fid })?.key.displayName
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
            Button("Accept") { model.acceptBlank(id: blank.id) }
            Button("Reject") { model.rejectBlank(id: blank.id) }
            Button("Choose Field") {
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
        Text(displayLabel)
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
                    Text("(from \(verbatim))")
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
            Text(blank.status == .unmatched ? "No match" : "Tap to choose")
                .font(.caption)
                .foregroundStyle(CounselTheme.textSecondary.opacity(0.7))
        }
    }

    private var displayLabel: String {
        let raw = blank.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty { return raw }
        let ctx = blank.context.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = ctx.prefix(40)
        return preview.isEmpty ? "(blank)" : "\u{201C}\(preview)\u{201D}"
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
            Text("Choose a field")
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
                                        Text(field.key.displayName)
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
                Text("No profile fields available")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .padding(16)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { onDismiss() }
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
        guard let url = model.targetURL else {
            return AttributedString("No target document loaded.")
        }
        let blanksDesc = model.blanks.isEmpty
            ? "No blanks detected in this document."
            : model.blanks.map { blank in
                let label = blank.label.isEmpty ? "(blank)" : blank.label
                return "\(label): \(blank.context)"
            }.joined(separator: "\n\n")
        var base = AttributedString("\(url.lastPathComponent)\n\n\(blanksDesc)")
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
                Text("PDF target")
                    .font(.system(.title3, design: .serif))
                    .foregroundStyle(CounselTheme.textPrimary)
                Text("Review and confirm blanks in the sidebar. "
                     + "Full PDF rendering is planned for a future version.")
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
                        Text("Fill complete")
                            .font(.system(.title2, design: .serif))
                            .foregroundStyle(CounselTheme.textPrimary)
                        Text("\(report.filledCount) blank\(report.filledCount == 1 ? "" : "s") filled in \(report.outputURL.lastPathComponent).")
                            .font(.callout)
                            .foregroundStyle(CounselTheme.textSecondary)
                    }
                }

                // Skipped blanks
                if !report.skipped.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Skipped (\(report.skipped.count))")
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
                                        ? skipped.locationDescription
                                        : skipped.label
                                    Text(label)
                                        .font(.callout)
                                        .foregroundStyle(CounselTheme.textPrimary)
                                    Text(skipped.reason)
                                        .font(.caption)
                                        .foregroundStyle(CounselTheme.textSecondary)
                                }
                            }
                        }
                    }
                }

                // Manual widgets
                if !manualWidgetNames.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Manual input required (\(manualWidgetNames.count))")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(CounselTheme.danger)

                        Text("The following AcroForm fields were not auto-filled "
                             + "(checkboxes, radio buttons, and drop-downs require manual input):")
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
