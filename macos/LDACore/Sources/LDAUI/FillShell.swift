//
//  FillShell.swift
//  LDAUI
//
//  The Counsel Fill window shell. Hosts the three-stage fill workflow:
//
//  Stage 0 (library): Browse the Client Portfolio Library; create, edit,
//  import, export, and delete portfolios.
//
//  Stage 1 (profile builder): Add source documents, extract a client portfolio,
//  review and edit fields, resolve conflicts, save to the library.
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
//  Subviews too large for this file live in FillShellViews.swift and
//  FillLibraryViews.swift. Sheet bodies and confirm methods live in
//  FillShellSheets.swift.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import LDACore

enum FillShellSurface: Equatable {
    case library
    case profile
    case review
}

enum FillStatusPresentation {
    static func reviewing(
        total: Int,
        confirmed: Int,
        language: AppLanguage? = nil
    ) -> String {
        let key = total == 1
            ? "%lld blank  \u{00B7}  %lld confirmed"
            : "%lld blanks  \u{00B7}  %lld confirmed"
        return String(
            format: L10n.string(key, language: language),
            Int64(total),
            Int64(confirmed)
        )
    }

    static func completed(
        filled: Int,
        fileName: String,
        skipped: Int,
        language: AppLanguage? = nil
    ) -> String {
        let key: String
        if skipped > 0 {
            key = filled == 1
                ? "Filled %lld blank in %@. %lld skipped."
                : "Filled %lld blanks in %@. %lld skipped."
            return String(
                format: L10n.string(key, language: language),
                Int64(filled),
                fileName as NSString,
                Int64(skipped)
            )
        }

        key = filled == 1
            ? "Filled %lld blank in %@."
            : "Filled %lld blanks in %@."
        return String(
            format: L10n.string(key, language: language),
            Int64(filled),
            fileName as NSString
        )
    }
}

// MARK: - FillShell

/// The top-level view for the Fill mode. Delegates body layout to the active
/// stage; toolbar tracks stage with appropriate actions.
public struct FillShell: View {

    @ObservedObject var model: FillModel

    // MARK: - Profile passphrase sheet

    /// True while the passphrase sheet for save-profile is presented.
    @State var isSavingWithPassphrase = false // internal for FillShellSheets.swift

    /// True while the passphrase sheet for load-profile is presented.
    @State var isLoadingWithPassphrase = false // internal for FillShellSheets.swift

    /// Passphrase entered in the sheet.
    @State var passphraseInput = "" // internal for FillShellSheets.swift

    /// The URL chosen by the Save panel, held while the passphrase is collected.
    @State var pendingSaveURL: URL? // internal for FillShellSheets.swift

    /// The URL chosen by the Load panel, held while the passphrase is collected.
    @State var pendingLoadURL: URL? // internal for FillShellSheets.swift

    // MARK: - Import sheet (library)

    /// True while the import passphrase/protection sheet is presented.
    @State var isImportingProfile = false // internal for FillShellSheets.swift

    /// The URL chosen by the import panel, held while protection is selected.
    @State var pendingImportURL: URL? // internal for FillShellSheets.swift

    /// The summary currently being exported from the library list.
    @State var exportingSummary: PortfolioSummary? // internal for FillShellSheets.swift

    /// True while the export passphrase sheet is presented.
    @State var isExportingWithPassphrase = false // internal for FillShellSheets.swift

    /// The URL chosen by the export Save panel.
    @State var pendingExportURL: URL? // internal for FillShellSheets.swift

    // MARK: - Editor extras

    /// True while the Add Field sheet is presented in the editor.
    @State private var isAddingField = false

    /// True while the Back-to-Library confirmation dialog is showing.
    @State private var isBackToLibraryConfirmation = false

    // MARK: - Source list
    //
    // sourcePaths is owned by FillModel so that createPortfolio can reset it when
    // a new portfolio session begins. FillShell reads and appends to model.sourcePaths
    // directly; no local @State copy is maintained.

    // MARK: - Field picker popover

    /// The blank id for which the field picker popover is currently open.
    @State private var pickerOpenForBlankID: UUID?

    // MARK: - Output

    /// One-line message shown after a successful or failed apply.
    @State private var applyMessage: String?

