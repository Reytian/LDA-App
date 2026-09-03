//
//  SettingsView.swift
//  LDAUI
//
//  The Settings window (Cmd+,), in two tabs:
//    - Vocabulary: user-defined terms (literal or regex) to always redact.
//    - Learned: what the app has learned from the user's accept and reject
//      decisions, with the ability to forget entries.
//
//  Code comments stay in English. User-facing copy is localized.
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
    /// Owned by the app so a model download outlives this window.
    @ObservedObject private var installer: ModelInstaller
    /// Owned by the app so a model import outlives this window.
    @ObservedObject private var importer: ModelImporter
    /// True while a scan is running, which gates model removal.
    private let isScanning: Bool

    public init(
        patterns: CustomPatternStore,
        learning: LearningStore,
        installer: ModelInstaller,
        importer: ModelImporter,
        isScanning: Bool
    ) {
        self.patterns = patterns
        self.learning = learning
        self.installer = installer
        self.importer = importer
        self.isScanning = isScanning
    }

    public var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label { L10n.text("General") } icon: { Image(systemName: "gearshape") } }
            AITab(installer: installer, importer: importer, isScanning: isScanning)
                .tabItem { Label { L10n.text("AI") } icon: { Image(systemName: "cpu") } }
            VocabularyTab(store: patterns)
                .tabItem { Label { L10n.text("Vocabulary") } icon: { Image(systemName: "text.book.closed") } }
            LearnedTab(store: learning)
                .tabItem { Label { L10n.text("Learned") } icon: { Image(systemName: "brain") } }
            SharingTab(patterns: patterns, learning: learning)
                .tabItem { Label { L10n.text("Sharing") } icon: { Image(systemName: "square.and.arrow.up.on.square") } }
            HistoryTab()
                .tabItem { Label { L10n.text("History") } icon: { Image(systemName: "clock.arrow.circlepath") } }
        }
        // Resizable, from the UI/UX audit on feat/lda-macos-core. Kept through
        // the merge: the model ladder makes this panel taller, so a fixed
        // 440pt height would clip the lowest rung.
        .frame(
            minWidth: 580,
            idealWidth: 700,
            maxWidth: .infinity,
            minHeight: 440,
            idealHeight: 540,
            maxHeight: .infinity
        )
        .background(CounselTheme.appSurface)
    }
}

// MARK: - History tab (R18)

