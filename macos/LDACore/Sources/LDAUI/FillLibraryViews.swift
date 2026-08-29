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
            Button("Delete", role: .destructive) {
                if let s = portfolioToDelete {
                    Task { await model.deletePortfolio(id: s.id) }
                }
                portfolioToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                portfolioToDelete = nil
            }
        } message: {
            Text("This action cannot be undone.")
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            libraryTopBar
        }
    }

    // MARK: - Top bar (New + Import)

    private var libraryTopBar: some View {
        HStack(spacing: 12) {
            Button {
                isShowingNewPortfolio = true
            } label: {
                Label("New Portfolio", systemImage: "plus.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(CounselTheme.inkAccentFill)
            .help("Create a new client portfolio")

            Button {
                onImport()
            } label: {
                Label("Import", systemImage: "tray.and.arrow.down")
            }
            .help("Import a portfolio from an .ldaprofile file")

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
                Text("No portfolios yet")
                    .font(.system(.title3, design: .serif))
                    .foregroundStyle(CounselTheme.textPrimary)
                Text("Create a new portfolio or import an existing .ldaprofile file.")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                isShowingNewPortfolio = true
            } label: {
                Label("New Portfolio", systemImage: "plus.circle")
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
            Button("Retry") {
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
            .help("Dismiss notice")
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
            Text("Export failed: \(error)")
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
            return "Delete \"\(s.label)\"?"
        }
        return "Delete portfolio?"
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
        Text(kindLabel)
            .font(.caption2.weight(.medium))
            .foregroundStyle(CounselTheme.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(CounselTheme.hairline)
            .clipShape(Capsule())
    }

    private var conflictBadge: some View {
        Label("Conflict", systemImage: "exclamationmark.triangle.fill")
            .font(.caption2.weight(.medium))
            .foregroundStyle(CounselTheme.danger)
            .labelStyle(.iconOnly)
            .help("This portfolio has unresolved field conflicts")
    }

    private func rowActionButton(
        _ label: String,
        icon: String,
        help: String,
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
        .help(help)
        .accessibilityLabel(Text(label))
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
        guard !raw.isEmpty else { return "Unknown date" }
        if let date = ISO8601DateFormatter().date(from: raw) {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return "Modified \(formatter.string(from: date))"
        }
        // Fallback: show the raw string trimmed to the date portion.
        return "Modified \(raw.prefix(10))"
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
            Text("New Portfolio")
                .font(.headline)
                .foregroundStyle(CounselTheme.textPrimary)

            // Kind picker.
            VStack(alignment: .leading, spacing: 8) {
                Text("Portfolio type")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(CounselTheme.textPrimary)

                Picker("Kind", selection: $selectedKind) {
                    ForEach(PortfolioKind.allCases, id: \.self) { kind in
                        Text(kindDisplayName(kind)).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                Text(kindDescription)
                    .font(.caption)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Label field.
            VStack(alignment: .leading, spacing: 6) {
                Text("Label")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(CounselTheme.textPrimary)

                TextField("e.g. Acme Corp, John Smith", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 280)
            }

            Divider()

            // Action buttons.
            HStack {
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    let created = nowISO8601()
                    let trimmed = label.trimmingCharacters(in: .whitespaces)
                    let effectiveLabel = trimmed.isEmpty ? kindDisplayName(selectedKind) : trimmed
                    Task {
                        await model.createPortfolio(
                            kind: selectedKind,
                            label: effectiveLabel,
                            fromScratch: false,
                            createdAtISO8601: created
                        )
                    }
                    dismiss()
                } label: {
                    Label("From Documents", systemImage: "doc.badge.plus")
                }
                .disabled(false)
                .help("Create this portfolio then add source documents to extract fields")
                .keyboardShortcut(.return, modifiers: [])

                Button {
                    let created = nowISO8601()
                    let trimmed = label.trimmingCharacters(in: .whitespaces)
                    let effectiveLabel = trimmed.isEmpty ? kindDisplayName(selectedKind) : trimmed
                    Task {
                        await model.createPortfolio(
                            kind: selectedKind,
                            label: effectiveLabel,
                            fromScratch: true,
                            createdAtISO8601: created
                        )
                    }
                    dismiss()
                } label: {
                    Label("From Scratch", systemImage: "pencil.and.list.clipboard")
                }
                .buttonStyle(.borderedProminent)
                .tint(CounselTheme.inkAccentFill)
                .help("Create an empty portfolio and add fields manually")
            }
        }
        .padding(24)
        .frame(minWidth: 400)
        .background(CounselTheme.raised)
    }

    // MARK: - Helpers

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
            return name.isEmpty ? "(enter a name above)" : "Custom: \"\(name)\""
        default:
            return key.displayName
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
            Text("Add Field")
                .font(.headline)
                .foregroundStyle(CounselTheme.textPrimary)

            // Canonical key list.
            VStack(alignment: .leading, spacing: 6) {
                Text("Canonical field")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(CounselTheme.textPrimary)

                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        Button {
                            selectedCanonical = nil
                        } label: {
                            HStack {
                                Text("Custom (enter name below)")
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
                                    Text(key.displayName)
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
                    Text("Field name")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(CounselTheme.textPrimary)

                    TextField("e.g. Trustee name", text: $customName)
                        .textFieldStyle(.roundedBorder)
                }
            }

            // Value field.
            VStack(alignment: .leading, spacing: 6) {
                Text("Value")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(CounselTheme.textPrimary)

                TextField("", text: $value)
                    .textFieldStyle(.roundedBorder)
            }

            // Live key preview.
            HStack(spacing: 6) {
                Text("Will save as:")
                    .font(.caption)
                    .foregroundStyle(CounselTheme.textSecondary)
                Text(resolvedKeyPreview)
                    .font(.caption.monospaced())
                    .foregroundStyle(CounselTheme.inkAccent)
            }

            Divider()

            HStack {
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Add Field") {
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
