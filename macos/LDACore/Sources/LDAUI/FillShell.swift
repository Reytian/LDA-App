//
//  FillShell.swift
//  LDAUI
//
//  The Counsel Fill window shell. Hosts the two-stage fill workflow:
//
//  Stage 1 (profile builder): Add source documents, extract a client portfolio,
//  review and edit fields, resolve conflicts, save/load the profile as an
//  encrypted .ldaprofile.
//
//  Stage 2 (fill review): Open a fill target (docx or pdf), review blank-by-
//  blank matches, accept, reject, or repoint each blank, then apply the fill.
//
//  Stage is driven entirely by FillModel.stage; the shell is a pure view that
//  observes the model and presents appropriate chrome. Heavy work lives in
//  FillModel; NSPanel calls live here.
//
//  Platform rules (hard-won; do NOT change):
//  - NSOpenPanel / NSSavePanel only. Two .fileImporter modifiers on one view
//    silently fail; this cost days before.
//  - pickerRequestID is observed via .onReceive of the publisher, not
//    .onChange, so the initial nil-then-reassign trick (M2) in acceptBlank
//    always fires the observer.
//  - The app is an SPM executable over the LDAUI library; all view code stays
//    in LDAUI.
//
//  Subviews too large for this file live in FillShellViews.swift.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import LDACore

// MARK: - FillShell

/// The top-level view for the Fill mode. Delegates body layout to the active
/// stage; toolbar tracks stage with appropriate actions.
public struct FillShell: View {

    @ObservedObject var model: FillModel

    // MARK: - Profile passphrase sheet

    /// True while the passphrase sheet for save-profile is presented.
    @State private var isSavingWithPassphrase = false

    /// True while the passphrase sheet for load-profile is presented.
    @State private var isLoadingWithPassphrase = false

    /// Passphrase entered in the sheet.
    @State private var passphraseInput = ""

    /// The URL chosen by the Save panel, held while the passphrase is collected.
    @State private var pendingSaveURL: URL?

    /// The URL chosen by the Load panel, held while the passphrase is collected.
    @State private var pendingLoadURL: URL?

    // MARK: - Source list

    /// Source document URLs added by the user (displayed in the profile builder).
    @State private var sourcePaths: [URL] = []

    // MARK: - Field picker popover

    /// The blank id for which the field picker popover is currently open.
    @State private var pickerOpenForBlankID: UUID?

    // MARK: - Output

    /// One-line message shown after a successful or failed apply.
    @State private var applyMessage: String?

    // MARK: - Init

    public init(model: FillModel) {
        self.model = model
    }

    // MARK: - Body