/// The per-session records: what was protected and what was restored, so the
/// user can review and trust each round-trip. Value-free by construction; the
/// files are encrypted on disk.
private struct HistoryTab: View {
    @State private var records: [SessionRecord] = []
    @State private var loadFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            L10n.text("Session history")
                .font(.system(.headline, design: .serif))
                .foregroundStyle(CounselTheme.textPrimary)
            L10n.text("Each round-trip records what was protected and what was restored. Records never contain the sensitive values themselves and stay encrypted on this Mac.")
                .font(.callout)
                .foregroundStyle(CounselTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if records.isEmpty {
                Spacer()
                Group {
                    if loadFailed {
                        L10n.text("The history could not be read.")
                    } else {
                        L10n.text("No sessions recorded yet. Records appear after your first Export for AI.")
                    }
                }
                .font(.callout)
                .foregroundStyle(CounselTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                List(records) { record in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(verbatim: SettingsHistoryPresentation.displayDate(
                                record.createdAtISO8601
                            ))
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(CounselTheme.textPrimary)
                            if let client = record.clientLabel {
                                L10n.text("\u{00B7}  %@", client as NSString)
                                    .font(.callout)
                                    .foregroundStyle(CounselTheme.textSecondary)
                            }
                            Spacer()
                            Button {
                                delete(record)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .l10nHelp("Delete this record")
                        }
                        Text(verbatim: documentsLine(record))
                            .font(CounselTheme.Typography.supporting)
                            .foregroundStyle(CounselTheme.textSecondary)
                            .lineLimit(2)
                        Text(verbatim: restoresLine(record))
                            .font(CounselTheme.Typography.supporting)
                            .foregroundStyle(CounselTheme.textSecondary)
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { reload() }
    }

    private func reload() {
        do {
            records = try SessionRecordStore().list()
            loadFailed = false
        } catch {
            records = []
            loadFailed = true
        }
    }

    private func delete(_ record: SessionRecord) {
        try? SessionRecordStore().delete(id: record.id)
        reload()
    }

    private func documentsLine(_ record: SessionRecord) -> String {
        let names = record.documents.map { "\($0.name) (\($0.entityCount))" }
        return SettingsHistoryPresentation.documentsLine(
            protectedValueCount: record.protectedValueCount,
            documentSummaries: names
        )
    }

    private func restoresLine(_ record: SessionRecord) -> String {
        let flagged = record.restoreEvents.reduce(0) {
            $0 + $1.orphanCount + $1.suspectCount + $1.ambiguousCount
        }
        let restored = record.restoreEvents.reduce(0) { $0 + $1.restoredCount }
        return SettingsHistoryPresentation.restoresLine(
            restoreCount: record.restoreEvents.count,
            restoredValueCount: restored,
            flaggedCount: flagged
        )
    }
}

// MARK: - AI tab

/// The detection ladder. One control answers "how hard should LDA look for the
/// names, companies, and addresses that patterns cannot catch". Every rung runs
/// fully on this Mac; a higher rung only changes WHICH local model runs and how
/// long it takes. See docs/design/model-tiers-prd.md.
private struct AITab: View {
    @Environment(\.appLanguage) private var appLanguage

    /// App-owned, so a download survives closing this window.
    @ObservedObject var installer: ModelInstaller
    /// App-owned, so an import survives closing this window.
    @ObservedObject var importer: ModelImporter
    /// True while a scan is running. Removing a model mid-scan would report
    /// disk reclaimed that llama.cpp still has mmapped.
    let isScanning: Bool

    @AppStorage(AISettings.detectionLevelKey) private var levelRaw = DetectionLevel.quick.rawValue
    @AppStorage(AISettings.customModelPathKey) private var customModelPath = ""

    @State private var showLdaV2Notice = false
    @State private var showManageModels = false

    private let catalog = ModelCatalog.load()
    private let installedGB = MemoryGate.installedGB()

    private var level: DetectionLevel {
        DetectionLevel(rawValue: levelRaw) ?? .quick
    }

    /// Run the legacy migration before the panel reads the stored level.
    ///
    /// @AppStorage reads the key directly, so without this a user upgrading
    /// from detectionMode = "fast" would see Quick selected here while the
    /// resolved setting was Patterns only: the panel would disagree with what
    /// the app actually does.
    private func migrateOnAppear() {
        AISettings.migrateIfNeeded()
        let resolved = AISettings.detectionLevel()
        if resolved.rawValue != levelRaw { levelRaw = resolved.rawValue }
        showLdaV2Notice = AISettings.shouldOfferLdaV2Switch()
    }

    /// Whether Touch ID protection actually took effect on this build.
    @StateObject private var keychainAdvisory = KeychainAdvisoryStore()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    L10n.text("How hard should LDA look?")
                        .font(.system(.headline, design: .serif))
                        .foregroundStyle(CounselTheme.textPrimary)
                    L10n.text("Higher settings find more names, companies, and addresses, and take longer. Detection uses the selected model on this Mac.")
                        .font(.callout)
                        .foregroundStyle(CounselTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if showLdaV2Notice { ldaV2Notice }

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(DetectionLevel.allCases, id: \.rawValue) { rung in
                        rungRow(rung)
                    }
                }

                if !customModelPath.isEmpty {
                    Divider()
                    customModelRow
                }

                Divider()

                HStack(spacing: 12) {
                    Button {
                        showManageModels = true
                    } label: {
                        Label {
                            L10n.text("Manage Models\u{2026}")
                        } icon: {
                            Image(systemName: "square.and.arrow.down")
                        }
                    }
                    .l10nHelp("Download, remove, or choose a different detection model")

                    if !customModelPath.isEmpty {
                        L10n.button("Stop Using It") {
                            AISettings.setCustomModel(url: nil)
                            customModelPath = ""
                        }
                        .l10nHelp("Go back to the model for the selected setting")
                    }
                }

                Label {
                    L10n.text("LDA processes document contents on this Mac. Installing an optional model uses a network connection to fetch its model file.")
                } icon: {
                    Image(systemName: "lock.laptopcomputer")
                }
                    .font(CounselTheme.Typography.supporting)
                    .foregroundStyle(CounselTheme.textSecondary)

                // Settings is where a user comes to check how their data is
                // protected, so an inactive Touch ID gate has to be stated here,
                // not only implied by its absence.
                if let advisory = keychainAdvisory.advisory {
                    Label {
                        Text(verbatim: advisory)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(CounselTheme.Typography.supporting)
                    .foregroundStyle(CounselTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear { migrateOnAppear() }
        .sheet(isPresented: $showManageModels) {
            // Both arguments are required by design: a default would let a call
            // site silently reintroduce the dead-parameter bug this replaced.
            ModelManagementView(
                installer: installer, importer: importer, isBusyElsewhere: isScanning
            )
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func rungRow(_ rung: DetectionLevel) -> some View {
        let tier = catalog.tier(for: rung)
        let availability = tier.map { MemoryGate.availability(for: $0, installedGB: installedGB) }
        // A tier is available when its file is in the container OR inside the
        // app bundle. No model ships inside the app by default, so the container
        // is the usual answer; the bundled check stays because a BUNDLE_MODEL=1
        // single-file build resolves only that way, and marking its one model
        // "Not installed" would leave that build unable to use it.
        let installed = tier.map {
            ModelCatalog.isInstalled($0) || ModelCatalog.isBundled($0)
        } ?? false
        // Patterns only has no tier and is always selectable. A model rung is
        // selectable only when it fits AND its file is present: selecting a rung
        // we cannot actually run produces a silent patterns-only pass, which is
        // the worst outcome this feature can have. Note the nil default is
        // FALSE for model rungs: when the manifest fails to load we must fail
        // closed rather than present a healthy-looking, unrunnable option.
        let selectable: Bool = {
            if rung == .patternsOnly { return true }
            guard let availability else { return false }
            return availability.isSelectable && installed
        }()

        Button {
            guard selectable else { return }
            // PRD 2.4: selecting a named rung clears "use another model",
            // otherwise the ladder shows one thing and runs another.
            AISettings.setCustomModel(url: nil)
            customModelPath = ""
            AISettings.setDetectionLevel(rung)
            levelRaw = rung.rawValue
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: level == rung ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(level == rung ? CounselTheme.inkAccent : CounselTheme.textSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        L10n.text(rung.displayName)
                            .font(.body.weight(.medium))
                            .foregroundStyle(selectable ? CounselTheme.textPrimary : CounselTheme.textSecondary)
                        if tier != nil, installed {
                            badge("Installed", tone: CounselTheme.textSecondary)
                        } else if let tier {
                            verbatimBadge(
                                String(
                                    format: L10n.string("Not installed · %@"),
                                    tier.downloadSizeDescription as NSString
                                ),
                                tone: CounselTheme.textSecondary
                            )
                        }
                        if case .tight = availability {
                            badge("Tight fit", tone: CounselTheme.danger)
                        }
                    }
                    Text(verbatim: OnboardingPresentation.chooseLine(for: rung, language: appLanguage))
                        .font(CounselTheme.Typography.supporting)
                        .foregroundStyle(CounselTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let tier, selectable {
                        L10n.text("About %lld seconds for a short agreement.", Int64(tier.secondsPerDocument))
                            .font(CounselTheme.Typography.supporting)
                            .foregroundStyle(CounselTheme.textSecondary)
                    }
                    if let tier, !selectable {
                        Text(verbatim: MemoryGate.localizedRequirementText(for: tier))
                            .font(CounselTheme.Typography.supporting)
                            .foregroundStyle(CounselTheme.danger)
                    }
                    if tier != nil, !installed {
                        L10n.text("Add the model file to use this setting.")
                            .font(CounselTheme.Typography.supporting)
                            .foregroundStyle(CounselTheme.danger)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!selectable)
        .accessibilityAddTraits(level == rung ? [.isSelected] : [])
    }

    /// One-time offer to leave the retired fine tune. Stated in consequence
    /// terms, not scores: the defect is that a share of what it finds comes back
    /// in a form the app cannot anchor, so those values stay in the document and
    /// never appear in the review list.
    private var ldaV2Notice: some View {
        VStack(alignment: .leading, spacing: 8) {
            L10n.text("Your chosen model leaves some names in the document")
                .font(.callout.weight(.semibold))
                .foregroundStyle(CounselTheme.textPrimary)
            L10n.text("It reports a portion of the names and addresses it finds in a slightly different form from your document, so those are never redacted and never reach your review list. The Quick model does not have this problem and runs at the same speed.")
                .font(CounselTheme.Typography.supporting)
                .foregroundStyle(CounselTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                L10n.button("Switch to Quick") {
                    AISettings.setCustomModel(url: nil)
                    customModelPath = ""
                    AISettings.setDetectionLevel(.quick)
                    levelRaw = DetectionLevel.quick.rawValue
                    AISettings.dismissLdaV2Notice()
                    showLdaV2Notice = false
                }
                .buttonStyle(.borderedProminent)
                L10n.button("Keep using my model") {
                    AISettings.dismissLdaV2Notice()
                    showLdaV2Notice = false
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(CounselTheme.raised))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(CounselTheme.danger.opacity(0.5), lineWidth: 1))
    }

    private var customModelRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                L10n.text("Custom model")
                    .font(.body.weight(.medium))
                    .foregroundStyle(CounselTheme.textPrimary)
                badge("In use", tone: CounselTheme.inkAccent)
            }
            Text(verbatim: (customModelPath as NSString).lastPathComponent)
                .font(.caption)
                .foregroundStyle(CounselTheme.textSecondary)
            L10n.text("LDA cannot estimate speed or memory for a model it does not know. It overrides the setting above.")
                .font(CounselTheme.Typography.supporting)
                .foregroundStyle(CounselTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func badge(_ text: String, tone: Color) -> some View {
        L10n.text(text)
            .font(.caption2)
            .foregroundStyle(tone)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(tone.opacity(0.4), lineWidth: 1))
    }

    private func verbatimBadge(_ text: String, tone: Color) -> some View {
        Text(verbatim: text)
            .font(.caption2)
            .foregroundStyle(tone)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(tone.opacity(0.4), lineWidth: 1))
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
                L10n.text("Share or move your setup")
                    .font(.system(.headline, design: .serif))
                    .foregroundStyle(CounselTheme.textPrimary)
                L10n.text("Export your custom vocabulary and learned terms to one file. Share it with your team or import it on another Mac. Importing merges into what you already have; nothing is overwritten or removed.")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Button { exportProfile() } label: {
                    Label {
                        L10n.text("Export Profile")
                    } icon: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(CounselTheme.inkAccentFill)

                Button { importProfile() } label: {
                    Label {
                        L10n.text("Import Profile")
                    } icon: {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
            }

            Text(verbatim: SettingsSharingPresentation.counts(
                vocabularyCount: patterns.patterns.count,
                learnedCount: learning.allTerms.count
            ))
                .font(CounselTheme.Typography.supporting.monospacedDigit())
                .foregroundStyle(CounselTheme.textSecondary)

            if let status {
                Text(verbatim: status)
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textPrimary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(CounselTheme.raised))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(CounselTheme.hairline, lineWidth: 1))
            }

            L10n.text("The file is plain JSON (a glossary of terms to redact). Treat it like any shared list that may name clients or matters.")
                .font(CounselTheme.Typography.supporting)
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
            status = SettingsSharingPresentation.preparationFailure
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "LDA-Vocabulary.json"
        panel.message = L10n.string("Save your vocabulary and learned terms to share or move.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            status = SettingsSharingPresentation.exported(
                vocabularyCount: profile.patterns.count,
                learnedCount: profile.learned.count
            )
        } catch {
            status = SettingsSharingPresentation.exportFailure(error.localizedDescription)
        }
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.message = L10n.string("Choose a shared LDA vocabulary file to merge.")
        panel.prompt = L10n.string("Import")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url),
              let profile = try? Portability.decode(data) else {
            status = SettingsSharingPresentation.invalidProfile
            return
        }
        let added = patterns.merge(profile.patterns)
        let merged = learning.merge(profile.learned)
        status = SettingsSharingPresentation.imported(
            vocabularyCount: added,
            learnedCount: merged
        )
    }
}

// MARK: - General tab

private struct GeneralTab: View {
    @Environment(\.appLanguage) private var appLanguage

    @AppStorage(AppLanguage.storageKey) private var languageRaw = AppLanguage.system.rawValue
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage(AISettings.outputStyleKey) private var outputStyleRaw = SubstitutionStyle.token.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            L10n.text("Language")
                .font(.system(.headline, design: .serif))
                .foregroundStyle(CounselTheme.textPrimary)

            Picker(selection: languageBinding) {
                ForEach(AppLanguage.allCases) { language in
                    Text(verbatim: language.nativeName(language: appLanguage)).tag(language)
                }
            } label: {
                L10n.text("Language")
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 320, alignment: .leading)

            L10n.text("Choose the language LDA uses for its interface. Follow System uses your Mac language.")
                .font(.callout)
                .foregroundStyle(CounselTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            L10n.text("Appearance")
                .font(.system(.headline, design: .serif))
                .foregroundStyle(CounselTheme.textPrimary)

            Picker(selection: appearanceBinding) {
                ForEach(AppearanceMode.allCases) {
                    Text(verbatim: L10n.string($0.label, language: appLanguage)).tag($0)
                }
            } label: {
                L10n.text("Theme")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320, alignment: .leading)

            L10n.text("System follows your Mac's light or dark setting. Choose Light or Dark to override it.")
                .font(.callout)
                .foregroundStyle(CounselTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            L10n.text("Output style")
                .font(.system(.headline, design: .serif))
                .foregroundStyle(CounselTheme.textPrimary)

            Picker(selection: outputStyleBinding) {
                ForEach(SubstitutionStyle.allCases, id: \.self) { style in
                    Text(verbatim: L10n.string(Self.label(for: style), language: appLanguage)).tag(style)
                }
            } label: {
                L10n.text("Output style")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 380, alignment: .leading)

            Text(verbatim: L10n.string(
                Self.explanation(for: SubstitutionStyle(rawValue: outputStyleRaw) ?? .token),
                language: appLanguage
            ))
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

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { AppLanguage.from(rawValue: languageRaw) },
            set: { languageRaw = $0.rawValue }
        )
    }

    private var outputStyleBinding: Binding<SubstitutionStyle> {
        Binding(
            get: { SubstitutionStyle(rawValue: outputStyleRaw) ?? .token },
            set: { outputStyleRaw = $0.rawValue }
        )
    }

    /// Short picker labels. Internal (not fileprivate) copy lives here because
    /// the style enum itself stays UI-free in the engine.
    static func label(for style: SubstitutionStyle) -> String {
        switch style {
        case .token: return "Placeholders"
        case .pseudonym: return "Pseudonyms"
        case .asterisk: return "Asterisks"
        }
    }

    /// One-sentence explanation per style, shown under the picker.
    static func explanation(for style: SubstitutionStyle) -> String {
        switch style {
        case .token:
            return "Protected values become placeholders like {PERSON_1}. Exact and compact, "
                + "but an external AI sometimes rewrites the braces, and a rewritten "
                + "placeholder cannot be restored."
        case .pseudonym:
            return "Protected values become natural stand-in names like Company A or 甲公司. "
                + "AI tools treat them as names and leave them alone, so documents come back "
                + "restorable even after heavy editing."
        case .asterisk:
            return "Protected values are masked in place, like 张*明 or 138****5678, the form "
                + "courts and regulators expect. Best for sending to a person; if two values "
                + "share one mask, that mask is reported instead of guessed at restore."
        }
    }
}

// MARK: - Vocabulary tab

private struct VocabularyTab: View {
    @ObservedObject var store: CustomPatternStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                L10n.text("Always redact these")
                    .font(.system(.headline, design: .serif))
                    .foregroundStyle(CounselTheme.textPrimary)
                L10n.text("Literal terms or regular expressions (for example a matter number M-\\d{5}). Useful for project codenames, client names, and internal labels.")
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
                Button { store.add() } label: {
                    Label {
                        L10n.text("Add Term")
                    } icon: {
                        Image(systemName: "plus")
                    }
                }
                    .buttonStyle(.borderedProminent)
                    .tint(CounselTheme.inkAccentFill)
                Spacer()
                L10n.text("%lld active", Int64(store.activePatterns.count))
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
    @Environment(\.appLanguage) private var appLanguage

    @Binding var pattern: CustomPattern

    private static let assignableTypes: [EntityType] = AssignableEntityTypes.vocabulary

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if pattern.isRegex {
                    TextField(L10n.string("Regular expression", language: appLanguage), text: $pattern.text)
                } else {
                    TextField(L10n.string("Term to redact", language: appLanguage), text: $pattern.text)
                }
            }
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 170)
                .overlay(alignment: .trailing) {
                    if pattern.isInvalidRegex {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(CounselTheme.danger)
                            .l10nHelp("Invalid regular expression")
                            .accessibilityLabel(Text(verbatim: L10n.string("Invalid regular expression", language: appLanguage)))
                            .padding(.trailing, 6)
                    }
                }

            Toggle(isOn: $pattern.isRegex) {
                Text(verbatim: ".*")
            }
                .toggleStyle(.button)
                .l10nHelp("Treat the term as a regular expression")
                .accessibilityLabel(Text(verbatim: L10n.string("Regular expression", language: appLanguage)))

            Picker(selection: $pattern.type) {
                ForEach(Self.assignableTypes, id: \.self) {
                    Text(verbatim: EntityTypePresentation.localizedName(for: $0, language: appLanguage)).tag($0)
                }
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .frame(width: 140)
            .accessibilityLabel(Text(verbatim: L10n.string("Token type", language: appLanguage)))

            Toggle(isOn: $pattern.caseSensitive) {
                Text(verbatim: "Aa")
            }
                .toggleStyle(.button)
                .l10nHelp("Match letter case exactly")
                .accessibilityLabel(Text(verbatim: L10n.string("Case sensitive", language: appLanguage)))
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
                L10n.text("What LDA has learned")
                    .font(.system(.headline, design: .serif))
                    .foregroundStyle(CounselTheme.textPrimary)
                L10n.text("LDA remembers what you accept and reject. Accepted names get auto-redacted next time; rejected ones stop appearing. Forget any entry to undo it.")
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
                    Label {
                        L10n.text("Forget All")
                    } icon: {
                        Image(systemName: "trash")
                    }
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
    @Environment(\.appLanguage) private var appLanguage

    let term: LearnedTerm
    let onForget: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(CounselTheme.color(for: term.type))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: term.value)
                    .font(.system(.callout, design: .serif))
                    .foregroundStyle(CounselTheme.textPrimary)
                    .lineLimit(1)
                Text(verbatim: String(
                    format: L10n.string("%@  \u{00B7}  kept %lld, rejected %lld", language: appLanguage),
                    EntityTypePresentation.localizedName(for: term.type, language: appLanguage) as NSString,
                    Int64(term.acceptCount),
                    Int64(term.rejectCount)
                ))
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
            .l10nHelp("Forget this term")
            .accessibilityLabel(Text(verbatim: L10n.formatted("Forget %@", language: appLanguage, [term.value as NSString])))
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
        L10n.text(text)
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
        L10n.text(text)
            .font(.callout)
            .foregroundStyle(CounselTheme.textSecondary)
            .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
}
