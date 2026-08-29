//
//  ModelManagementView.swift
//  LDAUI
//
//  The Manage Models sheet: every model, what it is good and bad at in terms a
//  lawyer can act on, and download or remove.
//
//  Copy comes from docs/design/model-management-prd.md section 5. It is written
//  in consequences rather than scores, because "F1 0.954" tells a lawyer
//  nothing, while "about one flag in fifteen is something you will dismiss"
//  tells them how their afternoon will go.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Annotations

/// The plain-language description of one model.
///
/// Kept beside the view rather than in Models.json: it is product copy that
/// changes with wording review, not data that changes with a model release, and
/// putting prose in the manifest invites shipping an unreviewed string.
enum ModelAnnotation {

    static func body(for level: DetectionLevel) -> String {
        switch level {
        case .patternsOnly:
            return ""
        case .quick:
            return "Finds names, companies, and addresses on every kind of contract we "
                + "tested, and it is the only setting that runs on a 16 GB Mac. On two "
                + "full agreements, one English and one Chinese, it found 35 of the 36 "
                + "names, companies, and addresses that had to be caught. It is the "
                + "least precise of the three: about one flag in five is something you "
                + "will look at and dismiss, so reviewing takes longer than waiting does."
        case .balanced:
            return "The best all round choice when your Mac has the memory. It also "
                + "found 35 of 36, and it is by far the tidiest to review: only about "
                + "one flag in fifteen is something you will dismiss. It reports what it "
                + "finds in exactly the wording of your document, so nothing is lost "
                + "between finding a name and redacting it. The one it missed was a "
                + "Chinese bank branch name, so on Chinese documents prefer Most "
                + "thorough when the document matters."
        case .mostThorough:
            return "The only setting that missed nothing. On the same two agreements it "
                + "found all 36 names, companies, and addresses, including the ones Quick "
                + "and Balanced each missed. You pay for that twice: it takes about twice "
                + "as long as Balanced, and it flags more that you will dismiss, roughly "
                + "one in eight. Choose it for the document you cannot afford to get wrong."
        }
    }

    /// "2.74 GB download   ~8.5 GB of memory   ~2 min 15 sec a contract"
    static func facts(for tier: ModelTier, bundled: Bool) -> String {
        let size = bundled
            ? "\(tier.downloadSizeDescription), inside the app"
            : "\(tier.downloadSizeDescription) download"
        let memory = String(format: "~%.1f GB of memory", tier.peakRSSGB)
        return "\(size)   \(memory)   ~\(duration(tier.secondsPerDocument)) a contract"
    }

    private static func duration(_ seconds: Int) -> String {
        if seconds < 90 { return "\(seconds) seconds" }
        let m = seconds / 60, s = seconds % 60
        return s == 0 ? "\(m) min" : "\(m) min \(s) sec"
    }
}

// MARK: - Sheet

/// Lists every model with its annotation and offers download or removal.
public struct ModelManagementView: View {

    @Environment(\.dismiss) private var dismiss
    // Injected, NOT owned. A sheet-owned installer meant closing the sheet
    // orphaned an in-flight download (URLSession retains its delegate, so it ran
    // to completion invisibly) and reopening showed Download again, starting a
    // second copy of the same multi-gigabyte file.
    @ObservedObject var installer: ModelInstaller
    @AppStorage(AISettings.detectionLevelKey) private var levelRaw = DetectionLevel.quick.rawValue
    @AppStorage(AISettings.customModelPathKey) private var customModelPath = ""

    /// Set while a scan is running, so removal can be refused with a reason.
    private let isBusyElsewhere: Bool

    @State private var pendingRemoval: ModelTier?
    @State private var lastReclaimed: String?

    private let catalog = ModelCatalog.load()
    private let installedGB = MemoryGate.installedGB()

    public init(installer: ModelInstaller, isBusyElsewhere: Bool) {
        self.installer = installer
        self.isBusyElsewhere = isBusyElsewhere
    }

