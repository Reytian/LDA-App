//
//  EntitySidebar.swift
//  LDAUI
//
//  The entity sidebar: a grouped, dense, scannable review list. Detections are
//  grouped into a Section per EntityType, each header carrying a monospaced-digit
//  count. Every row shows a low-chroma type dot in the entity hue, the surface
//  value in a serif face (truncated), a quiet caption with the type and the
//  detection source (regex vs LLM), and an accept toggle bound through
//  model.setAccepted. The ink accent is reserved for selection and focus; a
//  rejected entity reads dimmed. The layout stays compact so a 200-entity
//  contract remains usable.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import AppKit
import SwiftUI
import LDACore

/// The entity review sidebar. Lists detections grouped by type and their accept
/// state, with the ink accent used only for selection and focus. The session's
/// document tray sits at the top (R19).
public struct EntitySidebar: View {
    @ObservedObject private var session: SessionModel
    @ObservedObject private var model: ReviewModel

    /// Opens the Settings scene reliably (does not rely on menu wiring).
    @Environment(\.openSettings) private var openSettings

    /// The window's undo manager, so a Protect action lands in Edit > Undo.
    @Environment(\.undoManager) private var undoManager

    /// True while the add-a-missed-term popover is presented.
    @State private var isAddingTerm = false

    /// The persisted output style, observed so switching styles in Settings
    /// shows or hides the pseudonym editing affordances live (F5).
    @AppStorage(AISettings.outputStyleKey) private var outputStyleRaw =
        SubstitutionStyle.token.rawValue

    public init(session: SessionModel, model: ReviewModel) {
        self.session = session
        self.model = model
    }

    /// Whether replacement editing is available (pseudonym style only).
    private var isPseudonymEditingAvailable: Bool {
        PseudonymEditingPresentation.isEditingAvailable(
            style: SubstitutionStyle(rawValue: outputStyleRaw) ?? .token
        )
    }

    public var body: some View {
        // Selection lives on the model so the Review menu commands (next,
        // previous, toggle) and the list always agree. Arrow keys navigate
        // natively once the list has focus; Space and Return flip the selected
        // group without touching the mouse.
        ScrollViewReader { proxy in
            groupList
                .onChange(of: model.groupToReveal) { _, id in
                    // A legend click or a Protect action asks for the group to
                    // be scrolled into view; consume the request once.
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                    model.groupToReveal = nil
                }
        }
    }

