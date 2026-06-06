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

import SwiftUI
import LDACore

/// The entity review sidebar. Lists detections grouped by type and their accept
/// state, with the ink accent used only for selection and focus.
public struct EntitySidebar: View {
    @ObservedObject private var model: ReviewModel

    /// The currently selected group row. Selection is purely a UI affordance; it
    /// uses the ink accent and does not change accept state.
    @State private var selection: String?

    public init(model: ReviewModel) {
        self.model = model
    }

    public var body: some View {
        List(selection: $selection) {
            ForEach(Self.orderedTypes, id: \.self) { type in
                let groups = groups(of: type)
                if !groups.isEmpty {
                    Section {
                        ForEach(groups) { group in
                            EntityGroupRow(
                                group: group,
                                isSelected: selection == group.id,
                                onSetAccepted: { accepted in
                                    model.setAccepted(ids: group.ids, accepted)
                                }
                            )
                            .tag(group.id)
                            .listRowBackground(rowBackground(for: group.id))
                        }
                    } header: {
                        // The header count is distinct values, not raw occurrences.
                        SectionHeader(type: type, count: groups.count)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .tint(CounselTheme.inkAccent)
        .scrollContentBackground(.hidden)
        .background(CounselTheme.appSurface)
    }

    // MARK: - Grouping

    /// A stable type ordering for sections so the sidebar layout never reshuffles
    /// between detections.
    private static let orderedTypes: [EntityType] = [
        .person, .company, .address, .email, .phone,
        .bankAccount, .nationalID, .uscc, .amount, .date, .unknown
    ]

    /// Group the entities of a type by their value (case and whitespace
    /// insensitive), so every occurrence of "Investors" collapses into one row
    /// with an occurrence count and a single accept control. Group order follows
    /// first appearance.
    private func groups(of type: EntityType) -> [EntityGroup] {
        var order: [String] = []
        var byKey: [String: EntityGroup] = [:]

        for entity in model.entities where entity.span.type == type {
            let key = entity.span.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if var existing = byKey[key] {
                existing.ids.insert(entity.id)
                existing.occurrences += 1
                existing.anyAccepted = existing.anyAccepted || entity.accepted
                if existing.token == nil, entity.accepted { existing.token = entity.token }
                byKey[key] = existing
            } else {
                order.append(key)
                byKey[key] = EntityGroup(
                    id: "\(type.rawValue)|\(key)",
                    value: entity.span.text,
                    type: type,
                    source: entity.span.source,
                    ids: [entity.id],
                    occurrences: 1,
                    anyAccepted: entity.accepted,
                    token: entity.accepted ? entity.token : nil
                )
            }
        }
        return order.compactMap { byKey[$0] }
    }

    /// The ink-tinted selection background, or clear for unselected rows.
    private func rowBackground(for id: EntityGroup.ID) -> Color {
        selection == id ? CounselTheme.inkAccent.opacity(0.10) : Color.clear
    }
}

// MARK: - EntityGroup

/// All occurrences of one value within a type, collapsed into a single
/// reviewable row.
private struct EntityGroup: Identifiable {
    let id: String
    let value: String
    let type: EntityType
    let source: DetectionSource
    var ids: Set<ReviewEntity.ID>
    var occurrences: Int
    var anyAccepted: Bool
    var token: String?
}

// MARK: - SectionHeader

/// A type section header: the type name in chrome type with a monospaced-digit
/// count so the numbers align cleanly down the sidebar.
private struct SectionHeader: View {
    let type: EntityType
    let count: Int

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
        }
        .textCase(nil)
    }
}

// MARK: - EntityRow

/// One dense group row: a type dot, the serif value, a quiet caption (type,
/// source, and an occurrence count when the value repeats), and a single accept
/// toggle that applies to every occurrence. Rejected rows read dimmed; the
/// assigned token, when present, renders as a sealed mono chip.
private struct EntityGroupRow: View {
    let group: EntityGroup
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

            Toggle("", isOn: acceptedBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(CounselTheme.inkAccent)
                .accessibilityLabel(Text("Accept \(group.type.rawValue) \(group.value)"))
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
            .foregroundStyle(CounselTheme.color(for: type))
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