    private var level: DetectionLevel { DetectionLevel(rawValue: levelRaw) ?? .quick }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(DetectionLevel.modelLevels, id: \.rawValue) { lvl in
                        if let tier = catalog.tier(for: lvl) {
                            modelRow(lvl, tier)
                            Divider().padding(.vertical, 4)
                        }
                    }
                    customModelSection
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 520, idealHeight: 640)
        .background(CounselTheme.paper)
        .confirmationDialog(
            removalTitle,
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let tier = pendingRemoval {
                Button(removalButtonTitle(for: tier), role: .destructive) { confirmRemoval(tier) }
                Button("Cancel", role: .cancel) { pendingRemoval = nil }
            }
        } message: {
            if let tier = pendingRemoval { Text(removalMessage(for: tier)) }
        }
    }

    // MARK: Header and footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Models")
                    .font(.system(.title2, design: .serif))
                    .foregroundStyle(CounselTheme.textPrimary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            // The full statement, verbatim. Five falsifiable facts: scope,
            // trigger, destination, duration, payload.
            Text("Your documents never leave this Mac. Detection, redaction, and the "
                + "encrypted mapping all run here, and nothing about a document is ever "
                + "sent anywhere. LDA reaches the network for exactly one thing: fetching "
                + "a detection model file when you press Download. It connects only to "
                + "huggingface.co, only while a download you started is running, and it "
                + "sends nothing but the request for that file.")
                .font(.caption)
                .foregroundStyle(CounselTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: Binding(
                get: { AISettings.isOfflineMode() },
                set: { UserDefaults.standard.set($0, forKey: AISettings.offlineModeKey) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Offline mode")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(CounselTheme.textPrimary)
                    Text("Refuse all network requests, including model downloads. "
                        + "This is a setting inside LDA, not a firewall.")
                        .font(.caption2)
                        .foregroundStyle(CounselTheme.textSecondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(AISettings.managedOfflineMode() != nil)
            .help(AISettings.managedOfflineMode() != nil
                  ? "Your organisation has set this and it cannot be changed here."
                  : "Stop LDA making any network request")

            Text("Which should I choose?")
                .font(.callout.weight(.semibold))
                .foregroundStyle(CounselTheme.textPrimary)
            Text("Quick is built in and works on every Mac LDA supports. With 24 GB of "
                + "memory or more, Balanced finds the same amount and leaves you far less "
                + "to dismiss. Most thorough is the only one that missed nothing in our "
                + "testing.")
                .font(.caption)
                .foregroundStyle(CounselTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }

    private var footer: some View {
        HStack {
            Text(footerText)
                .font(.caption)
                .foregroundStyle(CounselTheme.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// Reclaimable bytes only. A bundled model is deliberately excluded: a size
    /// printed next to a Remove button that cannot act on it is a lie.
    private var footerText: String {
        let downloaded = catalog.tiers.filter {
            !ModelCatalog.isBundled($0) && ModelCatalog.isInstalled($0)
        }
        let total = downloaded.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let size = total == 0
            ? "0 bytes"
            : ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        var text = "Models live inside LDA's own folder on this Mac. \(size) downloaded."
        if let lastReclaimed { text += "  Freed \(lastReclaimed)." }
        return text
    }

    // MARK: Rows

    @ViewBuilder
    private func modelRow(_ lvl: DetectionLevel, _ tier: ModelTier) -> some View {
        let bundled = ModelCatalog.isBundled(tier)
        let installed = bundled || ModelCatalog.isInstalled(tier)
        let availability = MemoryGate.availability(for: tier, installedGB: installedGB)
        let phase = installer.phase(for: tier)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(lvl.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(CounselTheme.textPrimary)
                Text(tier.fileName.replacingOccurrences(of: "-Q4_K_M.gguf", with: "")
                        .replacingOccurrences(of: "-UD-Q3_K_XL.gguf", with: ""))
                    .font(.caption)
                    .foregroundStyle(CounselTheme.textSecondary)
                Spacer()
                if bundled { tag("Built in") }
                if level == lvl && customModelPath.isEmpty { tag("In use", tone: CounselTheme.inkAccent) }
            }

            Text(ModelAnnotation.body(for: lvl))
                .font(.caption)
                .foregroundStyle(CounselTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(ModelAnnotation.facts(for: tier, bundled: bundled))
                .font(.caption2)
                .foregroundStyle(CounselTheme.textSecondary)

            Text(MemoryGate.requirementText(for: tier, installedGB: installedGB))
                .font(.caption2)
                .foregroundStyle(availability.isSelectable
                                 ? CounselTheme.textSecondary : CounselTheme.danger)

            statusLine(lvl, tier, bundled: bundled, installed: installed,
                       availability: availability, phase: phase)

            if let redundant = ModelCatalog.redundantContainerCopy(for: tier) {
                HStack(spacing: 10) {
                    Text("A downloaded copy of \(lvl.displayName) is also on this Mac. "
                        + "It is not needed because \(lvl.displayName) is built into the app.")
                        .font(.caption2)
                        .foregroundStyle(CounselTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Remove downloaded copy") {
                        if let bytes = installer.removeRedundantCopy(tier) {
                            lastReclaimed = ByteCountFormatter.string(
                                fromByteCount: bytes, countStyle: .file)
                        }
                    }
                    .disabled(isBusyElsewhere)
                }
                .help(redundant.path)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func statusLine(
        _ lvl: DetectionLevel,
        _ tier: ModelTier,
        bundled: Bool,
        installed: Bool,
        availability: TierAvailability,
        phase: ModelInstallPhase
    ) -> some View {
        switch phase {
        case let .downloading(fraction, received, expected):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: fraction)
                HStack {
                    Text("\(ByteCountFormatter.string(fromByteCount: received, countStyle: .file))"
                        + " of \(ByteCountFormatter.string(fromByteCount: expected, countStyle: .file))")
                        .font(.caption2).foregroundStyle(CounselTheme.textSecondary)
                    Spacer()
                    Button("Cancel") { installer.cancel(tier) }
                }
            }
        case .verifying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking the file is exactly what it should be")
                    .font(.caption2).foregroundStyle(CounselTheme.textSecondary)
            }
        case let .failed(error):
            VStack(alignment: .leading, spacing: 6) {
                Text(error.message)
                    .font(.caption2).foregroundStyle(CounselTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                if error.isRetryable {
                    Button("Try Again") { installer.install(tier) }
                }
            }
        default:
            if bundled {
                Text("Built in and verified. Part of the app, so it cannot be removed.")
                    .font(.caption2).foregroundStyle(CounselTheme.textSecondary)
            } else if installed {
                HStack(spacing: 10) {
                    Text("Downloaded and verified.")
                        .font(.caption2).foregroundStyle(CounselTheme.textSecondary)
                    Button("Remove") { pendingRemoval = tier }
                        .disabled(isBusyElsewhere)
                        .help(isBusyElsewhere
                              ? "Finish or stop the current scan first."
                              : "Delete this model and free the space")
                }
            } else if !availability.isSelectable {
                Text("Cannot run on this Mac, so it is not offered for download.")
                    .font(.caption2).foregroundStyle(CounselTheme.danger)
            } else {
                Button("Download \(tier.downloadSizeDescription)") { installer.install(tier) }
            }
        }
    }

    private var customModelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Use another model")
                .font(.body.weight(.semibold))
                .foregroundStyle(CounselTheme.textPrimary)
            HStack(alignment: .top) {
                Text("Any local GGUF file. LDA cannot tell you how well it will work, how "
                    + "long it will take, or how much memory it needs.")
                    .font(.caption)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button("Choose File\u{2026}") { chooseCustomModel() }
            }
            if !customModelPath.isEmpty {
                HStack(spacing: 10) {
                    Text((customModelPath as NSString).lastPathComponent)
                        .font(.caption2).foregroundStyle(CounselTheme.textSecondary)
                    Button("Stop Using It") {
                        AISettings.setCustomModel(url: nil)
                        customModelPath = ""
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    private func tag(_ text: String, tone: Color = CounselTheme.textSecondary) -> some View {
        Text(text)
            .font(.caption2).foregroundStyle(tone)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(tone.opacity(0.4), lineWidth: 1))
    }

    // MARK: Removal

    private var removalTitle: String {
        guard let tier = pendingRemoval else { return "Remove model" }
        return "Remove \(tier.displayName)?"
    }

    /// The destination is computed BEFORE the click so the button can name it.
    private func demotionTarget(for tier: ModelTier) -> DetectionLevel {
        AISettings.bestAvailableLevel(
            catalog: catalog, installedGB: installedGB, notAbove: tier.detectionLevel
        )
    }

    private func removalButtonTitle(for tier: ModelTier) -> String {
        guard tier.detectionLevel == level else { return "Remove" }
        return demotionTarget(for: tier) == .patternsOnly
            ? "Remove and stop finding names"
            : "Remove and switch"
    }

    private func removalMessage(for tier: ModelTier) -> String {
        let freed = ByteCountFormatter.string(fromByteCount: tier.sizeBytes, countStyle: .file)
        guard tier.detectionLevel == level else {
            return "This frees \(freed). You can download it again later."
        }
        let target = demotionTarget(for: tier)
        if target == .patternsOnly {
            return "This is the model you are using. Removing it frees \(freed), and "
                + "detection drops to patterns only: emails, phones, dates, amounts, and "
                + "ID numbers. Names, companies, and addresses will no longer be found."
        }
        return "This is the model you are using. Removing it frees \(freed) and switches "
            + "detection to \(target.displayName)."
    }

    private func confirmRemoval(_ tier: ModelTier) {
        let wasInUse = tier.detectionLevel == level
        let target = demotionTarget(for: tier)
        if let bytes = installer.remove(tier) {
            lastReclaimed = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        if wasInUse {
            AISettings.setDetectionLevel(target)
            levelRaw = target.rawValue
        }
        pendingRemoval = nil
    }

    private func chooseCustomModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let gguf = UTType(filenameExtension: "gguf") { panel.allowedContentTypes = [gguf] }
        panel.message = "Choose a local GGUF model. It will run fully on this Mac."
        panel.prompt = "Use Model"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        AISettings.setCustomModel(url: url)
        customModelPath = url.path
    }
}
