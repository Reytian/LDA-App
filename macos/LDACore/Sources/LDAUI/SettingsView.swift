//
//  SettingsView.swift
//  LDAUI
//
//  The Settings window (Cmd+,). Lets the user manage a custom vocabulary: literal
//  terms that should always be redacted, each with the token type to assign. The
//  list persists across launches and is applied on the next Anonymize run.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import SwiftUI
import LDACore

/// Edits the user's custom redaction vocabulary.
public struct SettingsView: View {
    @ObservedObject private var store: CustomPatternStore

    public init(store: CustomPatternStore) {
        self.store = store
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if store.patterns.isEmpty {
                emptyState
            } else {
                List {
                    ForEach($store.patterns) { $pattern in
                        PatternRow(pattern: $pattern)
                    }
                    .onDelete { store.remove(atOffsets: $0) }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }

            footer
        }
        .frame(width: 540, height: 420)
        .background(CounselTheme.appSurface)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Custom vocabulary")
                .font(.system(.title3, design: .serif))
                .foregroundStyle(CounselTheme.textPrimary)
            Text("Terms listed here are always redacted, in addition to what the engine finds. Useful for project codenames, client names, and internal labels.")
                .font(.callout)
                .foregroundStyle(CounselTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(CounselTheme.textSecondary)
            Text("No custom terms yet")
                .foregroundStyle(CounselTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Button {
                store.add()
            } label: {
                Label("Add Term", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(CounselTheme.inkAccent)
            Spacer()
            Text("\(store.activePatterns.count) active")
                .font(.caption.monospacedDigit())
                .foregroundStyle(CounselTheme.textSecondary)
        }
        .padding(16)
        .background(CounselTheme.raised)
        .overlay(alignment: .top) {
            Rectangle().fill(CounselTheme.hairline).frame(height: 1)
        }
    }
}

// MARK: - PatternRow

/// One editable vocabulary row: the term, its token type, and a case toggle.
private struct PatternRow: View {
    @Binding var pattern: CustomPattern

    /// The types a user can sensibly assign to a custom term.
    private static let assignableTypes: [EntityType] = [
        .person, .company, .address, .email, .phone,
        .bankAccount, .nationalID, .uscc, .amount, .date, .unknown
    ]

    var body: some View {
        HStack(spacing: 10) {
            TextField("Term to redact", text: $pattern.text)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 200)

            Picker("", selection: $pattern.type) {
                ForEach(Self.assignableTypes, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .labelsHidden()
            .frame(width: 150)

            Toggle("Aa", isOn: $pattern.caseSensitive)
                .toggleStyle(.button)
                .help("Match letter case exactly")
        }
        .padding(.vertical, 3)
    }
}
