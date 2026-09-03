//
//  OnboardingView.swift
//  LDAUI
//
//  The first-run sheet (R13). Two pages now: the model ask, then what the app
//  does (the round-trip in three steps), the honest privacy promise and the
//  cautions. Dismissing the sheet leaves the user at the drop zone.
//
//  Page 1 exists because the app cannot find people's names or company names
//  without a detection model, and no model ships inside the app. It is an ASK,
//  not a consent ritual: there is no acknowledgement checkbox, because a tick
//  box before a lawyer's first document buys a defensible log entry rather
//  than an informed reader, and it is unresolvable on an 8 GB Mac. What page 1
//  does have is no exit that is not an answer: Download, I Already Have the
//  File, or Not Now.
//
//  The primary button owns .keyboardShortcut(.defaultAction) on page 1, so
//  Return starts the download rather than carrying the user through to a
//  names-blind scan in one keypress.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import SwiftUI

/// The first-run onboarding sheet.
public struct OnboardingView: View {

    /// Why this sheet is on screen.
    ///
    /// `.firstRun` is the two-page sheet. `.modelAskOnly` is the return visit
    /// for an unresolved ask (pressed Download and cancelled, or the drive is
    /// still at the office): only page 1 exists and answering dismisses,
    /// because the three steps were already read.
    public enum Mode: Equatable {
        case firstRun
        case modelAskOnly
    }

    /// Which page is on screen.
    enum Page: Equatable {
        case model
        case steps
    }

    @Binding var isPresented: Bool
    @AppStorage(AppLanguage.storageKey) private var languageRaw = AppLanguage.system.rawValue

    /// Whether THIS MAC has any detection model: a tier installed in the app
    /// container, one inside the app bundle, or a custom model that resolves.
    ///
    /// No model ships inside the app, so false is the ordinary state of a fresh
    /// install rather than a packaging accident. It asks about the machine, not
    /// about the selected rung: someone who deliberately chose Patterns only
    /// and has a model installed must not be told to add one.
    let hasModel: Bool

    /// The app-owned downloader, so the transfer keeps running when the user
    /// presses Continue and the ask costs no waiting.
    @ObservedObject var installer: ModelInstaller

    /// The tier manifest, passed in rather than reloaded: the size in the
    /// primary button comes from it, so the number has one source of truth.
    let catalog: ModelCatalog

    /// Whether ANY tier could run on this Mac. False on 8 GB and 12 GB, where
    /// the ask becomes a statement with one Continue, because a dialog with no
    /// available remedy is a ritual.
    let canRunAModel: Bool

    let mode: Mode

    /// Dismisses onboarding and opens Manage Models.
    ///
    /// One button into the existing sheet rather than a second download entry
    /// point here. That sheet and the app-owned installer already carry
    /// progress, cancel, resume, the memory gate, the offline-mode gate and
    /// every error string, and `AISettings.canDownload` exists because this
    /// codebase has a history of multi-entry actions where one path was gated
    /// and another was not.
    ///
    /// The shell defers the presentation to this sheet's `onDismiss` rather
    /// than swapping sheets in one tick: two presentation modifiers on one
    /// view have silently never presented in this window before.
    let onOpenModelManagement: () -> Void

    @State private var page: Page