    // MARK: - Init

    /// Whether this shell is the frontmost mode. Gates the toolbar: RootShell
    /// keeps every mode's view alive in a ZStack, and SwiftUI merges toolbar
    /// items from all live layers, so an inactive shell must contribute none.
    /// Also gates library loading: the portfolio library key lives in the
    /// macOS Keychain, and it must never be touched at app launch, only when
    /// the user actually enters Fill.
    private let isActive: Bool

    /// One-time flag: the first library unlock shows a short explanation of
    /// the upcoming macOS Keychain prompt, so the system dialog is expected
    /// rather than alarming.
    @AppStorage("com.haotianyi.LDA.hasSeenLibraryKeychainNote")
    private var hasSeenLibraryKeychainNote = false

    /// True while the first-time Keychain explanation is presented.
    @State private var isShowingKeychainNote = false

    /// Native titlebar and toolbar clearance that persists across every Fill stage.
    @State private var windowChromeTopInset: CGFloat = 0

    public init(model: FillModel, isActive: Bool = true) {
        self.model = model
        self.isActive = isActive
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            WindowChromeTopSpacer(height: windowChromeTopInset, background: CounselTheme.appSurface)

            Group {
                switch activeSurface {
                case .library:
                    PortalLibraryBody(
                        model: model,
                        onExport: { summary in beginExportFromLibrary(summary) },
                        onImport: { beginImportProfile() }
                    )
                case .profile:
                    profileBuilderView
                case .review:
                    fillReviewView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CounselTheme.appSurface)
        .background(WindowContentTopInsetReader(topInset: $windowChromeTopInset))
        .l10nNavigationTitle("Fill from Profile")
        .toolbar { toolbarContent }
        .sheet(isPresented: $isSavingWithPassphrase) {
            saveProfilePassphraseSheet
        }
        .sheet(isPresented: $isLoadingWithPassphrase) {
            loadProfilePassphraseSheet
        }
        .sheet(isPresented: $isImportingProfile) {
            importProfileSheet
        }
        .sheet(isPresented: $isExportingWithPassphrase) {
            exportProfilePassphraseSheet
        }
        .sheet(isPresented: $isAddingField) {
            AddFieldSheet(
                model: model,
                portfolioKind: model.profile?.kind ?? .company
            )
        }
        .l10nConfirmationDialog(
            "Leave editor?",
            isPresented: $isBackToLibraryConfirmation,
            titleVisibility: .visible
        ) {
            L10n.button("Save and leave") {
                Task {
                    await model.saveToLibrary(modifiedAtISO8601: nowISO8601())
                    // saveToLibrary clears profileDirty on success and sets stage
                    // to .failed on error. Navigate only when the save succeeded:
                    // if dirty is still true the save failed and we must stay in the
                    // editor so the user can see the .failed banner and retry.
                    if !model.profileDirty {
                        model.backToLibrary()
                    }
                }
            }
            L10n.button("Discard changes", role: .destructive) {
                model.backToLibrary()
            }
            L10n.button("Cancel", role: .cancel) {}
        } message: {
            L10n.text("You have unsaved changes to this portfolio.")
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
        // Boot from .idle into .library when the user ENTERS Fill, never at
        // app launch: refreshing the library decrypts the index with a
        // Keychain-held key, and a Keychain prompt must always be the result
        // of a user action.
        .onAppear {
            if isActive {
                activateLibraryIfNeeded()
            }
        }
        .onChange(of: isActive) { _, nowActive in
            if nowActive {
                activateLibraryIfNeeded()
            }
        }
        .l10nAlert("Unlock your portfolio library?", isPresented: $isShowingKeychainNote) {
            L10n.button("Continue") {
                hasSeenLibraryKeychainNote = true
                Task { await model.refreshLibrary() }
            }
            L10n.button("Not Now", role: .cancel) {
                hasSeenLibraryKeychainNote = true
            }
        } message: {
            L10n.text("Your portfolio library is encrypted with a key stored in your macOS Keychain. macOS will confirm with Touch ID (or your password); the key never leaves this Mac. You will only see this explanation once.")
        }
    }

    /// First activation loads the library; the very first time ever, a short
    /// note explains the upcoming Keychain permission dialog first.
    private func activateLibraryIfNeeded() {
        guard model.stage == .idle else { return }
        if hasSeenLibraryKeychainNote {
            Task { await model.refreshLibrary() }
        } else {
            isShowingKeychainNote = true
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isActive {
            switch activeSurface {
            case .library:
                libraryToolbar
            case .profile:
                profileBuilderToolbar
            case .review:
                fillReviewToolbar
            }
        }
    }

    private var activeSurface: FillShellSurface {
        Self.surface(
            for: model.stage,
            failureContext: model.failureContext
        )
    }

    static func surface(
        for stage: FillStage,
        failureContext: FillFailureContext?
    ) -> FillShellSurface {
        switch stage {
        case .library:
            return .library
        case .idle, .importingSources, .extracting, .profileReady:
            return .profile
        case .planning, .reviewing, .applying, .done:
            return .review
        case .failed:
            switch failureContext {
            case .library, nil: return .library
            case .profile: return .profile
            case .review: return .review
            }
        }
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        // Library toolbar is intentionally minimal; the heavy actions live in
        // PortalLibraryBody's top bar (New Portfolio + Import). The toolbar just
        // carries the mode switcher from RootShell (principal placement).
        ToolbarItemGroup(placement: .automatic) {
            EmptyView()
        }
    }

    @ToolbarContentBuilder
    private var profileBuilderToolbar: some ToolbarContent {
        // Navigation group: Back to Library, Add Sources
        ToolbarItemGroup(placement: .navigation) {
            Button {
                requestBackToLibrary()
            } label: {
                L10n.label("Back to Library", systemImage: "arrow.backward")
            }
            .l10nHelp("Return to the portfolio library")

            if profilePrimaryAction != .addSources {
                Button {
                    presentAddSources()
                } label: {
                    L10n.label("Add Sources", systemImage: "doc.badge.plus")
                }
                .l10nHelp("Add source documents to extract profile fields from (PDF, Word, or plain text)")
            }
        }

        // One primary next action plus a More menu keeps the workflow legible
        // on narrow windows while retaining every advanced command.
        ToolbarItemGroup(placement: .automatic) {
            Button(action: runProfilePrimaryAction) {
                L10n.label(
                    profilePrimaryActionLabel,
                    systemImage: profilePrimaryActionIcon
                )
            }
            .labelStyle(.titleAndIcon)
            .buttonStyle(.borderedProminent)
            .tint(CounselTheme.inkAccentFill)
            .disabled(!canRunProfilePrimaryAction)
            .help(L10n.string(profilePrimaryActionHelp))

            Menu {
                Button {
                    isAddingField = true
                } label: {
                    L10n.label("Add Field", systemImage: "plus.circle")
                }
                .disabled(model.profile == nil)

                Button {
                    Task { await model.saveToLibrary(modifiedAtISO8601: nowISO8601()) }
                } label: {
                    L10n.label("Save to Library", systemImage: "checkmark.circle")
                }
                .disabled(!canSaveToLibrary)

                if FillProfilePrimaryAction.offersUnsavedTargetOption(
                    hasProfile: model.profile != nil,
                    needsSave: profileNeedsSave
                ) {
                    Button(action: presentOpenTarget) {
                        L10n.label("Choose Target Without Saving", systemImage: "doc.text")
                    }
                    .disabled(!canOpenTarget)
                    .l10nHelp("Use this profile for the current fill without adding it to the library")
                }

                if !model.sourcePaths.isEmpty, model.profile != nil {
                    Button(action: extractProfileFromSources) {
                        L10n.label("Re-extract from Sources", systemImage: "arrow.clockwise")
                    }
                    .disabled(!canExtract)
                }

                Divider()

                Button(action: beginSaveProfile) {
                    L10n.label("Export Profile", systemImage: "tray.and.arrow.up")
                }
                .disabled(!canSaveProfile)

                Button(action: beginLoadProfile) {
                    L10n.label("Load Profile", systemImage: "tray.and.arrow.down")
                }
            } label: {
                L10n.label("More", systemImage: "ellipsis.circle")
            }
            .l10nHelp("More profile actions")
        }
    }

    @ToolbarContentBuilder
    private var fillReviewToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                model.backToProfile()
                applyMessage = nil
            } label: {
                L10n.label("Back to Profile", systemImage: "arrow.backward")
            }
            .l10nHelp("Return to the profile builder")
        }

        ToolbarItemGroup(placement: .automatic) {
            if case .reviewing = model.stage {
                Button {
                    beginApplyFill()
                } label: {
                    L10n.label("Apply Fill", systemImage: "square.and.arrow.down")
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.borderedProminent)
                .tint(CounselTheme.inkAccentFill)
                .l10nHelp("Apply confirmed fills and write the output document")
            }

            Menu {
                if case .reviewing = model.stage {
                    Button {
                        model.acceptAllProposed()
                    } label: {
                        L10n.label("Accept All Proposed", systemImage: "checkmark.circle")
                    }
                }

                Button(action: presentOpenTarget) {
                    L10n.label("Choose Another Target", systemImage: "doc.text")
                }
                .disabled(model.stage == .planning || model.stage == .applying)
            } label: {
                L10n.label("More", systemImage: "ellipsis.circle")
            }
            .l10nHelp("More fill actions")
        }
    }

