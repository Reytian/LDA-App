//
//  FillLibraryViews.swift
//  LDAUI
//
//  Portal UI for the Client Portfolio Library (stage .library).
//
//  Contains:
//  - PortalLibraryBody: the full library list view with toolbar affordances
//    (New Portfolio, Import), row actions (Edit, Fill, Export, Delete), and
//    empty-state when the library is empty.
//  - NewPortfolioSheet: kind picker + label field + From Documents / From Scratch.
//  - AddFieldSheet: canonical key picker + custom name + value field.
//  - ImportProfileSheet: passphrase / Keychain protection picker.
//
//  Factored from FillShell.swift so the combined fill shell stays under
//  ~800 lines. FillShell.swift owns all NSPanel calls; views here call back to
//  FillShell via closures or model intents.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import AppKit
import SwiftUI
import LDACore

// MARK: - PortalLibraryBody

/// The full-screen library view shown when model.stage == .library.
///
/// Displays model.summaries in a List with row-level actions (Edit, Fill,
/// Export, Delete), a toolbar-mirrored "New Portfolio" button at the top,
/// and an empty-state prompt when the list is empty. libraryNotice is shown
/// as a dismissable warning banner. exportError is shown as a non-sticky
/// error banner (no dismiss button; cleared by the model on next export).
struct PortalLibraryBody: View {
    @ObservedObject var model: FillModel

    // MARK: - Sheet state

    @State private var isShowingNewPortfolio = false

    // MARK: - Delete confirmation state

    @State private var portfolioToDelete: PortfolioSummary?
    @State private var isDeletingConfirmation = false

    // MARK: - Notice dismissal

    @State private var libraryNoticeDismissed = false

    // MARK: - Export trigger (passed in from shell)

    let onExport: (PortfolioSummary) -> Void
    let onImport: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            libraryTopBar

            if case .failed(let detail) = model.stage {
                libraryFailureBanner(detail)
            }

            // Library notice banner (one-time; dismissable).
            if let notice = model.libraryNotice, !libraryNoticeDismissed {
                libraryNoticeBanner(notice)
            }

            // Export error banner (clears when next export starts).
            if let err = model.exportError {
                exportErrorBanner(err)
            }

            if model.summaries.isEmpty {
                libraryEmptyState
            } else {
                portfolioList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CounselTheme.appSurface)
        // New Portfolio sheet.
        .sheet(isPresented: $isShowingNewPortfolio) {
            NewPortfolioSheet(model: model)
        }
        // Delete confirmation.
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: $isDeletingConfirmation,
            titleVisibility: .visible
        ) {
            L10n.button("Delete", role: .destructive) {
                if let s = portfolioToDelete {
                    Task { await model.deletePortfolio(id: s.id) }
                }
                portfolioToDelete = nil
            }
            L10n.button("Cancel", role: .cancel) {
                portfolioToDelete = nil
            }
        } message: {
            L10n.text("This action cannot be undone.")
        }
    }

    // MARK: - Top bar (New + Import)

    private var libraryTopBar: some View {
        HStack(spacing: 12) {
            Button {
                isShowingNewPortfolio = true
            } label: {
                L10n.label("New Portfolio", systemImage: "plus.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(CounselTheme.inkAccentFill)
            .l10nHelp("Create a new client portfolio")

            Button {
                onImport()
            } label: {
                L10n.label("Import", systemImage: "tray.and.arrow.down")
            }
            .l10nHelp("Import a portfolio from an .ldaprofile file")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(CounselTheme.raised)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CounselTheme.hairline).frame(height: 1)
        }
    }

    // MARK: - Portfolio list

    private var portfolioList: some View {
        List {
            ForEach(model.summaries, id: \.id) { summary in
                PortfolioRow(
                    summary: summary,
                    onEdit: {
                        Task { await model.openForEdit(id: summary.id) }
                    },
                    onFill: {
                        Task { await model.fillFrom(id: summary.id) }
                    },
                    onExport: {
                        onExport(summary)
                    },
                    onDelete: {
                        portfolioToDelete = summary
                        isDeletingConfirmation = true
                    }
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(CounselTheme.appSurface)
    }

    // MARK: - Empty state

    private var libraryEmptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "briefcase")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(CounselTheme.inkAccent.opacity(0.7))

            VStack(spacing: 6) {
                L10n.text("No portfolios yet")
                    .font(.system(.title3, design: .serif))
                    .foregroundStyle(CounselTheme.textPrimary)
                L10n.text("Create a new portfolio or import an existing .ldaprofile file.")
                    .font(CounselTheme.Typography.readingBody)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                isShowingNewPortfolio = true
            } label: {
                L10n.label("New Portfolio", systemImage: "plus.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(CounselTheme.inkAccentFill)
        }
        .frame(maxWidth: 360)
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Notice banners

    private func libraryFailureBanner(_ detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(CounselTheme.danger)
            Text(detail)
                .font(.callout)
                .foregroundStyle(CounselTheme.danger)
                .lineLimit(2)
            Spacer(minLength: 0)
            L10n.button("Retry") {
                Task { await model.refreshLibrary() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(CounselTheme.raised)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CounselTheme.hairline).frame(height: 1)
        }
    }

    private func libraryNoticeBanner(_ notice: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(CounselTheme.danger)
            Text(notice)
                .font(.callout)
                .foregroundStyle(CounselTheme.danger)
                .lineLimit(3)
            Spacer(minLength: 0)
            Button {
                libraryNoticeDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(CounselTheme.textSecondary)
            }
            .buttonStyle(.borderless)
            .l10nHelp("Dismiss notice")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(CounselTheme.raised)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CounselTheme.hairline).frame(height: 1)
        }
    }

    private func exportErrorBanner(_ error: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(CounselTheme.danger)
            L10n.text("Export failed: %@", error)
                .font(.callout)
                .foregroundStyle(CounselTheme.danger)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(CounselTheme.raised)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CounselTheme.hairline).frame(height: 1)
        }
    }

    // MARK: - Helpers

    private var deleteConfirmationTitle: String {
        if let s = portfolioToDelete {
            return String(
                format: L10n.string("Delete \"%@\"?"),
                s.label as NSString
            )
        }
        return L10n.string("Delete portfolio?")
    }
}

