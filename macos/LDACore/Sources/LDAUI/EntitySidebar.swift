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

    /// The currently selected row. Selection is purely a UI affordance here; it
    /// uses the ink accent and does not change accept state.
    @State private var selection: ReviewEntity.ID?

    public init(model: ReviewModel) {
        self.model = model
    }

    public var body: some View {
        List(selection: $selection) {
            ForEach(Self.orderedTypes, id: \.self) { type in
                let group = entities(of: type)
                if !group.isEmpty {
                    Section {
                        ForEach(group) { entity in
                            EntityRow(
                                entity: entity,
                                isSelected: selection == entity.id,
                                onSetAccepted: { accepted in
                                    model.setAccepted(entity.id, accepted)
                                }
                            )
                            .tag(entity.id)
                            .listRowBackground(rowBackground(for: entity.id))
                        }
                    } header: {
                        SectionHeader(type: type, count: group.count)
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

    /// The entities of a given type, preserving their order in the model.
    private func entities(of type: EntityType) -> [ReviewEntity] {
        model.entities.filter { $0.span.type == type }
    }

    /// The ink-tinted selection background, or clear for unselected rows.
    private func rowBackground(for id: ReviewEntity.ID) -> Color {
        selection == id ? CounselTheme.inkAccent.opacity(0.10) : Color.clear
    }
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

/// One dense detection row: a type dot, the serif surface value, a quiet
/// type-and-source caption, and an accept toggle. Rejected rows read dimmed; the
/// assigned token, when present, renders as a sealed mono chip.
private struct EntityRow: View {
    let entity: ReviewEntity
    let isSelected: Bool
    let onSetAccepted: (Bool) -> Void

    private var accepted: Bool { entity.accepted }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Circle()
                .fill(CounselTheme.color(for: entity.span.type))
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
                .accessibilityLabel(Text("Accept \(entity.span.type.rawValue)"))
        }
        .padding(.vertical, 3)
        .opacity(accepted ? 1.0 : 0.55)
    }

    /// The surface value in serif, truncated, with the sealed token chip shown
    /// alongside once a token has been assigned for an accepted entity.
    private var valueLine: some View {
        HStack(spacing: 6) {
            Text(entity.span.text)
                .font(.system(.callout, design: .serif))
                .foregroundStyle(CounselTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            if accepted, let token = entity.token {
                TokenChip(token: token, type: entity.span.type)
            }
        }
    }

    /// The quiet caption: type plus the detection source rendered as a human
    /// label (regex vs LLM).
    private var captionLine: some View {
        Text("\(entity.span.type.rawValue)  \u{00B7}  \(Self.sourceLabel(for: entity.span.source))")
            .font(.caption2)
            .foregroundStyle(CounselTheme.textSecondary)
            .lineLimit(1)
    }

    /// A binding that routes accept changes back through the model so the model
    /// stays the single source of truth.
    private var acceptedBinding: Binding<Bool> {
        Binding(
            get: { entity.accepted },
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