    // MARK: - Profile builder view

    private var profileBuilderView: some View {
        VStack(spacing: 0) {
            profileStatusBanner
            ProfileBuilderBody(
                model: model,
                sourcePaths: model.sourcePaths,
                primaryActionTitle: profilePrimaryActionLabel,
                primaryActionHelp: profilePrimaryActionHelp,
                canRunPrimaryAction: canRunProfilePrimaryAction,
                onPrimaryAction: runProfilePrimaryAction,
                onLoadProfile: beginLoadProfile
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
                Text(verbatim: extractingLabel)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(CounselTheme.textSecondary)
                Spacer(minLength: 0)
            }
        } else if case .importingSources = model.stage {
            bannerChrome {
                ProgressView()
                    .controlSize(.small)
                L10n.text("Importing source documents")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
                Spacer(minLength: 0)
            }
        } else if case .profileReady = model.stage {
            if !model.sourceWarnings.isEmpty {
                bannerChrome {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(CounselTheme.danger)
                    Text(verbatim: String(
                        format: L10n.string("Some sources could not be imported: %@"),
                        model.sourceWarnings.prefix(3).joined(separator: "; ") as NSString
                    ))
                        .font(.callout)
                        .foregroundStyle(CounselTheme.danger)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
            } else if model.profile?.incomplete == true {
                bannerChrome {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(CounselTheme.danger)
                    L10n.text("Extraction could not fully scan all segments. Some fields may be missing.")
                        .font(.callout)
                        .foregroundStyle(CounselTheme.danger)
                    Spacer(minLength: 0)
                }
            }
            if let conflicted = model.profile?.conflictedKeys, !conflicted.isEmpty {
                conflictBanner(keys: conflicted)
            }
        } else if model.stage == .idle {
            // Empty state hint (when not booted yet)
            bannerChrome {
                L10n.text("Add source documents, then click Extract to build a profile.")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
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
        }
    }

    private func conflictBanner(keys: [ProfileFieldKey]) -> some View {
        bannerChrome {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(CounselTheme.danger)
            let names = keys.map {
                ProfileFieldPresentation.localizedName(for: $0)
            }.joined(separator: ", ")
            Text(verbatim: String(
                format: L10n.string(
                    "Conflicts in: %@. Use the resolve controls below to keep one value per field."
                ),
                names as NSString
            ))
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
                isActive: isActive,
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
                L10n.text("Planning fill")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
                Spacer(minLength: 0)
            }
        } else if case .applying = model.stage {
            bannerChrome {
                ProgressView()
                    .controlSize(.small)
                L10n.text("Applying fill")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
                Spacer(minLength: 0)
            }
        } else if case .done(let report) = model.stage {
            bannerChrome {
                Image(systemName: "checkmark.seal")
                    .foregroundStyle(CounselTheme.inkAccent)
                Text(verbatim: FillStatusPresentation.completed(
                    filled: report.filledCount,
                    fileName: report.outputURL.lastPathComponent,
                    skipped: report.skipped.count
                ))
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
                Text(verbatim: FillStatusPresentation.reviewing(
                    total: total,
                    confirmed: confirmed
                ))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(CounselTheme.textPrimary)
                if unmatched > 0 {
                    L10n.text("\u{00B7}  %lld unmatched", unmatched)
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
        !model.sourcePaths.isEmpty
            && model.modelPath.flatMap {
                $0.isEmpty ? nil : $0
            } != nil
            && !(model.stage == .importingSources || model.stage == .extracting)
    }

    private var extractDisabledReason: String {
        if model.sourcePaths.isEmpty { return "Add at least one source document first" }
        if model.modelPath == nil || (model.modelPath ?? "").isEmpty {
            return "Requires an on-device model. Open Settings, then AI, "
                + "and add a model to enable this."
        }
        return "Extract profile fields from the source documents"
    }

    private var canSaveProfile: Bool {
        guard let profile = model.profile else { return false }
        return profile.conflictedKeys.isEmpty
    }

    /// Save to library: requires a profile with no conflicts, and either the dirty
    /// flag is set OR the portfolio has never been saved to the library (nil id means
    /// this is a new portfolio that exists only in memory and is always saveable when
    /// conflict-free).
    private var canSaveToLibrary: Bool {
        guard let profile = model.profile else { return false }
        guard profile.conflictedKeys.isEmpty else { return false }
        guard FillProfilePrimaryAction.allowsProfilePersistence(during: model.stage) else {
            return false
        }
        return model.profileDirty || model.currentPortfolioID == nil
    }

    private var canOpenTarget: Bool {
        model.profile.map { $0.conflictedKeys.isEmpty } == true
            && !(model.stage == .importingSources || model.stage == .extracting)
    }

    private var profileNeedsSave: Bool {
        model.profile != nil
            && (model.profileDirty || model.currentPortfolioID == nil)
    }

    private var profilePrimaryAction: FillProfilePrimaryAction {
        FillProfilePrimaryAction.resolve(
            hasProfile: model.profile != nil,
            hasSources: !model.sourcePaths.isEmpty,
            needsSave: profileNeedsSave
        )
    }

    private var profilePrimaryActionLabel: String {
        switch profilePrimaryAction {
        case .addSources: return "Add Sources"
        case .extract: return "Extract Profile"
        case .saveAndChooseTarget: return "Save & Choose Target"
        case .chooseTarget: return "Choose Target"
        }
    }

    private var profilePrimaryActionIcon: String {
        switch profilePrimaryAction {
        case .addSources: return "doc.badge.plus"
        case .extract: return "text.magnifyingglass"
        case .saveAndChooseTarget: return "arrow.right.doc.on.clipboard"
        case .chooseTarget: return "doc.text"
        }
    }

    private var canRunProfilePrimaryAction: Bool {
        switch profilePrimaryAction {
        case .addSources: return true
        case .extract: return canExtract
        case .saveAndChooseTarget: return canSaveToLibrary
        case .chooseTarget: return canOpenTarget
        }
    }

    private var profilePrimaryActionHelp: String {
        switch profilePrimaryAction {
        case .addSources:
            return "Add source documents to build a client profile"
        case .extract:
            return extractDisabledReason
        case .saveAndChooseTarget:
            return "Save this portfolio, then choose the Word or PDF document to fill"
        case .chooseTarget:
            return "Choose the Word or PDF document to fill"
        }
    }

    private func runProfilePrimaryAction() {
        switch profilePrimaryAction {
        case .addSources:
            presentAddSources()
        case .extract:
            extractProfileFromSources()
        case .saveAndChooseTarget:
            Task {
                await model.saveToLibrary(modifiedAtISO8601: nowISO8601())
                guard case .profileReady = model.stage,
                      !model.profileDirty,
                      model.currentPortfolioID != nil else { return }
                presentOpenTarget()
            }
        case .chooseTarget:
            presentOpenTarget()
        }
    }

    private func extractProfileFromSources() {
        let created = nowISO8601()
        let label = model.profile?.label
            ?? model.sourcePaths.first?.deletingPathExtension().lastPathComponent
            ?? "Profile"
        let kind = model.profile?.kind ?? .company
        Task {
            await model.extractProfile(
                sources: model.sourcePaths,
                label: label,
                createdAtISO8601: created,
                kind: kind
            )
        }
    }

    private var extractingLabel: String {
        let pct = Int((model.progress * 100).rounded())
        return String(
            format: L10n.string("Extracting  %lld%%"),
            Int64(pct)
        )
    }

    // MARK: - Back to Library

    /// Called from toolbar "Back to Library" in the editor stage.
    /// If profileDirty, shows the Save/Discard confirmation dialog; otherwise
    /// navigates immediately.
    private func requestBackToLibrary() {
        if model.profileDirty {
            isBackToLibraryConfirmation = true
        } else {
            model.backToLibrary()
        }
    }

    // MARK: - Library Import

    private func beginImportProfile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [Self.profileType]
        panel.message = L10n.string("Choose a .ldaprofile file to import into the library.")
        panel.prompt = L10n.string("Import")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingImportURL = url
        passphraseInput = ""
        isImportingProfile = true
    }

    // MARK: - Library Export

    private func beginExportFromLibrary(_ summary: PortfolioSummary) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [Self.profileType]
        savePanel.message = String(
            format: L10n.string("Export \"%@\" as an encrypted .ldaprofile file."),
            summary.label
        )
        savePanel.nameFieldStringValue = summary.label + ".ldaprofile"
        guard savePanel.runModal() == .OK, let url = savePanel.url else { return }
        exportingSummary = summary
        pendingExportURL = url
        passphraseInput = ""
        isExportingWithPassphrase = true
    }

    // MARK: - Add Sources

    private func presentAddSources() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.sourceContentTypes
        panel.message = L10n.string("Choose source documents to extract profile fields from.")
        panel.prompt = L10n.string("Add")
        guard panel.runModal() == .OK else { return }
        let new = panel.urls.filter { url in
            !model.sourcePaths.contains(url)
        }
        model.sourcePaths.append(contentsOf: new)
    }

    // MARK: - Open fill target

    private func presentOpenTarget() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = Self.targetContentTypes
        panel.message = L10n.string("Choose the Word or PDF document to fill.")
        panel.prompt = L10n.string("Open")
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
        savePanel.message = L10n.string("Choose a folder for the filled output document.")
        savePanel.prompt = L10n.string("Save Here")
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
        savePanel.message = L10n.string("Save the current profile as an encrypted .ldaprofile file.")
        savePanel.nameFieldStringValue = (model.profile?.label ?? "profile") + ".ldaprofile"
        guard savePanel.runModal() == .OK, let url = savePanel.url else { return }
        pendingSaveURL = url
        passphraseInput = ""
        isSavingWithPassphrase = true
    }

