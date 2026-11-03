//
//  BatchAnonymizeView.swift
//  LDAUI
//
//  The batch window (File > Batch Anonymize...): one source folder in, one
//  redacted copy and mapping per document out, with no review step and no
//  confirmation (BatchAnonymizer). It runs the built-in LDA V4 model and
//  protects run-in values automatically (UnlocatedValuePolicy.protect), the
//  same batch `lda batch` runs. The batch_anonymize MCP tool opens it too;
//  the next batch then answers that request with counts (MCPBatchHandoff).
//
//  Mappings are sealed under the Keychain account the app's Restore looks
//  up (SessionModel.sidecarKeychainAccount), or under one passphrase typed
//  here. A Keychain-sealed mapping restores only in LDA on this Mac.
//
//  The window shows only the two folders and Start. The output style (the
//  Settings choice unless changed), the passphrase and redoing finished
//  documents sit under More options. After a run it lists only the
//  documents that need attention; the report in the output folder has the
//  rest.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import AppKit
import LDACore
import SwiftUI

/// A stop request shared with the batch running off the main thread.
final class BatchStopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    func set() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}

/// The batch window's state: the chosen folders and settings, then the run.
@MainActor
final class BatchAnonymizeModel: ObservableObject {
    enum KeyMode: Hashable {
        case keychain
        case passphrase
    }

    enum Phase: Equatable {
        case idle
        case running
        case finished
        case failed(String)
    }

    @Published var sourceFolder: URL?
    @Published var outputFolder: URL?
    @Published var style: SubstitutionStyle
    @Published var keyMode: KeyMode = .keychain
    @Published var passphrase = ""
    @Published var passphraseConfirmation = ""
    @Published var redoFinished = false
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var total = 0
    @Published private(set) var completed = 0
    @Published private(set) var currentSource: String?
    @Published private(set) var items: [BatchItem] = []
    @Published private(set) var report: BatchReport?

    private var stopFlag = BatchStopFlag()
    private let modelPath: () -> String?

    init(
        modelPath: @escaping () -> String? = { LDAV4Extractor.bundledModelPath() },
        style: SubstitutionStyle = AISettings.outputStyle()
    ) {
        self.modelPath = modelPath
        self.style = style
    }

    /// Closing the window stops the batch after the document in progress,
    /// rather than leaving it running unseen.
    deinit {
        stopFlag.set()
    }

    var isRunning: Bool { phase == .running }

    var passphraseIsUsable: Bool {
        keyMode == .keychain || (!passphrase.isEmpty && passphrase == passphraseConfirmation)
    }

    /// The visible error and the Start gate use the same folder comparison.
    var hasFolderConflict: Bool {
        guard let sourceFolder, let outputFolder else { return false }
        return sourceFolder.standardizedFileURL == outputFolder.standardizedFileURL
    }

    var passphraseValidationKey: String? {
        guard !passphraseIsUsable else { return nil }
        if passphrase.isEmpty || passphraseConfirmation.isEmpty {
            return "Type the passphrase twice under More options."
        }
        return "The passphrases do not match. Check them under More options."
    }

    var canStart: Bool {
        !isRunning && sourceFolder != nil && outputFolder != nil
            && !hasFolderConflict && passphraseIsUsable
    }

    // MARK: Folders

    func chooseSourceFolder() {
        if let url = Self.chooseFolder(
            message: L10n.string("Choose the folder of documents to anonymize. Subfolders are included."),
            prompt: L10n.string("Choose")
        ) {
            sourceFolder = url
        }
    }

    func chooseOutputFolder() {
        if let url = Self.chooseFolder(
            message: L10n.string("Choose the folder for the redacted copies, the mappings and the batch report."),
            prompt: L10n.string("Save Here")
        ) {
            outputFolder = url
        }
    }