// MARK: - PortfolioRow

/// One row in the library list. Shows label, kind badge, modified date, and
/// conflict indicator. Row actions: Edit, Fill a document, Export, Delete.
struct PortfolioRow: View {
    let summary: PortfolioSummary
    let onEdit: () -> Void
    let onFill: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Leading icon.
            Image(systemName: portfolioIcon)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(CounselTheme.inkAccent)
                .frame(width: 28, alignment: .center)

            // Label + kind badge + modified date.
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(summary.label)
                        .font(.system(.body, design: .serif))
                        .foregroundStyle(CounselTheme.textPrimary)
                        .lineLimit(1)

                    kindBadge

                    if summary.conflicted {
                        conflictBadge
                    }
                }

                Text(modifiedDateLabel)
                    .font(.caption)
                    .foregroundStyle(CounselTheme.textSecondary)
            }

            Spacer(minLength: 0)

            // Action buttons.
            HStack(spacing: 4) {
                rowActionButton(
                    "Edit",
                    icon: "pencil",
                    help: "Open for editing",
                    action: onEdit
                )
                rowActionButton(
                    "Fill",
                    icon: "doc.text",
                    help: "Fill a document from this portfolio",
                    action: onFill
                )
                rowActionButton(
                    "Export",
                    icon: "tray.and.arrow.up",
                    help: "Export as .ldaprofile",
                    action: onExport
                )
                rowActionButton(
                    "Delete",
                    icon: "trash",
                    help: "Delete this portfolio",
                    tint: CounselTheme.danger,
                    action: onDelete
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(CounselTheme.raised)
        .clipShape(RoundedRectangle(cornerRadius: CounselTheme.Radius.sm))
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }

    // MARK: - Subviews

    private var kindBadge: some View {
        L10n.text(kindLabel)
            .font(.caption2.weight(.medium))
            .foregroundStyle(CounselTheme.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(CounselTheme.hairline)
            .clipShape(Capsule())
    }

    private var conflictBadge: some View {
        L10n.label("Conflict", systemImage: "exclamationmark.triangle.fill")
            .font(.caption2.weight(.medium))
            .foregroundStyle(CounselTheme.danger)
            .labelStyle(.iconOnly)
            .l10nHelp("This portfolio has unresolved field conflicts")
    }

    private func rowActionButton(
        _ labelKey: String,
        icon: String,
        help helpKey: String,
        tint: Color = CounselTheme.inkAccent,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(L10n.string(helpKey))
        .accessibilityLabel(Text(verbatim: L10n.string(labelKey)))
    }

    // MARK: - Helpers

    private var portfolioIcon: String {
        switch summary.kind {
        case .company: return "building.2"
        case .individual: return "person"
        case .general: return "folder"
        }
    }

    private var kindLabel: String {
        switch summary.kind {
        case .company: return "Company"
        case .individual: return "Individual"
        case .general: return "General"
        }
    }

    private var modifiedDateLabel: String {
        let raw = summary.modifiedAtISO8601
        guard !raw.isEmpty else { return L10n.string("Unknown date") }
        if let date = ISO8601DateFormatter().date(from: raw) {
            let formatter = DateFormatter()
            formatter.locale = AppLanguage.selected().locale
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return String(
                format: L10n.string("Modified %@"),
                formatter.string(from: date) as NSString
            )
        }
        // Fallback: show the raw string trimmed to the date portion.
        return String(
            format: L10n.string("Modified %@"),
            String(raw.prefix(10)) as NSString
        )
    }
}

// MARK: - NewPortfolioSheet

/// A modal sheet that collects kind, label, and creation mode (from documents
/// vs from scratch) for a new portfolio.
struct NewPortfolioSheet: View {
    @ObservedObject var model: FillModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedKind: PortfolioKind = .company
    @State private var label: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            L10n.text("New Portfolio")
                .font(CounselTheme.Typography.sectionTitle)
                .foregroundStyle(CounselTheme.textPrimary)

            // Kind picker.
            VStack(alignment: .leading, spacing: 8) {
                L10n.text("Portfolio type")
                    .font(CounselTheme.Typography.readingBody.weight(.medium))
                    .foregroundStyle(CounselTheme.textPrimary)

                L10n.picker("Kind", selection: $selectedKind) {
                    ForEach(PortfolioKind.allCases, id: \.self) { kind in
                        L10n.text(kindDisplayName(kind)).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                L10n.text(kindDescription)
                    .font(CounselTheme.Typography.readingBody)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Label field.
            VStack(alignment: .leading, spacing: 6) {
                L10n.text("Label")
                    .font(CounselTheme.Typography.readingBody.weight(.medium))
                    .foregroundStyle(CounselTheme.textPrimary)

                L10n.textField("e.g. Acme Corp, John Smith", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 280)
            }

            Divider()

            // Keep long translated actions readable at the compact sheet width.
            ViewThatFits(in: .horizontal) {
                HStack {
                    cancelButton
                    Spacer()
                    fromDocumentsButton
                    fromScratchButton
                }

                VStack(spacing: 10) {
                    HStack {
                        cancelButton
                        Spacer()
                    }
                    fromDocumentsButton
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    fromScratchButton
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 400)
        .background(CounselTheme.raised)
    }

    // MARK: - Helpers

    private var cancelButton: some View {
        L10n.button("Cancel", role: .cancel) {
            dismiss()
        }
        .keyboardShortcut(.cancelAction)
    }

    private var fromDocumentsButton: some View {
        Button {
            createPortfolio(fromScratch: false)
        } label: {
            L10n.label("From Documents", systemImage: "doc.badge.plus")
        }
        .l10nHelp("Create this portfolio then add source documents to extract fields")
        .keyboardShortcut(.return, modifiers: [])
    }

    private var fromScratchButton: some View {
        Button {
            createPortfolio(fromScratch: true)
        } label: {
            L10n.label("From Scratch", systemImage: "pencil.and.list.clipboard")
        }
        .buttonStyle(.borderedProminent)
        .tint(CounselTheme.inkAccentFill)
        .l10nHelp("Create an empty portfolio and add fields manually")
    }

    private func createPortfolio(fromScratch: Bool) {
        let created = nowISO8601()
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        let effectiveLabel = trimmed.isEmpty
            ? L10n.string(kindDisplayName(selectedKind))
            : trimmed
        Task {
            await model.createPortfolio(
                kind: selectedKind,
                label: effectiveLabel,
                fromScratch: fromScratch,
                createdAtISO8601: created
            )
        }
        dismiss()
    }

    private func kindDisplayName(_ kind: PortfolioKind) -> String {
        switch kind {
        case .company: return "Company"
        case .individual: return "Individual"
        case .general: return "General"
        }
    }

    private var kindDescription: String {
        switch selectedKind {
        case .company:
            return "Corporate entity: company name, registration, directors, shareholders, capital structure."
        case .individual:
            return "Natural person: name, date of birth, nationality, passport, national ID, address, contact."
        case .general:
            return "Covers both corporate and personal field sets. Use when a portfolio spans both."
        }
    }
}

// MARK: - AddFieldSheet

/// A sheet for adding a new field to the current portfolio. Shows the
/// canonical keys for the portfolio's kind, a custom-name text field, a
/// value field, and a live resolved-key preview.
struct AddFieldSheet: View {
    @ObservedObject var model: FillModel
    @Environment(\.dismiss) private var dismiss

    /// The kind used to build the canonical key list.
    let portfolioKind: PortfolioKind

    @State private var selectedCanonical: ProfileFieldKey?
    @State private var customName: String = ""
    @State private var value: String = ""

    /// The resolved key: canonical if a key is selected; custom from the typed name otherwise.
    private var resolvedKey: ProfileFieldKey {
        if let c = selectedCanonical {
            return c
        }
        let trimmed = customName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? .custom("") : model.resolveFieldName(trimmed)
    }

    private var resolvedKeyPreview: String {
        let key = resolvedKey
        switch key {
        case .custom(let name):
            if name.isEmpty {
                return L10n.string("(enter a name above)")
            }
            return String(
                format: L10n.string("Custom: \"%@\""),
                name as NSString
            )
        default:
            return ProfileFieldPresentation.localizedName(for: key)
        }
    }

    private var canAdd: Bool {
        switch resolvedKey {
        case .custom(let name):
            return !name.trimmingCharacters(in: .whitespaces).isEmpty
                && !value.trimmingCharacters(in: .whitespaces).isEmpty
        default:
            return !value.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            L10n.text("Add Field")
                .font(.headline)
                .foregroundStyle(CounselTheme.textPrimary)

            // Canonical key list.
            VStack(alignment: .leading, spacing: 6) {
                L10n.text("Canonical field")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(CounselTheme.textPrimary)

                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        Button {
                            selectedCanonical = nil
                        } label: {
                            HStack {
                                L10n.text("Custom (enter name below)")
                                    .font(.callout)
                                    .foregroundStyle(CounselTheme.textPrimary)
                                Spacer()
                                if selectedCanonical == nil {
                                    Image(systemName: "checkmark")
                                        .font(.caption)
                                        .foregroundStyle(CounselTheme.inkAccent)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)

                        ForEach(ProfileFieldKey.canonical(for: portfolioKind), id: \.rawKey) { key in
                            Button {
                                selectedCanonical = key
                                customName = ""
                            } label: {
                                HStack {
                                    Text(verbatim: ProfileFieldPresentation.localizedName(for: key))
                                        .font(.callout)
                                        .foregroundStyle(CounselTheme.textPrimary)
                                    Spacer()
                                    if selectedCanonical == key {
                                        Image(systemName: "checkmark")
                                            .font(.caption)
                                            .foregroundStyle(CounselTheme.inkAccent)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 180)
                .background(CounselTheme.appSurface)
                .clipShape(RoundedRectangle(cornerRadius: CounselTheme.Radius.sm))
                .overlay {
                    RoundedRectangle(cornerRadius: CounselTheme.Radius.sm)
                        .stroke(CounselTheme.hairline, lineWidth: 1)
                }
            }

            // Custom name field (enabled only when "Custom" is selected).
            if selectedCanonical == nil {
                VStack(alignment: .leading, spacing: 6) {
                    L10n.text("Field name")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(CounselTheme.textPrimary)

                    L10n.textField("e.g. Trustee name", text: $customName)
                        .textFieldStyle(.roundedBorder)
                }
            }

            // Value field.
            VStack(alignment: .leading, spacing: 6) {
                L10n.text("Value")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(CounselTheme.textPrimary)

                TextField(text: $value) { EmptyView() }
                    .textFieldStyle(.roundedBorder)
            }

            // Live key preview.
            HStack(spacing: 6) {
                L10n.text("Will save as:")
                    .font(.caption)
                    .foregroundStyle(CounselTheme.textSecondary)
                Text(resolvedKeyPreview)
                    .font(.caption.monospaced())
                    .foregroundStyle(CounselTheme.inkAccent)
            }

            Divider()

            HStack {
                L10n.button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                L10n.button("Add Field") {
                    model.addField(key: resolvedKey, value: value.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(CounselTheme.inkAccentFill)
                .disabled(!canAdd)
            }
        }
        .padding(24)
        .frame(minWidth: 380)
        .background(CounselTheme.raised)
    }
}

// MARK: - Timestamp helper

/// Returns the current date and time formatted as an ISO 8601 string.
/// Lives in this file (the portal/editor edge layer). Called at button
/// tap sites so the model never reads the clock.
func nowISO8601() -> String {
    ISO8601DateFormatter().string(from: Date())
}