    public init(
        isPresented: Binding<Bool>,
        hasModel: Bool,
        installer: ModelInstaller,
        catalog: ModelCatalog,
        canRunAModel: Bool,
        mode: Mode = .firstRun,
        onOpenModelManagement: @escaping () -> Void
    ) {
        self._isPresented = isPresented
        self.hasModel = hasModel
        self.installer = installer
        self.catalog = catalog
        self.canRunAModel = canRunAModel
        self.mode = mode
        self.onOpenModelManagement = onOpenModelManagement
        // A Mac that already has a model is never asked; it starts on the
        // steps, which is exactly the sheet that shipped before this change.
        self._page = State(initialValue: hasModel ? .steps : .model)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Text("Language")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(CounselTheme.textPrimary)
                    Spacer()
                    // A lawyer who reads Chinese must be able to read the ask,
                    // so the picker stays above it on page 1.
                    Picker("Language", selection: languageBinding) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.nativeName).tag(language)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 210)
                }

                if page == .model {
                    modelAskPage
                } else {
                    stepsPage
                }
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .frame(
            minWidth: 520,
            idealWidth: 620,
            minHeight: 500,
            idealHeight: 620
        )
        .background(CounselTheme.raised)
        // No exit that is not an answer, except on the Mac that has nothing to
        // answer: there the page is a statement, so Escape is the same as its
        // single Continue.
        .interactiveDismissDisabled(page == .model && route != .unavailable)
    }

    // MARK: - Page 1: the ask

    /// Which ask this Mac gets.
    private var route: ModelSetupPresentation.AskRoute {
        ModelSetupPresentation.askRoute(
            canRunAModel: canRunAModel,
            canDownload: quickTier.map { AISettings.canDownload($0) } ?? false
        )
    }

    /// The tier the ask offers. Quick is the one rung that runs on the 16 GB
    /// minimum spec.
    private var quickTier: ModelTier? { catalog.tier(for: .quick) }

    /// The download's phase, or `.waiting` when there is no tier to download.
    private var phase: ModelInstallPhase {
        quickTier.map { installer.phase(for: $0) } ?? .waiting
    }

    /// The model ask: what a scan cannot find without a model, the measured
    /// evidence, and the two routes to fixing it.
    ///
    /// Tinted with the accent rather than danger red: at first run this is a
    /// setup task, not an error. Danger red is reserved for the pre-scan
    /// advisory in AppShell, where the user is about to act on a reduced scan.
    private var modelAskPage: some View {
        Label {
            VStack(alignment: .leading, spacing: 8) {
                Text(LocalizedStringKey(ModelSetupPresentation.askTitleKey(route: route)))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(CounselTheme.textPrimary)

                askBodyParagraphs

                if route == .unavailable {
                    unavailableActions
                } else {
                    switch phase {
                    case .waiting, .cancelled:
                        askActions
                        footnotes
                    default:
                        progressLine
                    }
                }
            }
        } icon: {
            Image(systemName: route == .unavailable
                  ? "exclamationmark.circle"
                  : "arrow.down.circle")
                .foregroundStyle(CounselTheme.inkAccent)
        }
    }

    /// The ask's prose. The last paragraph of the download and import routes
    /// is the measured evidence, set in supporting type so it reads as a
    /// citation rather than as another warning.
    private var askBodyParagraphs: some View {
        let paragraphs = ModelSetupPresentation.askBody(route: route)
        return ForEach(Array(paragraphs.enumerated()), id: \.offset) { item in
            let isEvidence = paragraphs.count > 1 && item.offset == paragraphs.count - 1
            Text(verbatim: item.element)
                .font(isEvidence ? CounselTheme.Typography.supporting : .callout)
                .foregroundStyle(CounselTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The three answers. The fix is first and owns the default action, so
    /// Return spends bandwidth rather than confidentiality.
    @ViewBuilder
    private var askActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if route == .download, let tier = quickTier {
                Button(
                    ModelSetupPresentation.downloadButtonTitle(
                        sizeDescription: tier.downloadSizeDescription
                    )
                ) {
                    AISettings.recordModelSetupAnswer(.accepted)
                    installer.install(tier)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(CounselTheme.inkAccentFill)

                Button("I Already Have the File\u{2026}") { chooseExistingFile() }
            } else {
                // Offline mode refuses the download and may be MDM-forced, so
                // the verified import becomes the primary route. Nothing here
                // offers to turn offline mode off: the app must not change a
                // security setting for the user.
                Button("I Already Have the File\u{2026}") { chooseExistingFile() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(CounselTheme.inkAccentFill)
            }

            Button("Not Now") { decline() }
                .buttonStyle(.link)
        }
    }

    /// The 8 GB and 12 GB Mac: the exact memory gap, then one Continue. There
    /// is no button to add a model here, because adding a file by hand would
    /// not make the model runnable.
    @ViewBuilder
    private var unavailableActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let tier = quickTier {
                Text(verbatim: MemoryGate.localizedRequirementText(for: tier))
                    .font(CounselTheme.Typography.supporting)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Continue") {
                AISettings.recordModelSetupAnswer(.unavailable)
                advance()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .tint(CounselTheme.inkAccentFill)
        }
    }

    /// Both routes are named so the offline one is discoverable at first run.
    private var footnotes: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("No connection: download the model on another Mac, bring it over on a drive, and add the file in Manage Models. LDA checks it before installing it.")
            if route == .importOnly {
                Text("This works with offline mode on. Adding a file makes no network request.")
            }
        }
        .font(CounselTheme.Typography.supporting)
        .foregroundStyle(CounselTheme.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The transfer, in place of the buttons. The user can read the next steps
    /// while it arrives: it is owned by the app, not by this sheet, so pressing
    /// Continue costs no waiting.
    @ViewBuilder
    private var progressLine: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch phase {
            case let .downloading(fraction, received, expected):
                Text("Downloading the detection model. You can read the next steps while it arrives.")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ProgressView(value: fraction)
                HStack {
                    Text(verbatim: String(
                        format: L10n.string("%@ of %@"),
                        ByteCountFormatter.string(
                            fromByteCount: received, countStyle: .file
                        ) as NSString,
                        ByteCountFormatter.string(
                            fromByteCount: expected, countStyle: .file
                        ) as NSString
                    ))
                        .font(CounselTheme.Typography.supporting)
                        .foregroundStyle(CounselTheme.textSecondary)
                    Spacer()
                    Button("Cancel") { cancelDownload() }
                }
                continueButton
            case .verifying:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking the file is exactly what it should be")
                        .font(CounselTheme.Typography.supporting)
                        .foregroundStyle(CounselTheme.textSecondary)
                }
                continueButton
            case let .failed(error):
                Text(verbatim: error.localizedMessage())
                    .font(CounselTheme.Typography.supporting)
                    .foregroundStyle(CounselTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    if error.isRetryable {
                        Button("Try Again") { retryDownload() }
                    }
                    Button("Manage Models\u{2026}") { openModelManagement() }
                }
                continueButton
            case .installed:
                Text("The detection model is installed. A scan will look for names, companies, and addresses.")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                continueButton
            case .waiting, .cancelled:
                EmptyView()
            }
        }
    }

    /// Leaves the ask without abandoning the transfer.
    private var continueButton: some View {
        Button("Continue") { advance() }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .tint(CounselTheme.inkAccentFill)
    }

    // MARK: - Page 2: what the app does

    private var stepsPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Use AI on confidential documents, safely")
                    .font(.system(.title2, design: .serif).weight(.semibold))
                    .foregroundStyle(CounselTheme.textPrimary)
                Text("LDA protects client information before it reaches an AI tool, and puts it back afterwards. Three steps:")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                step(
                    number: "1",
                    icon: "tray.and.arrow.down",
                    title: "Bring documents in",
                    // Without a model the shipped sentence promises names
                    // three lines below the block that says they are not
                    // found. Which kinds of value a scan can find is exactly
                    // what the ask above decides.
                    text: hasModel
                        ? "Drop Word, PDF, or text files (or a .zip). The app finds names, companies, dates, amounts, emails, phones, and IDs, and you review what it will protect."
                        : "Drop Word, PDF, or text files (or a .zip). The app scans each one and you review what it will protect. Which kinds of value it can find depends on the detection model above."
                )
                step(
                    number: "2",
                    icon: "doc.richtext",
                    title: "Hand the safe copy to any AI",
                    text: "Export for AI saves a redacted Markdown file. Upload it to ChatGPT, Claude, or any tool, with your instructions."
                )
                step(
                    number: "3",
                    icon: "doc.badge.arrow.up",
                    title: "Bring the answer back",
                    text: "Restore takes the file the AI gave back and puts the real values in, flagging anything it cannot match with certainty. Save the final document in its original format."
                )
            }

            Divider()

            // The privacy summary distinguishes LDA's own processing from the
            // external services a user may choose for an exported document.
            Label {
                Text("LDA processes document contents and stores the encrypted mapping on this Mac. If you ask it to download a detection model, it connects to the model host. Copying or exporting a document lets you send it to a service you choose, so review that service's privacy settings first.")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock.laptopcomputer")
                    .foregroundStyle(CounselTheme.inkAccent)
            }

            // The cautions, visually separate from the promise and with their
            // own icon.
            //
            // The clipboard sentence is scoped to the MENU-BAR companion on
            // purpose. It is the only path in the app that puts real values on
            // the clipboard; Restore's own file flow writes a file and never
            // touches it. An unscoped version told every user that
            // the flow this sheet just taught them produces something that
            // evaporates, which is both untrue and needlessly alarming. It also
            // avoids promising the clearing outright, because quitting the app
            // inside the window defeats the timer.
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Anything you choose to keep visible stays visible in the exported document.")
                    Text("Restore Clipboard, in the menu-bar icon, is the one action that puts real values on your clipboard; it tries to clear them again about \(Int(SensitiveClipboard.autoClearAfter)) seconds later, so paste promptly and do not rely on the clearing.")
                }
                .font(.callout)
                .foregroundStyle(CounselTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "hand.raised")
                    .foregroundStyle(CounselTheme.textSecondary)
            }

            HStack {
                // A one-click route back for someone who pressed Not Now, so
                // the decision is reversible without hunting through chrome.
                if !hasModel, canRunAModel {
                    Button("Set Up a Model\u{2026}") { openModelManagement() }
                        .controlSize(.small)
                }
                Spacer()
                Button("Get Started") {
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(CounselTheme.inkAccentFill)
            }
        }
    }

    // MARK: - Answers

    /// Not Now. Recorded on the click, not inferred from a dismissal, so
    /// "pressed Set Up a Model then closed Manage Models" is no longer
    /// indistinguishable from "installed a model".
    private func decline() {
        AISettings.recordModelSetupAnswer(.declined)
        advance()
    }

    /// The offline route: the file is on a drive already, so the answer is
    /// accepted and Manage Models takes over.
    private func chooseExistingFile() {
        openModelManagement()
    }

    /// The one route into Manage Models from this sheet, so no button here can
    /// leave the answer alone.
    ///
    /// Pressing any of them is the user acting on the ask, and a stored
    /// "declined" must not survive that: it would silence the return visit for
    /// someone who had in fact taken the ask up. "Accepted" is deliberately
    /// not terminal, so recording it here still asks once more if no file
    /// arrives. The scan gate is unaffected either way, being keyed on the
    /// machine and never on the stored answer.
    private func openModelManagement() {
        AISettings.recordModelSetupAnswer(.accepted)
        onOpenModelManagement()
    }

    private func cancelDownload() {
        guard let tier = quickTier else { return }
        installer.cancel(tier)
    }

    private func retryDownload() {
        guard let tier = quickTier else { return }
        installer.install(tier)
    }

    /// Leave page 1: on to the steps at first run, or out of the sheet on a
    /// return visit, where the steps were already read.
    private func advance() {
        switch mode {
        case .firstRun: page = .steps
        case .modelAskOnly: isPresented = false
        }
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { AppLanguage.from(rawValue: languageRaw) },
            set: { languageRaw = $0.rawValue }
        )
    }

    private func step(
        number: String,
        icon: String,
        title: LocalizedStringKey,
        text: LocalizedStringKey
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(CounselTheme.inkAccent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                (Text(verbatim: "\(number). ") + Text(title))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(CounselTheme.textPrimary)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
