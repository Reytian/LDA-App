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

    /// True while the add-a-missed-term popover is presented.
    @State private var isAddingTerm = false

    public init(session: SessionModel, model: ReviewModel) {
        self.session = session
        self.model = model
    }

    public var body: some View {
        // Selection lives on the model so the Review menu commands (next,
        // previous, toggle) and the list always agree. Arrow keys navigate
        // natively once the list has focus; Space and Return flip the selected
        // group without touching the mouse.
        List(selection: $model.selectedGroupID) {
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
                        Text("Documents")
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
                                isSelected: model.selectedGroupID == group.id,
                                onSetAccepted: { accepted in
                                    model.setAccepted(ids: group.ids, accepted)
                                }
                            )
                            .tag(group.id)
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
            guard model.selectedGroupID != nil else { return .ignored }
            model.toggleSelectedGroup()
            return .handled
        }
        .onKeyPress(.return) {
            guard model.selectedGroupID != nil else { return .ignored }
            model.toggleSelectedGroup()
            return .handled
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            sidebarFooter
        }
    }

    // MARK: - Footer

    /// A thin footer pinned to the lower-left with a Settings gear and the
    /// add-a-missed-term control (R5).
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
            .help("Settings")
            .accessibilityLabel(Text("Settings"))

            Spacer(minLength: 0)

            if !model.documentText.isEmpty {
                Button {
                    isAddingTerm = true
                } label: {
                    Label("Protect a missed item", systemImage: "plus.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(CounselTheme.textSecondary)
                }
                .buttonStyle(.borderless)
                .help("Add something the detection missed; every occurrence will be redacted")
                .accessibilityLabel(Text("Protect a missed item"))
                .popover(isPresented: $isAddingTerm, arrowEdge: .bottom) {
                    AddTermPopover(model: model, isPresented: $isAddingTerm)
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

    private var sidebarEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: emptyStateIcon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(CounselTheme.textSecondary)
            Text(emptyStateTitle)
                .font(.callout.weight(.semibold))
                .foregroundStyle(CounselTheme.textPrimary)
            Text(emptyStateDetail)
                .font(.caption)
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
        model.selectedGroupID == id ? CounselTheme.inkAccent.opacity(0.10) : Color.clear
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
            Text(type.rawValue)
                .font(.caption.weight(.semibold))
                .foregroundStyle(CounselTheme.textSecondary)
            Spacer(minLength: 8)
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(CounselTheme.textSecondary)

            Menu {
                bulkActions
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.caption)
                    .foregroundStyle(CounselTheme.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Redact or keep every \(type.rawValue) value at once")
            .accessibilityLabel(Text("Bulk actions for \(type.rawValue)"))
        }
        .textCase(nil)
        .contextMenu { bulkActions }
    }

    @ViewBuilder
    private var bulkActions: some View {
        Button("Redact All \(type.rawValue)") { onSetAllAccepted(true) }
        Button("Keep All \(type.rawValue) Visible") { onSetAllAccepted(false) }
    }
}

// MARK: - EntityRow

/// One dense group row: a type dot, the serif value, a quiet caption (type,
/// source, and an occurrence count when the value repeats), and a single accept
/// toggle that applies to every occurrence. Rejected rows read dimmed; the
/// assigned token, when present, renders as a sealed mono chip.
private struct EntityGroupRow: View {
    let group: ReviewGroup
    let isSelected: Bool
    let onSetAccepted: (Bool) -> Void

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
                    .help("Rejected: this will remain visible in the exported document")
                    .accessibilityLabel("Will remain visible")
            }

            Toggle("", isOn: acceptedBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(CounselTheme.inkAccent)
                .accessibilityLabel(Text("Redact \(group.type.rawValue) \(group.value)"))
                .accessibilityHint(Text(
                    "Toggles whether every occurrence of this value is replaced "
                        + "in the exported document or remains visible."
                ))
        }
        .padding(.vertical, 3)
        .opacity(accepted ? 1.0 : 0.55)
    }

    /// The value in serif, truncated, an occurrence-count pill when it repeats,
    /// and the sealed token chip once a token has been assigned.
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

            if accepted, let token = group.token {
                TokenChip(token: token, type: group.type)
            }
        }
    }

    /// The quiet caption: type plus the detection source rendered as a human
    /// label (regex vs LLM).
    private var captionLine: some View {
        Text("\(group.type.rawValue)  \u{00B7}  \(Self.sourceLabel(for: group.source))")
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

    /// Render the detection source as a short, lawyer-facing label. Deterministic
    /// detections are regex matches; the rest carry their own names.
    private static func sourceLabel(for source: DetectionSource) -> String {
        switch source {
        case .deterministic:
            return "regex"
        case .llm:
            return "LLM"
        case .manual:
            return "manual"
        }
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