    /// The tray plus one section per entity type, with selection on the model.
    private var groupList: some View {
        List(selection: $model.selectedGroupIDs) {
            if session.entries.count > 1 {
                Section {
                    ForEach(session.entries) { entry in
                        DocumentTrayRow(
                            model: entry.model,
                            name: entry.name,
                            isSelected: session.activeEntry?.id == entry.id,
                            onSelect: { session.selectedID = entry.id },
                            onRemove: { session.removeDocument(id: entry.id) }
                        )
                        .listRowBackground(
                            session.activeEntry?.id == entry.id
                                ? CounselTheme.inkAccent.opacity(0.10)
                                : Color.clear
                        )
                    }
                } header: {
                    HStack(spacing: 8) {
                        Image(systemName: "tray.full")
                            .font(.caption)
                            .foregroundStyle(CounselTheme.textSecondary)
                        L10n.text("Documents")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(CounselTheme.textSecondary)
                        Spacer(minLength: 8)
                        Text("\(session.entries.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(CounselTheme.textSecondary)
                    }
                    .textCase(nil)
                }
            }

            ForEach(ReviewModel.groupTypeOrder, id: \.self) { type in
                let groups = model.groups(of: type)
                if !groups.isEmpty {
                    Section {
                        ForEach(groups) { group in
                            EntityGroupRow(
                                group: group,
                                isSelected: model.selectedGroupIDs.contains(group.id),
                                onSetAccepted: { accepted in
                                    model.setAccepted(ids: group.ids, accepted)
                                },
                                pseudonymEditing: pseudonymEditingContext(for: group)
                            )
                            .tag(group.id)
                            .id(group.id)
                            .listRowBackground(rowBackground(for: group.id))
                        }
                    } header: {
                        // The header count is distinct values, not raw occurrences.
                        SectionHeader(
                            type: type,
                            count: groups.count,
                            onSetAllAccepted: { accepted in
                                model.setAccepted(type: type, accepted)
                            }
                        )
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .tint(CounselTheme.inkAccent)
        .scrollContentBackground(.hidden)
        .background(CounselTheme.appSurface)
        .overlay {
            if session.entries.count <= 1, model.entities.isEmpty {
                sidebarEmptyState
            }
        }
        .onKeyPress(.space) {
            guard !model.selectedGroupIDs.isEmpty else { return .ignored }
            model.toggleSelectedGroup()
            return .handled
        }
        .onKeyPress(.return) {
            guard !model.selectedGroupIDs.isEmpty else { return .ignored }
            model.toggleSelectedGroup()
            return .handled
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            sidebarFooter
        }
    }

    // MARK: - Pseudonym editing (F5)

    /// The editing context for one group row, or nil when the affordance is
    /// hidden (non-pseudonym styles). Editing applies to accepted values via
    /// the row itself; the session validates and stores every edit.
    private func pseudonymEditingContext(for group: ReviewGroup) -> PseudonymEditingContext? {
        guard isPseudonymEditingAvailable else { return nil }
        return PseudonymEditingContext(
            currentReplacement: PseudonymEditingPresentation.currentReplacement(
                override: session.pseudonymOverrides[group.value],
                assignedToken: group.token
            ),
            hasOverride: session.pseudonymOverrides[group.value] != nil,
            onSubmit: { replacement in
                do {
                    try session.setPseudonymOverride(
                        surface: group.value,
                        replacement: replacement
                    )
                    return nil
                } catch let error as PseudonymOverrideError {
                    return PseudonymOverrideErrorPresentation.message(for: error)
                } catch {
                    return error.localizedDescription
                }
            }
        )
    }

    // MARK: - Footer

    /// A thin footer pinned to the lower-left with a Settings gear and the
    /// add-a-missed-term control (R5), plus the pseudonym editing footnote
    /// while that style is active.
    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.selectedGroupIDs.count > 1 {
                batchSelectionBar
            } else if model.entityGroups.count >= 5 {
                L10n.text("Tip: Command-click or Shift-click extra findings, then keep them visible together.")
                    .font(CounselTheme.Typography.supporting)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .l10nAccessibilityLabel("Tip: select several extra findings to keep them visible together.")
            }
            if isPseudonymEditingAvailable, !model.entities.isEmpty {
                Text(LocalizedStringKey(PseudonymEditingPresentation.footnote))
                    .font(CounselTheme.Typography.supporting)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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

                if !model.documentText.isEmpty {
                    protectControl
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(CounselTheme.appSurface)
        .overlay(alignment: .top) {
            Rectangle().fill(CounselTheme.hairline).frame(height: 1)
        }
    }

    /// The Protect control (R5 plus select-to-protect). While the Original
    /// view has a selection it becomes a primary "Protect “value”…" button;
    /// otherwise it is the quiet typed-path label. Both open the same chooser.
    @ViewBuilder
    private var protectControl: some View {
        if let value = selectedValue {
            Button {
                isAddingTerm = true
            } label: {
                Label {
                    Text(verbatim: String(
                        format: L10n.string("Protect “%@”\u{2026}"),
                        ProtectSelectionPresentation.menuValue(value) as NSString
                    ))
                } icon: {
                    Image(systemName: "text.badge.plus")
                }
                .font(CounselTheme.Typography.supporting)
            }
            .buttonStyle(.bordered)
            .tint(CounselTheme.inkAccentFill)
            .help(LocalizedStringKey(protectHelpKey))
            .l10nAccessibilityLabel("Protect the selected text")
            .popover(isPresented: $isAddingTerm, arrowEdge: .bottom) {
                AddTermPopover(
                    model: model,
                    isPresented: $isAddingTerm,
                    selection: value,
                    undoManager: undoManager
                )
            }
        } else {
            Button {
                isAddingTerm = true
            } label: {
                L10n.label("Protect a missed item", systemImage: "plus.circle")
                    .font(CounselTheme.Typography.supporting)
                    .foregroundStyle(CounselTheme.textSecondary)
            }
            .buttonStyle(.borderless)
            .disabled(model.status == .detecting)
            .help(LocalizedStringKey(protectHelpKey))
            .l10nAccessibilityLabel("Protect a missed item")
            .popover(isPresented: $isAddingTerm, arrowEdge: .bottom) {
                AddTermPopover(model: model, isPresented: $isAddingTerm, undoManager: undoManager)
            }
        }
    }

    /// The trimmed Original-view selection, when one can be protected.
    private var selectedValue: String? {
        guard model.canProtectSelection, let raw = model.selectedText else { return nil }
        let value = ProtectSelectionRules.trim(raw)
        return value.isEmpty ? nil : value
    }

    /// The help text follows the state: scanning, Safe Preview, or Original.
    private var protectHelpKey: String {
        if model.status == .detecting {
            return "Available when the scan finishes."
        }
        if model.previewMode == .safePreview {
            return "Switch to Original to select text to protect."
        }
        return "Select text in the document, then protect it as a kind. Every occurrence is redacted."
    }

    /// Actions for a native macOS multi-selection. Findings remain selected
    /// after either action, which makes the decision easy to reverse.
    private var batchSelectionBar: some View {
        HStack(spacing: 8) {
            Text("\(model.selectedGroupIDs.count) selected")
                .font(.caption.weight(.semibold))
                .foregroundStyle(CounselTheme.textPrimary)

            Spacer(minLength: 4)

            L10n.button("Redact") {
                model.setSelectedGroupsAccepted(true)
            }
            .buttonStyle(.borderless)
            .l10nHelp("Redact every selected finding")

            L10n.button("Keep Visible") {
                model.setSelectedGroupsAccepted(false)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(CounselTheme.danger)
            .l10nHelp("Keep every selected finding visible in the exported document")

            Button {
                model.selectedGroupIDs = []
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(CounselTheme.textSecondary)
            }
            .buttonStyle(.borderless)
            .l10nHelp("Clear selection")
            .l10nAccessibilityLabel("Clear finding selection")
        }
        .padding(.bottom, 2)
    }

    private var sidebarEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: emptyStateIcon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(CounselTheme.textSecondary)
            Text(verbatim: L10n.string(emptyStateTitle))
                .font(.callout.weight(.semibold))
                .foregroundStyle(CounselTheme.textPrimary)
            Text(verbatim: localizedEmptyStateDetail)
                .font(CounselTheme.Typography.supporting)
                .foregroundStyle(CounselTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: 250)
        .accessibilityElement(children: .combine)
    }

    private var emptyStateTitle: String {
        switch model.status {
        case .detecting: return "Scanning on this Mac"
        case .ready: return "No findings detected"
        case .failed: return "Findings unavailable"
        case .idle, .importing, .imported: return "Findings appear here"
        }
    }

    private var emptyStateDetail: String {
        switch model.status {
        case .idle, .importing:
            return "Add a document to begin."
        case .imported:
            return "Scan the document, then accept or keep each detected item."
        case .detecting:
            return "Detected names and other sensitive items will appear as they are ready for review."
        case .ready:
            return "Review the document and use Protect a missed item if you spot something sensitive."
        case .failed(let detail):
            return detail
        }
    }

    private var localizedEmptyStateDetail: String {
        if case .failed(let detail) = model.status {
            return detail
        }
        return L10n.string(emptyStateDetail)
    }

    private var emptyStateIcon: String {
        switch model.status {
        case .detecting: return "text.magnifyingglass"
        case .ready: return "checkmark.shield"
        case .failed: return "exclamationmark.triangle"
        case .idle, .importing, .imported: return "sidebar.left"
        }
    }


    // MARK: - Selection chrome

    /// The ink-tinted selection background, or clear for unselected rows.
    private func rowBackground(for id: ReviewGroup.ID) -> Color {
        model.selectedGroupIDs.contains(id) ? CounselTheme.inkAccent.opacity(0.10) : Color.clear
    }
}

// MARK: - SectionHeader

/// A type section header: the type name in chrome type with a monospaced-digit
/// count, plus a quiet menu to redact or keep every value of the type at once
/// (also available as a context menu on the header).
private struct SectionHeader: View {
    let type: EntityType
    let count: Int
    let onSetAllAccepted: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(CounselTheme.color(for: type))
                .frame(width: 7, height: 7)
            Text(EntityTypePresentation.localizedKey(for: type))
                .font(.caption.weight(.semibold))
                .foregroundStyle(CounselTheme.textSecondary)
            Spacer(minLength: 8)
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(CounselTheme.textSecondary)

            Menu {
                EntityTypeBulkActions(type: type, onSetAllAccepted: onSetAllAccepted)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.caption)
                    .foregroundStyle(CounselTheme.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(EntityTypePresentation.bulkActionHelp(for: type))
            .accessibilityLabel(Text(verbatim: String(
                format: L10n.string("Bulk actions for %@"),
                EntityTypePresentation.localizedName(for: type) as NSString
            )))
        }
        .textCase(nil)
        .contextMenu {
            EntityTypeBulkActions(type: type, onSetAllAccepted: onSetAllAccepted)
        }
    }
}

// MARK: - Pseudonym editing context (F5)

/// Editing support for one group's replacement text. nil hides the affordance
/// entirely (token and asterisk styles).
struct PseudonymEditingContext {
    /// The replacement the row shows: the user's override, or the one the
    /// most recent build assigned (nil before the first build).
    let currentReplacement: String?
    /// True when the shown replacement is a user override (enables clearing).
    let hasOverride: Bool
    /// Validate and store one edit. Returns nil on success, or the
    /// human-readable rejection to show inline. An empty string clears the
    /// override.
    let onSubmit: (String) -> String?
}

// MARK: - EntityRow

/// One dense group row: a type dot, the serif value, a quiet caption (type,
/// source, and an occurrence count when the value repeats), and a single accept
/// toggle that applies to every occurrence. Rejected rows read dimmed; the
/// assigned token, when present, renders as a sealed mono chip. Under the
/// pseudonym style the chip's text is editable through a small popover.
private struct EntityGroupRow: View {
    let group: ReviewGroup
    let isSelected: Bool
    let onSetAccepted: (Bool) -> Void
    let pseudonymEditing: PseudonymEditingContext?

    /// True while the replacement editing popover is presented.
    @State private var isEditingReplacement = false
    /// The draft replacement text inside the popover.
    @State private var replacementDraft = ""
    /// The inline rejection from the last submit, if any.
    @State private var replacementError: String?

    private var accepted: Bool { group.anyAccepted }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Circle()
                .fill(CounselTheme.color(for: group.type))
                .frame(width: 8, height: 8)
                .opacity(accepted ? 1.0 : 0.4)
                .alignmentGuide(.firstTextBaseline) { dimension in
                    dimension[.bottom] - 1
                }

            VStack(alignment: .leading, spacing: 2) {
                valueLine
                captionLine
            }

            Spacer(minLength: 8)

            if !accepted {
                Image(systemName: "eye")
                    .font(.caption)
                    .foregroundStyle(CounselTheme.danger)
                    .l10nHelp("Rejected: this will remain visible in the exported document")
                    .l10nAccessibilityLabel("Will remain visible")
            }

            Toggle("", isOn: acceptedBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(CounselTheme.inkAccent)
                .accessibilityLabel(Text(verbatim: String(
                    format: L10n.string("Redact %@ %@"),
                    EntityTypePresentation.localizedName(for: group.type) as NSString,
                    group.value as NSString
                )))
                .l10nAccessibilityHint("Toggles whether every occurrence of this value is replaced in the exported document or remains visible.")
        }
        .padding(.vertical, 3)
        .opacity(accepted ? 1.0 : 0.55)
    }

    /// The value in serif, truncated, an occurrence-count pill when it repeats,
    /// the sealed replacement chip once one exists, and the pseudonym edit
    /// affordance when the style allows it.
    private var valueLine: some View {
        HStack(spacing: 6) {
            Text(group.value)
                .font(.system(.callout, design: .serif))
                .foregroundStyle(CounselTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            if group.occurrences > 1 {
                Text("\u{00D7}\(group.occurrences)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(CounselTheme.textSecondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule(style: .continuous).fill(CounselTheme.hairline.opacity(0.6))
                    )
            }

            if accepted, let shown = pseudonymEditing?.currentReplacement ?? group.token {
                TokenChip(token: shown, type: group.type)
            }

            if accepted, let pseudonymEditing {
                Button {
                    replacementDraft = pseudonymEditing.currentReplacement ?? ""
                    replacementError = nil
                    isEditingReplacement = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(CounselTheme.textSecondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .l10nHelp("Edit the replacement text used for this value")
                .accessibilityLabel(Text("Edit replacement for \(group.value)"))
                .popover(isPresented: $isEditingReplacement, arrowEdge: .trailing) {
                    replacementPopover(pseudonymEditing)
                }
            }
        }
    }

    /// The small replacement editor: one field, inline validation, and a way
    /// back to the automatic pseudonym.
    private func replacementPopover(_ editing: PseudonymEditingContext) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Replacement for \"\(group.value)\"")
                .font(.headline)
                .foregroundStyle(CounselTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            L10n.text("This text stands in for the value in the safe copy. It cannot already appear in the session documents.")
                .font(CounselTheme.Typography.supporting)
                .foregroundStyle(CounselTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            L10n.textField("Replacement text", text: $replacementDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submitReplacement(editing) }

            if let replacementError {
                Text(replacementError)
                    .font(CounselTheme.Typography.supporting)
                    .foregroundStyle(CounselTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if editing.hasOverride {
                    L10n.button("Use Automatic") {
                        replacementError = editing.onSubmit("")
                        if replacementError == nil { isEditingReplacement = false }
                    }
                    .l10nHelp("Go back to the automatically chosen pseudonym")
                }
                Spacer()
                L10n.button("Cancel", role: .cancel) { isEditingReplacement = false }
                    .keyboardShortcut(.cancelAction)
                L10n.button("Use This Text") { submitReplacement(editing) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(CounselTheme.inkAccentFill)
                    .disabled(replacementDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func submitReplacement(_ editing: PseudonymEditingContext) {
        replacementError = editing.onSubmit(replacementDraft)
        if replacementError == nil {
            isEditingReplacement = false
        }
    }

    /// The quiet caption: type plus the detection source rendered as a human
    /// label (regex vs LLM).
    private var captionLine: some View {
        Text(verbatim: String(
            format: L10n.string("%@  \u{00B7}  %@"),
            EntityTypePresentation.localizedName(for: group.type) as NSString,
            EntityTypePresentation.sourceLabel(for: group.source) as NSString
        ))
            .font(.caption2)
            .foregroundStyle(CounselTheme.textSecondary)
            .lineLimit(1)
    }

    /// A binding that routes accept changes back through the model for every
    /// occurrence in the group, so the model stays the single source of truth.
    private var acceptedBinding: Binding<Bool> {
        Binding(
            get: { group.anyAccepted },
            set: { onSetAccepted($0) }
        )
    }
}

// MARK: - TokenChip

/// A sealed, filled chip showing the opaque mono token for an accepted entity,
/// for example [PERSON_1]. The fill is a low-chroma tint of the entity hue so it
/// reads as sealed without competing with the ink accent.
private struct TokenChip: View {
    let token: String
    let type: EntityType

    var body: some View {
        Text(displayToken)
            .font(.caption2.monospaced())
            .foregroundStyle(CounselTheme.textPrimary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(CounselTheme.color(for: type).opacity(0.12))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(CounselTheme.color(for: type).opacity(0.28), lineWidth: 1)
            )
            .lineLimit(1)
            .fixedSize()
    }

    /// Present the token in square brackets, normalizing the curly grammar form
    /// "{PERSON_1}" to the sealed display form "[PERSON_1]".
    private var displayToken: String {
        var inner = token
        if inner.hasPrefix("{") { inner.removeFirst() }
        if inner.hasSuffix("}") { inner.removeLast() }
        return "[\(inner)]"
    }
}
