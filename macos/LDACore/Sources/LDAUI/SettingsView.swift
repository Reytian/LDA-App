//
//  SettingsView.swift
//  LDAUI
//
//  The Settings window (Cmd+,), in two tabs:
//    - Vocabulary: user-defined terms (literal or regex) to always redact.
//    - Learned: what the app has learned from the user's accept and reject
//      decisions, with the ability to forget entries.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import SwiftUI
import LDACore

/// The Settings root: a two-tab editor for the custom vocabulary and the learned
/// terms.
public struct SettingsView: View {
    @ObservedObject private var patterns: CustomPatternStore
    @ObservedObject private var learning: LearningStore

    public init(patterns: CustomPatternStore, learning: LearningStore) {
        self.patterns = patterns
        self.learning = learning
    }

    public var body: some View {
        TabView {
            VocabularyTab(store: patterns)
                .tabItem { Label("Vocabulary", systemImage: "text.book.closed") }
            LearnedTab(store: learning)
                .tabItem { Label("Learned", systemImage: "brain") }
        }
        .frame(width: 580, height: 440)
        .background(CounselTheme.appSurface)
    }
}

// MARK: - Vocabulary tab

private struct VocabularyTab: View {
    @ObservedObject var store: CustomPatternStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Always redact these")
                    .font(.system(.headline, design: .serif))
                    .foregroundStyle(CounselTheme.textPrimary)
                Text("Literal terms or regular expressions (for example a matter number M-\\d{5}). Useful for project codenames, client names, and internal labels.")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            if store.patterns.isEmpty {
                placeholder("No custom terms yet", systemImage: "text.badge.plus")
            } else {
                List {
                    ForEach($store.patterns) { $pattern in
                        PatternRow(pattern: $pattern)
                    }
                    .onDelete { store.remove(atOffsets: $0) }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }

            HStack {
                Button { store.add() } label: { Label("Add Term", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                    .tint(CounselTheme.inkAccent)
                Spacer()
                Text("\(store.activePatterns.count) active")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(CounselTheme.textSecondary)
            }
            .padding(16)
            .background(CounselTheme.raised)
            .overlay(alignment: .top) { Rectangle().fill(CounselTheme.hairline).frame(height: 1) }
        }
    }
}

/// One editable vocabulary row: the term, a regex toggle, its token type, and a
/// case toggle. A failing regex is flagged.
private struct PatternRow: View {
    @Binding var pattern: CustomPattern

    private static let assignableTypes: [EntityType] = [
        .person, .company, .address, .email, .phone,
        .bankAccount, .nationalID, .uscc, .amount, .date, .unknown
    ]

    var body: some View {
        HStack(spacing: 8) {
            TextField(pattern.isRegex ? "Regular expression" : "Term to redact", text: $pattern.text)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 170)
                .overlay(alignment: .trailing) {
                    if pattern.isInvalidRegex {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(CounselTheme.danger)
                            .help("Invalid regular expression")
                            .padding(.trailing, 6)
                    }
                }

            Toggle(".*", isOn: $pattern.isRegex)
                .toggleStyle(.button)
                .help("Treat the term as a regular expression")

            Picker("", selection: $pattern.type) {
                ForEach(Self.assignableTypes, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 140)

            Toggle("Aa", isOn: $pattern.caseSensitive)
                .toggleStyle(.button)
                .help("Match letter case exactly")
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Learned tab

private struct LearnedTab: View {
    @ObservedObject var store: LearningStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What LDA has learned")
                    .font(.system(.headline, design: .serif))
                    .foregroundStyle(CounselTheme.textPrimary)
                Text("LDA remembers what you accept and reject. Accepted names get auto-redacted next time; rejected ones stop appearing. Forget any entry to undo it.")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            if store.sortedTerms.isEmpty {
                placeholder("Nothing learned yet. Anonymize and export a few documents.", systemImage: "brain")
            } else {
                List {
                    ForEach(store.sortedTerms) { term in
                        LearnedRow(term: term) { store.forget(term.id) }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }

            HStack {
                Spacer()
                Button(role: .destructive) { store.reset() } label: {
                    Label("Forget All", systemImage: "trash")
                }
                .disabled(store.sortedTerms.isEmpty)
            }
            .padding(16)
            .background(CounselTheme.raised)
            .overlay(alignment: .top) { Rectangle().fill(CounselTheme.hairline).frame(height: 1) }
        }
    }
}

private struct LearnedRow: View {
    let term: LearnedTerm
    let onForget: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(CounselTheme.color(for: term.type))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(term.value)
                    .font(.system(.callout, design: .serif))
                    .foregroundStyle(CounselTheme.textPrimary)
                    .lineLimit(1)
                Text("\(term.type.rawValue)  \u{00B7}  kept \(term.acceptCount), rejected \(term.rejectCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(CounselTheme.textSecondary)
            }
            Spacer(minLength: 8)
            decisionBadge
            Button { onForget() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(CounselTheme.textSecondary)
                .help("Forget this term")
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var decisionBadge: some View {
        switch term.decision {
        case .redact:
            badge("auto-redact", CounselTheme.inkAccent)
        case .suppress:
            badge("hidden", CounselTheme.textSecondary)
        case .neutral:
            badge("learning", CounselTheme.textSecondary)
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

// MARK: - Shared

@ViewBuilder
private func placeholder(_ text: String, systemImage: String) -> some View {
    VStack(spacing: 8) {
        Image(systemName: systemImage)
            .font(.system(size: 28, weight: .light))
            .foregroundStyle(CounselTheme.textSecondary)
        Text(text)
            .font(.callout)
            .foregroundStyle(CounselTheme.textSecondary)
            .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
}