    private static func chooseFolder(message: String, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: Run

    /// Starts the batch off the main thread. Progress arrives on the main
    /// actor; the finished report replaces the running list.
    func start() {
        guard canStart, let source = sourceFolder, let output = outputFolder else { return }
        let handoff = MCPBatchHandoff.shared
        guard let modelPath = modelPath() else {
            phase = .failed(L10n.string("The built-in LDA V4 model was not found. Reinstall LDA."))
            if let request = handoff.claim() { handoff.answer(request, .failed) }
            return
        }
        let passphrase = keyMode == .passphrase ? self.passphrase : nil
        let options = BatchOptions(
            modelPath: modelPath,
            style: style,
            unlocatedPolicy: .protect,
            redoFinished: redoFinished,
            protectionLabel: passphrase == nil ? "keychain" : "passphrase",
            protection: { document in
                if let passphrase { return .passphrase(passphrase) }
                // The account the app's Restore derives from the sidecar's name.
                let sidecar = URL(
                    fileURLWithPath: document.deletingPathExtension().lastPathComponent + "_redacted.ldamap"
                )
                return .keychain(account: SessionModel.sidecarKeychainAccount(for: sidecar))
            }
        )
        let flag = BatchStopFlag()
        stopFlag = flag
        phase = .running
        total = 0
        completed = 0
        currentSource = nil
        items = []
        report = nil
        // An MCP request waiting in this window is answered by this batch,
        // even when the window closes before the batch ends.
        let request = handoff.claim()
        handoff.isBatchRunning = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let sourceScope = source.startAccessingSecurityScopedResource()
            let outputScope = output.startAccessingSecurityScopedResource()
            defer {
                if sourceScope { source.stopAccessingSecurityScopedResource() }
                if outputScope { output.stopAccessingSecurityScopedResource() }
            }
            do {
                let report = try BatchAnonymizer.run(
                    sourceFolder: source,
                    outputFolder: output,
                    options: options,
                    isCancelled: { flag.isSet },
                    onProgress: { progress in
                        Task { @MainActor in self?.apply(progress) }
                    }
                )
                await MainActor.run {
                    handoff.isBatchRunning = false
                    if let request {
                        handoff.answer(request, report.cancelled ? .stopped : .finished, report: report)
                    }
                }
                await self?.finish(report)
            } catch {
                await MainActor.run {
                    handoff.isBatchRunning = false
                    if let request { handoff.answer(request, .failed) }
                }
                await self?.fail(BatchAnonymizer.describe(error))
            }
        }
    }

    func stop() {
        stopFlag.set()
    }

    private func apply(_ progress: BatchProgress) {
        guard phase == .running else { return }
        total = progress.total
        guard let item = progress.item else {
            currentSource = progress.source
            return
        }
        completed = max(completed, progress.index)
        currentSource = nil
        if !items.contains(where: { $0.source == item.source }) {
            items.append(item)
        }
    }

    private func finish(_ report: BatchReport) {
        self.report = report
        items = report.items
        completed = report.items.count
        total = max(total, report.items.count)
        currentSource = nil
        passphrase = ""
        passphraseConfirmation = ""
        phase = .finished
    }

    private func fail(_ message: String) {
        currentSource = nil
        phase = .failed(message)
    }

    // MARK: Results