    public var body: some View {
        Group {
            switch model.stage {
            case .idle, .importingSources, .extracting, .profileReady:
                profileBuilderView
            case .planning, .reviewing, .applying, .done, .failed:
                fillReviewView
            }
        }
        .background(CounselTheme.appSurface)
        .navigationTitle("Fill from Profile")
        .toolbar { toolbarContent }
        .sheet(isPresented: $isSavingWithPassphrase) {
            saveProfilePassphraseSheet
        }
        .sheet(isPresented: $isLoadingWithPassphrase) {
            loadProfilePassphraseSheet
        }
        // Observe pickerRequestID via onReceive so the nil-then-reassign (M2)
        // trick in FillModel.acceptBlank fires even when the id does not change.
        .onReceive(model.$pickerRequestID) { id in
            guard let id else { return }
            pickerOpenForBlankID = id
        }
        .onChange(of: model.stage) { _, stage in
            announceStage(stage)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        switch model.stage {
        case .idle, .importingSources, .extracting, .profileReady:
            profileBuilderToolbar
        case .planning, .reviewing, .applying, .done, .failed:
            fillReviewToolbar
        }
    }

    @ToolbarContentBuilder
    private var profileBuilderToolbar: some ToolbarContent {
        // Navigation group: Add Sources
        ToolbarItemGroup(placement: .navigation) {
            Button {
                presentAddSources()
            } label: {
                Label("Add Sources", systemImage: "doc.badge.plus")
            }
            .help("Add source documents to extract profile fields from (PDF, Word, or plain text)")
        }

        // Automatic group: Extract, Save Profile, Load Profile, Open Target
        ToolbarItemGroup(placement: .automatic) {
            Button {
                let created = ISO8601DateFormatter().string(from: Date())
                let label = sourcePaths.first?.deletingPathExtension().lastPathComponent ?? "Profile"
                Task {
                    await model.extractProfile(
                        sources: sourcePaths,
                        label: label,
                        createdAtISO8601: created
                    )
                }
            } label: {
                Label("Extract", systemImage: "text.magnifyingglass")
            }
            .labelStyle(.titleAndIcon)
            .buttonStyle(.borderedProminent)
            .tint(CounselTheme.inkAccentFill)
            .disabled(!canExtract)
            .help(extractDisabledReason)

            Button {
                beginSaveProfile()
            } label: {
                Label("Save Profile", systemImage: "tray.and.arrow.down")
            }
            .labelStyle(.titleAndIcon)
            .disabled(!canSaveProfile)
            .help("Save the current profile as an encrypted .ldaprofile file")

            Button {
                beginLoadProfile()
            } label: {
                Label("Load Profile", systemImage: "tray.and.arrow.up")
            }
            .labelStyle(.titleAndIcon)
            .help("Load a previously saved .ldaprofile file")

            Button {
                presentOpenTarget()
            } label: {
                Label("Open Target", systemImage: "doc.text")
            }
            .labelStyle(.titleAndIcon)
            .disabled(!canOpenTarget)
            .help("Open the Word or PDF document to fill (requires a loaded profile)")
        }
    }

    @ToolbarContentBuilder
    private var fillReviewToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                presentOpenTarget()
            } label: {
                Label("Open Target", systemImage: "doc.text")
            }
            .help("Open the Word or PDF document to fill")
        }

        ToolbarItemGroup(placement: .automatic) {
            // Accept all proposed blanks in one click
            if case .reviewing = model.stage {
                Button {
                    model.acceptAllProposed()
                } label: {
                    Label("Accept All", systemImage: "checkmark.circle")
                }
                .help("Accept all proposed blank fills at once")

                Button {
                    beginApplyFill()
                } label: {
                    Label("Apply Fill", systemImage: "square.and.arrow.down")
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.borderedProminent)
                .tint(CounselTheme.inkAccentFill)
                .help("Apply confirmed fills and write the output document")
            }

            // Let the user go back to the profile builder from any fill-review stage
            Button {
                model.backToProfile()
                applyMessage = nil
            } label: {
                Label("Back to Profile", systemImage: "arrow.backward")
            }
            .help("Return to the profile builder")
        }
    }

    // MARK: - Profile builder view

    private var profileBuilderView: some View {
        VStack(spacing: 0) {
            profileStatusBanner
            ProfileBuilderBody(
                model: model,
                sourcePaths: sourcePaths
            )
        }
    }

    // MARK: - Profile status banner

    @ViewBuilder
    private var profileStatusBanner: some View {
        if case .extracting = model.stage {
            bannerChrome {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .tint(CounselTheme.inkAccent)
                    .frame(maxWidth: 300)
                Text(extractingLabel)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(CounselTheme.textSecondary)
                Spacer(minLength: 0)
            }
        } else if case .importingSources = model.stage {
            bannerChrome {
                ProgressView()
                    .controlSize(.small)
                Text("Importing source documents")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
                Spacer(minLength: 0)
            }
        } else if case .profileReady = model.stage {
            if !model.sourceWarnings.isEmpty {
                bannerChrome {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(CounselTheme.danger)
                    Text("Some sources could not be imported: "
                         + model.sourceWarnings.prefix(3).joined(separator: "; "))
                        .font(.callout)
                        .foregroundStyle(CounselTheme.danger)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
            } else if model.profile?.incomplete == true {
                bannerChrome {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(CounselTheme.danger)
                    Text("Extraction could not fully scan all segments. Some fields may be missing.")
                        .font(.callout)
                        .foregroundStyle(CounselTheme.danger)
                    Spacer(minLength: 0)
                }
            }
            if let conflicted = model.profile?.conflictedKeys, !conflicted.isEmpty {
                conflictBanner(keys: conflicted)
            }
        } else if case .idle = model.stage {
            // Empty state hint
            bannerChrome {
                Text("Add source documents, then click Extract to build a profile.")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
                Spacer(minLength: 0)
            }
        }
    }

    private func conflictBanner(keys: [ProfileFieldKey]) -> some View {
        bannerChrome {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(CounselTheme.danger)
            let names = keys.map(\.displayName).joined(separator: ", ")
            Text("Conflicts in: \(names). Use the resolve controls below to keep one value per field.")
                .font(.callout)
                .foregroundStyle(CounselTheme.danger)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Fill review view

    private var fillReviewView: some View {
        VStack(spacing: 0) {
            fillStatusBanner
            FillReviewBody(
                model: model,
                pickerOpenForBlankID: $pickerOpenForBlankID,
                applyMessage: $applyMessage
            )
        }
    }

    // MARK: - Fill status banner

    @ViewBuilder
    private var fillStatusBanner: some View {
        if case .planning = model.stage {
            bannerChrome {
                ProgressView()
                    .controlSize(.small)
                Text("Planning fill")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
                Spacer(minLength: 0)
            }
        } else if case .applying = model.stage {
            bannerChrome {
                ProgressView()
                    .controlSize(.small)
                Text("Applying fill")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
                Spacer(minLength: 0)
            }
        } else if case .done(let report) = model.stage {
            bannerChrome {
                Image(systemName: "checkmark.seal")
                    .foregroundStyle(CounselTheme.inkAccent)
                let skippedCount = report.skipped.count
                let skipText = skippedCount > 0
                    ? "  \u{00B7}  \(skippedCount) skipped"
                    : ""
                Text("Filled \(report.filledCount) blank\(report.filledCount == 1 ? "" : "s") in \(report.outputURL.lastPathComponent)\(skipText).")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textPrimary)
                if let msg = applyMessage {
                    Text(msg)
                        .font(.callout)
                        .foregroundStyle(CounselTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        } else if case .failed(let detail) = model.stage {
            bannerChrome {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(CounselTheme.danger)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(CounselTheme.danger)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
        } else if case .reviewing = model.stage {
            let total = model.blanks.count
            let confirmed = model.blanks.filter { $0.status == .confirmed }.count
            let unmatched = model.blanks.filter { $0.status == .unmatched }.count
            bannerChrome {
                Image(systemName: "checkmark.seal")
                    .foregroundStyle(CounselTheme.inkAccent)
                Text("\(total) blank\(total == 1 ? "" : "s")  \u{00B7}  \(confirmed) confirmed")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(CounselTheme.textPrimary)
                if unmatched > 0 {
                    Text("\u{00B7}  \(unmatched) unmatched")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(CounselTheme.danger)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Banner chrome

    private func bannerChrome<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(CounselTheme.raised)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(CounselTheme.hairline)
                .frame(height: 1)
        }
    }

    // MARK: - Computed guards

    private var canExtract: Bool {
        !sourcePaths.isEmpty
            && model.modelPath.flatMap {
                $0.isEmpty ? nil : $0
            } != nil
            && !(model.stage == .importingSources || model.stage == .extracting)
    }

    private var extractDisabledReason: String {
        if sourcePaths.isEmpty { return "Add at least one source document first" }
        if model.modelPath == nil || (model.modelPath ?? "").isEmpty {
            return "Requires the bundled on-device model (lda-v2-Q4_K_M.gguf). "
                + "In development builds, place the model at "
                + "~/Developer/lda-models/lda-v2-Q4_K_M.gguf."
        }
        return "Extract profile fields from the source documents"
    }

    private var canSaveProfile: Bool {
        guard let profile = model.profile else { return false }
        return profile.conflictedKeys.isEmpty
    }

    private var canOpenTarget: Bool {
        model.profile != nil
            && !(model.stage == .importingSources || model.stage == .extracting)
    }

    private var extractingLabel: String {
        let pct = Int((model.progress * 100).rounded())
        return "Extracting  \(pct)%"
    }

    // MARK: - Add Sources

    private func presentAddSources() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.sourceContentTypes
        panel.message = "Choose source documents to extract profile fields from."
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        let new = panel.urls.filter { url in
            !sourcePaths.contains(url)
        }
        sourcePaths.append(contentsOf: new)
    }

    // MARK: - Open fill target

    private func presentOpenTarget() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = Self.targetContentTypes
        panel.message = "Choose the Word or PDF document to fill."
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        applyMessage = nil
        // Security scope is now owned by FillModel (startTargetScope / stopTargetScope).
        // The scope must survive from planFill through applyFill; managing it here
        // inside a single Task would release it before applyFill runs.
        Task {
            await model.planFill(target: url)
        }
    }

    // MARK: - Apply fill

    private func beginApplyFill() {
        applyMessage = nil
        let savePanel = NSOpenPanel()
        savePanel.canChooseFiles = false
        savePanel.canChooseDirectories = true
        savePanel.canCreateDirectories = true
        savePanel.allowsMultipleSelection = false
        savePanel.message = "Choose a folder for the filled output document."
        savePanel.prompt = "Save Here"
        guard savePanel.runModal() == .OK, let dir = savePanel.url else { return }
        let needsScope = dir.startAccessingSecurityScopedResource()
        Task {
            defer { if needsScope { dir.stopAccessingSecurityScopedResource() } }
            await model.applyFill(outputDir: dir)
        }
    }

    // MARK: - Save Profile flow

    private func beginSaveProfile() {
        guard canSaveProfile else { return }
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [Self.profileType]
        savePanel.message = "Save the current profile as an encrypted .ldaprofile file."
        savePanel.nameFieldStringValue = (model.profile?.label ?? "profile") + ".ldaprofile"
        guard savePanel.runModal() == .OK, let url = savePanel.url else { return }
        pendingSaveURL = url
        passphraseInput = ""
        isSavingWithPassphrase = true
    }

    private func confirmSaveProfile() {
        isSavingWithPassphrase = false
        guard let url = pendingSaveURL, let profile = model.profile else {
            pendingSaveURL = nil
            passphraseInput = ""
            return
        }
        let protection: MappingProtection = passphraseInput.isEmpty
            ? .keychain(account: url.lastPathComponent)
            : .passphrase(passphraseInput)
        pendingSaveURL = nil
        passphraseInput = ""
        do {
            try ProfileStore.save(profile, to: url, protection: protection)
        } catch {
            showAlert(
                title: "Save failed",
                text: error.localizedDescription,
                warning: true
            )
        }
    }

    private var saveProfilePassphraseSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Protect the profile")
                .font(.headline)
                .foregroundStyle(CounselTheme.textPrimary)

            Text("Enter an optional passphrase to encrypt the profile. "
                 + "Leave it blank to protect it with the system Keychain.")
                .font(.callout)
                .foregroundStyle(CounselTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let url = pendingSaveURL, Self.isUnderICloud(url) {
                Label(
                    "This folder syncs to iCloud. The encrypted profile will be uploaded with it.",
                    systemImage: "icloud.and.arrow.up"
                )
                .font(.callout)
                .foregroundStyle(CounselTheme.danger)
                .fixedSize(horizontal: false, vertical: true)
            }

            SecureField("Passphrase (optional)", text: $passphraseInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    isSavingWithPassphrase = false
                    pendingSaveURL = nil
                    passphraseInput = ""
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    confirmSaveProfile()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(CounselTheme.inkAccentFill)
            }
        }
        .padding(24)
        .frame(minWidth: 380)
        .background(CounselTheme.raised)
    }

    // MARK: - Load Profile flow

    private func beginLoadProfile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [Self.profileType]
        panel.message = "Choose a .ldaprofile file to load."
        panel.prompt = "Load"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingLoadURL = url
        passphraseInput = ""
        isLoadingWithPassphrase = true
    }

    private func confirmLoadProfile() {
        isLoadingWithPassphrase = false
        guard let url = pendingLoadURL else {
            pendingLoadURL = nil
            passphraseInput = ""
            return
        }
        let protection: MappingProtection = passphraseInput.isEmpty
            ? .keychain(account: url.lastPathComponent)
            : .passphrase(passphraseInput)
        pendingLoadURL = nil
        passphraseInput = ""
        do {
            let profile = try ProfileStore.load(from: url, protection: protection)
            model.loadProfile(profile)
        } catch {
            showAlert(
                title: "Load failed",
                text: error.localizedDescription,
                warning: true
            )
        }
    }

    private var loadProfilePassphraseSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Profile passphrase")
                .font(.headline)
                .foregroundStyle(CounselTheme.textPrimary)

            Text("If this profile was saved with a passphrase, enter it. "
                 + "Leave it blank if it uses the Keychain.")
                .font(.callout)
                .foregroundStyle(CounselTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Passphrase (optional)", text: $passphraseInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    isLoadingWithPassphrase = false
                    pendingLoadURL = nil
                    passphraseInput = ""
                }
                .keyboardShortcut(.cancelAction)

                Button("Load") {
                    confirmLoadProfile()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(CounselTheme.inkAccentFill)
            }
        }
        .padding(24)
        .frame(minWidth: 380)
        .background(CounselTheme.raised)
    }

    // MARK: - Helpers

    private func announceStage(_ stage: FillStage) {
        switch stage {
        case .profileReady:
            AccessibilityNotification.Announcement("Profile ready. Review and edit fields below.").post()
        case .reviewing:
            let count = model.blanks.count
            AccessibilityNotification.Announcement(
                "Review ready. \(count) blank\(count == 1 ? "" : "s") to review."
            ).post()
        case .done(let report):
            AccessibilityNotification.Announcement(
                "Fill complete. \(report.filledCount) blank\(report.filledCount == 1 ? "" : "s") filled."
            ).post()
        case .failed(let detail):
            AccessibilityNotification.Announcement("Fill failed. \(detail)").post()
        default:
            break
        }
    }

    private func showAlert(title: String, text: String, warning: Bool) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = warning ? .warning : .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func isUnderICloud(_ url: URL) -> Bool {
        url.standardizedFileURL.path.contains("/Library/Mobile Documents/")
    }

    // MARK: - Content types

    private static let sourceContentTypes: [UTType] = {
        var types: [UTType] = [.plainText, .text, .pdf]
        if let docx = UTType("org.openxmlformats.wordprocessingml.document") {
            types.append(docx)
        }
        return types
    }()

    private static let targetContentTypes: [UTType] = {
        var types: [UTType] = [.pdf]
        if let docx = UTType("org.openxmlformats.wordprocessingml.document") {
            types.append(docx)
        }
        return types
    }()

    private static let profileType: UTType = UTType(
        exportedAs: "ai.openclaw.lda.profile",
        conformingTo: .data
    )
}
