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

import AppKit
import SwiftUI
import UniformTypeIdentifiers
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
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            AITab()
                .tabItem { Label("AI", systemImage: "cpu") }
            VocabularyTab(store: patterns)
                .tabItem { Label("Vocabulary", systemImage: "text.book.closed") }
            LearnedTab(store: learning)
                .tabItem { Label("Learned", systemImage: "brain") }
            SharingTab(patterns: patterns, learning: learning)
                .tabItem { Label("Sharing", systemImage: "square.and.arrow.up.on.square") }
        }
        .frame(width: 580, height: 440)
        .background(CounselTheme.appSurface)
    }
}

// MARK: - AI tab

/// The detection model and quality/speed settings (R3, R14). The model always
/// runs fully on this Mac; swapping only changes WHICH local model runs.
private struct AITab: View {
    @AppStorage(AISettings.customModelPathKey) private var customModelPath = ""
    @AppStorage(AISettings.detectionModeKey) private var detectionModeRaw = DetectionMode.thorough.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Detection model")
                    .font(.system(.headline, design: .serif))
                    .foregroundStyle(CounselTheme.textPrimary)
                Text(modelDescription)
                    .font(.callout)
                    .foregroundStyle(modelMissing ? CounselTheme.danger : CounselTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Button {
                    chooseModel()
                } label: {
                    Label("Choose Model\u{2026}", systemImage: "folder")
                }
                .help("Pick another local GGUF model to run instead of the bundled one")

                if !customModelPath.isEmpty {
                    Button("Use Bundled Model") {
                        customModelPath = ""
                    }
                    .help("Go back to the tuned model that ships with the app")
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Quality and speed")
                    .font(.system(.headline, design: .serif))
                    .foregroundStyle(CounselTheme.textPrimary)

                Picker("Detection", selection: $detectionModeRaw) {
                    ForEach(DetectionMode.allCases, id: \.rawValue) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                Text("Thorough runs the on-device AI to find people, companies, and addresses, "
                    + "and takes longer on big documents. Fast is instant but pattern-only: "
                    + "emails, phones, dates, amounts, and IDs.")
                    .font(.caption)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Label("Every model runs fully on this Mac. Nothing leaves your computer.",
                  systemImage: "lock.laptopcomputer")
                .font(.caption)
                .foregroundStyle(CounselTheme.textSecondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// What the active model line should say.
    private var modelDescription: String {
        if customModelPath.isEmpty {
            return "Using the bundled tuned model (the default)."
        }
        if FileManager.default.fileExists(atPath: customModelPath) {
            return "Using a custom model: \((customModelPath as NSString).abbreviatingWithTildeInPath)"
        }
        return "The chosen model is missing: \((customModelPath as NSString).abbreviatingWithTildeInPath). "
            + "The bundled model is used instead."
    }

    private var modelMissing: Bool {
        !customModelPath.isEmpty && !FileManager.default.fileExists(atPath: customModelPath)
    }

    private func chooseModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let gguf = UTType(filenameExtension: "gguf") {
            panel.allowedContentTypes = [gguf]
        }
        panel.message = "Choose a local GGUF model. It will run fully on this Mac."
        panel.prompt = "Use Model"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        customModelPath = url.path
    }
}

// MARK: - Sharing tab

/// Export the vocabulary and learned memory to one file, or merge a shared file
/// in. Lets a team share one list, or a user carry their setup to another device.
private struct SharingTab: View {
    @ObservedObject var patterns: CustomPatternStore
    @ObservedObject var learning: LearningStore
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Share or move your setup")
                    .font(.system(.headline, design: .serif))
                    .foregroundStyle(CounselTheme.textPrimary)
                Text("Export your custom vocabulary and learned terms to one file. Share it with your team or import it on another Mac. Importing merges into what you already have; nothing is overwritten or removed.")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Button { exportProfile() } label: {
                    Label("Export Profile", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .tint(CounselTheme.inkAccentFill)

                Button { importProfile() } label: {
                    Label("Import Profile", systemImage: "square.and.arrow.down")
                }
            }

            Text("\(patterns.patterns.count) vocabulary terms  \u{00B7}  \(learning.allTerms.count) learned entries")
                .font(.caption.monospacedDigit())
                .foregroundStyle(CounselTheme.textSecondary)

            if let status {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textPrimary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(CounselTheme.raised))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(CounselTheme.hairline, lineWidth: 1))
            }

            Text("The file is plain JSON (a glossary of terms to redact). Treat it like any shared list that may name clients or matters.")
                .font(.caption)
                .foregroundStyle(CounselTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func exportProfile() {
        let profile = VocabularyProfile(
            exportedAtISO8601: ISO8601DateFormatter().string(from: Date()),
            patterns: patterns.patterns,
            learned: learning.allTerms
        )
        guard let data = try? Portability.encode(profile) else {
            status = "Could not prepare the profile."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "LDA-Vocabulary.json"
        panel.message = "Save your vocabulary and learned terms to share or move."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            status = "Exported \(profile.patterns.count) vocabulary terms and \(profile.learned.count) learned entries."
        } catch {
            status = "Export failed. \(error.localizedDescription)"
        }
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a shared LDA vocabulary file to merge."
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url),
              let profile = try? Portability.decode(data) else {
            status = "That file is not a valid LDA vocabulary profile."
            return
        }
        let added = patterns.merge(profile.patterns)
        let merged = learning.merge(profile.learned)
        status = "Imported \(added) new vocabulary "
            + (added == 1 ? "term" : "terms")
            + " and merged \(merged) learned "
            + (merged == 1 ? "entry." : "entries.")
    }
}

// MARK: - General tab

private struct GeneralTab: View {
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Appearance")
                .font(.system(.headline, design: .serif))
                .foregroundStyle(CounselTheme.textPrimary)

            Picker("Theme", selection: appearanceBinding) {
                ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320, alignment: .leading)

            Text("System follows your Mac's light or dark setting. Choose Light or Dark to override it.")
                .font(.callout)
                .foregroundStyle(CounselTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var appearanceBinding: Binding<AppearanceMode> {
        Binding(
            get: { AppearanceMode.from(rawValue: appearanceRaw) },
            set: { appearanceRaw = $0.rawValue }
        )
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
                    .tint(CounselTheme.inkAccentFill)
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
                            .accessibilityLabel("Invalid regular expression")
                            .padding(.trailing, 6)
                    }
                }

            Toggle(".*", isOn: $pattern.isRegex)
                .toggleStyle(.button)
                .help("Treat the term as a regular expression")
                .accessibilityLabel("Regular expression")

            Picker("", selection: $pattern.type) {
                ForEach(Self.assignableTypes, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 140)
            .accessibilityLabel("Token type")

            Toggle("Aa", isOn: $pattern.caseSensitive)
                .toggleStyle(.button)
                .help("Match letter case exactly")
                .accessibilityLabel("Case sensitive")
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
            Button { onForget() } label: {
                Image(systemName: "xmark.circle.fill")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(CounselTheme.textSecondary)
            .help("Forget this term")
            .accessibilityLabel("Forget \(term.value)")
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