    /// Shows the output folder in Finder with the batch report selected, the
    /// way the app shows every other file it writes.
    func revealReport() {
        guard let outputFolder else { return }
        let summary = outputFolder.appendingPathComponent(BatchReport.summaryFileName)
        let target = FileManager.default.fileExists(atPath: summary.path) ? summary : outputFolder
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    /// The style picker's catalog keys: the labels the Settings picker shows.
    static func styleLabel(_ style: SubstitutionStyle) -> String {
        switch style {
        case .token: return "Placeholders"
        case .pseudonym: return "Pseudonyms"
        case .asterisk: return "Asterisks"
        }
    }

    /// The second line of a document's row, in `language`.
    nonisolated static func detail(for item: BatchItem, language: AppLanguage) -> String {
        switch item.status {
        case .done where item.autoProtectedValueCount > 0:
            return L10n.formatted(
                "%lld replaced, %lld protected automatically",
                language: language,
                [Int64(item.replacedCount), Int64(item.autoProtectedValueCount)]
            )
        case .done:
            return L10n.formatted("%lld replaced", language: language, [Int64(item.replacedCount)])
        case .skipped:
            return L10n.string("Finished in an earlier run", language: language)
        case .failed:
            return L10n.formatted(
                "Not written: %@",
                language: language,
                [item.reason ?? L10n.string("unknown error", language: language)]
            )
        }
    }

    /// The one line under a finished run: what was written, then only the
    /// counts that are not zero.
    nonisolated static func summary(for report: BatchReport, language: AppLanguage) -> String {
        var parts = [L10n.formatted("%lld written", language: language, [Int64(report.doneCount)])]
        if report.skippedCount > 0 {
            parts.append(
                L10n.formatted("%lld finished in an earlier run", language: language, [Int64(report.skippedCount)])
            )
        }
        if report.failedCount > 0 {
            parts.append(L10n.formatted("%lld not written", language: language, [Int64(report.failedCount)]))
        }
        return parts.joined(separator: " · ")
    }

    /// The documents the window lists after a run, in report order: each one
    /// not written, and each written one with something to check, as in the
    /// report's "Check these" section. Every other document is only in the
    /// report.
    nonisolated static func problems(in report: BatchReport, language: AppLanguage) -> [BatchProblem] {
        report.items.compactMap { item in
            if item.status == .failed {
                return BatchProblem(source: item.source, lines: [detail(for: item, language: language)], failed: true)
            }
            var lines: [String] = []
            if item.unboxedTokenCount > 0 {
                lines.append(L10n.formatted(
                    "Values the review PDF still shows: %lld. Share the redacted text, not the review PDF.",
                    language: language,
                    [Int64(item.unboxedTokenCount)]
                ))
            }
            if item.embeddedMediaCount > 0 {
                lines.append(L10n.formatted(
                    "Embedded images copied without scanning, such as signatures or stamps: %lld.",
                    language: language,
                    [Int64(item.embeddedMediaCount)]
                ))
            }
            if item.trackedChangeCount > 0 {
                lines.append(L10n.formatted(
                    "Tracked changes: %lld. Accept them before redacting for an exact round trip.",
                    language: language,
                    [Int64(item.trackedChangeCount)]
                ))
            }
            return lines.isEmpty ? nil : BatchProblem(source: item.source, lines: lines, failed: false)
        }
    }
}

/// A document the batch window lists after a run.
struct BatchProblem: Identifiable, Equatable {
    let source: String
    let lines: [String]
    /// Not written at all, rather than written with something to check.
    let failed: Bool

    var id: String { source }
}

/// The batch window's content.
public struct BatchAnonymizeView: View {
    @StateObject private var model = BatchAnonymizeModel()
    @ObservedObject private var handoff = MCPBatchHandoff.shared
    @Environment(\.appLanguage) private var language
    @State private var showsOptions = false

    public init() {}

    public var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            if handoff.pending != nil {
                Label {
                    L10n.text("Your AI assistant asked LDA to open this window. When the batch ends, it receives only counts, never file names or document text.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "sparkles")
                }
                .font(CounselTheme.Typography.supporting)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
            L10n.text("Anonymize every document in a folder. No review step.")
                .fixedSize(horizontal: false, vertical: true)
            folders
            if model.hasFolderConflict {
                validationNotice("Choose an output folder different from the source folder.")
            }
            options
            controls
            outcome
        }
        .padding(24)
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(CounselTheme.Typography.readingBody)
        .background(CounselTheme.paper)
        // Fill the window and start at its top: a window restored at a
        // larger size otherwise floats the short content in its middle.
        .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: model.hasFolderConflict) { _, conflicts in
            if conflicts {
                AccessibilityNotification.Announcement(L10n.string(
                    "Choose an output folder different from the source folder.", language: language
                )).post()
            }
        }
        .onDisappear { handoff.windowClosed() }
    }