    // MARK: - Load Profile flow

    private func beginLoadProfile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [Self.profileType]
        panel.message = L10n.string("Choose a .ldaprofile file to load.")
        panel.prompt = L10n.string("Load")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingLoadURL = url
        passphraseInput = ""
        isLoadingWithPassphrase = true
    }

    // MARK: - Helpers

    private func announceStage(_ stage: FillStage) {
        switch stage {
        case .profileReady:
            AccessibilityNotification.Announcement(
                L10n.string("Profile ready. Review and edit fields below.")
            ).post()
        case .reviewing:
            let count = model.blanks.count
            AccessibilityNotification.Announcement(
                String(
                    format: L10n.string(
                        count == 1
                            ? "Review ready. %lld blank to review."
                            : "Review ready. %lld blanks to review."
                    ),
                    Int64(count)
                )
            ).post()
        case .done(let report):
            AccessibilityNotification.Announcement(
                String(
                    format: L10n.string(
                        report.filledCount == 1
                            ? "Fill complete. %lld blank filled."
                            : "Fill complete. %lld blanks filled."
                    ),
                    Int64(report.filledCount)
                )
            ).post()
        case .failed(let detail):
            AccessibilityNotification.Announcement(String(
                format: L10n.string("Fill failed. %@"),
                detail as NSString
            )).post()
        default:
            break
        }
    }

    func showAlert(title: String, text: String, warning: Bool) { // internal for FillShellSheets.swift
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = warning ? .warning : .informational
        alert.addButton(withTitle: L10n.string("OK"))
        alert.runModal()
    }

    static func isUnderICloud(_ url: URL) -> Bool { // internal for FillShellSheets.swift
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