    private var folders: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                L10n.text("From")
                folderName(model.sourceFolder)
                Button { model.chooseSourceFolder() } label: {
                    L10n.text("Choose…").font(CounselTheme.Typography.supporting.weight(.medium))
                }
                    .l10nAccessibilityLabel("Choose source folder")
                    .accessibilityValue(model.sourceFolder?.path ?? L10n.string("No folder chosen", language: language))
                    .disabled(model.isRunning)
            }
            GridRow {
                L10n.text("To")
                folderName(model.outputFolder)
                Button { model.chooseOutputFolder() } label: {
                    L10n.text("Choose…").font(CounselTheme.Typography.supporting.weight(.medium))
                }
                    .l10nAccessibilityLabel("Choose output folder")
                    .accessibilityValue(model.outputFolder?.path ?? L10n.string("No folder chosen", language: language))
                    .disabled(model.isRunning)
            }
        }
    }

    /// The folder's name; the full path is in its help tag.
    @ViewBuilder
    private func folderName(_ url: URL?) -> some View {
        if let url {
            Text(verbatim: url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(url.path)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            L10n.text("No folder chosen")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var options: some View {
        FullRowDisclosure(isExpanded: $showsOptions) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    L10n.text("Output style")
                        .font(CounselTheme.Typography.heading)
                    Picker(selection: $model.style) {
                        ForEach(SubstitutionStyle.allCases, id: \.self) { style in
                            Text(verbatim: L10n.string(BatchAnonymizeModel.styleLabel(style), language: language)).tag(style)
                        }
                    } label: { L10n.text("Output style") }
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 10) {
                    L10n.text("Mapping keys")
                        .font(CounselTheme.Typography.heading)
                    Picker(selection: $model.keyMode) {
                        Text(verbatim: L10n.string("Keychain on this Mac", language: language))
                            .tag(BatchAnonymizeModel.KeyMode.keychain)
                        Text(verbatim: L10n.string("One passphrase for every mapping", language: language))
                            .tag(BatchAnonymizeModel.KeyMode.passphrase)
                    } label: { L10n.text("Mapping keys") }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    if model.keyMode == .passphrase {
                        VStack(alignment: .leading, spacing: 10) {
                            L10n.secureField("Passphrase", text: $model.passphrase)
                            L10n.secureField("Type the passphrase again", text: $model.passphraseConfirmation)
                        }
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 400)
                    }
                }
                L10n.toggle("Redo documents finished earlier", isOn: $model.redoFinished)
            }
            .controlSize(.large)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 16)
            .disabled(model.isRunning)
        } label: {
            L10n.text("More options")
        }
    }

    private var controls: some View {
        HStack(alignment: .firstTextBaseline) {
            if let key = model.passphraseValidationKey {
                validationNotice(key)
            }
            Spacer()
            if model.isRunning {
                Button { model.stop() } label: {
                    L10n.text("Stop").font(CounselTheme.Typography.supporting.weight(.medium))
                }
            } else {
                Button { model.start() } label: {
                    L10n.text("Start").font(CounselTheme.Typography.supporting.weight(.medium))
                }
                    .buttonStyle(.borderedProminent)
                    .tint(CounselTheme.inkAccentFill)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canStart)
            }
        }
    }

    private func validationNotice(_ key: String) -> some View {
        L10n.label(key, systemImage: "exclamationmark.circle")
            .font(CounselTheme.Typography.supporting)
            .foregroundStyle(CounselTheme.danger)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var outcome: some View {
        if model.isRunning {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(model.completed), total: Double(max(model.total, 1)))
                if let current = model.currentSource {
                    L10n.text("Document %lld of %lld: %@", Int64(model.completed + 1), Int64(model.total), current)
                        .font(CounselTheme.Typography.metadata)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        if let report = model.report {
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: BatchAnonymizeModel.summary(for: report, language: language))
                Spacer()
                L10n.button("Show in Finder") { model.revealReport() }
            }
            if report.autoProtectedValueCount > 0 {
                L10n.text("Values protected automatically: %lld", Int64(report.autoProtectedValueCount))
                    .font(CounselTheme.Typography.supporting)
                    .foregroundStyle(.secondary)
            }
            if report.cancelled {
                L10n.text("Stopped before every document was processed.")
            }
            problemList(BatchAnonymizeModel.problems(in: report, language: language))
        }
        if case .failed(let message) = model.phase {
            Text(verbatim: message)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func problemList(_ problems: [BatchProblem]) -> some View {
        if !problems.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(problems) { problem in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: problem.failed ? "exclamationmark.triangle.fill" : "exclamationmark.circle")
                                .foregroundStyle(problem.failed ? Color.orange : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: problem.source)
                                ForEach(problem.lines, id: \.self) { line in
                                    Text(verbatim: line)
                                        .font(CounselTheme.Typography.metadata)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 200)
        }
    }
}

/// File > Batch Anonymize...: opens the batch window. A view, not a plain
/// Button in the command group, because opening a window needs the
/// environment's openWindow action.
public struct BatchAnonymizeMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    private let title: String

    public init(title: String) {
        self.title = title
    }

    public var body: some View {
        Button(title) {
            openWindow(id: LDAWindowID.batch)
        }
        .keyboardShortcut("b", modifiers: [.command, .shift])
    }
}
