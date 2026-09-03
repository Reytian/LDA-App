//
//  OnboardingView.swift
//  LDAUI
//
//  The first-run sheet (R13/R17). Three pages: language, the model ask, then
//  what the app does (the round-trip in three steps), the honest privacy
//  promise and the cautions. Dismissing the sheet leaves the user at the drop
//  zone.
//
//  Language is page 1 because a lawyer who reads Chinese must be able to read
//  every page that follows it, including the ask. The model page exists
//  because the app cannot find people's names or company names without a
//  detection model, and no model ships inside the app. It is a CHOICE among
//  four routes (three rungs, an import, or defer), not a consent ritual:
//  there is no acknowledgement checkbox, because a tick box before a lawyer's
//  first document buys a defensible log entry rather than an informed
//  reader, and it is unresolvable on an 8 GB Mac.
//
//  Escape is blocked on every page except the last (.steps), and nowhere on
//  the .unavailable route: AppShell.swift's onboardingDismissed() writes
//  .declined for an unanswered ask, and .declined is honoured forever, so a
//  page in front of that ask with Escape enabled would let a user
//  permanently silence a question they never saw. On an 8/12 GB Mac the
//  recorded answer (.unavailable) is correct however the sheet closes, and
//  the page is already a statement with no remedy, so Escape stays enabled
//  there.
//
//  Return-key ownership, one per page: language -> Continue; model -> the
//  primary install action (or the import action on .importOnly, or Continue
//  on .unavailable); steps -> its own final action. Only one page is on screen, so no
//  collision.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import SwiftUI

/// The first-run onboarding sheet.
public struct OnboardingView: View {

    /// Why this sheet is on screen.
    ///
    /// `.firstRun` is the three-page sheet (two when a model is already
    /// present). `.modelAskOnly` is the return visit for an unresolved ask
    /// (pressed Download and cancelled, or the drive is still at the
    /// office): only the model page exists and answering dismisses, because
    /// the language question is already settled and the three steps were
    /// already read.
    public enum Mode: Equatable {
        case firstRun
        case modelAskOnly
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

    /// The tier manifest, passed in rather than reloaded: every size and
    /// timing figure on the model page comes from it, so those numbers have
    /// one source of truth.
    let catalog: ModelCatalog

    /// Whether ANY tier could run on this Mac. False on 8 GB and 12 GB, where
    /// the model page becomes a statement with one Continue, because a page
    /// with no available remedy is a ritual.
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

    @State private var page: OnboardingPresentation.Page

    /// The rung the primary action would install. Defaults to the wizard's
    /// recommendation, but the user can tap a different selectable row: the
    /// recommendation is carried by this default plus the Recommended badge,
    /// never by reordering the ladder.
    @State private var selectedLevel: DetectionLevel?

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
        self._page = State(initialValue: OnboardingPresentation.firstPage(mode: mode))
        self._selectedLevel = State(initialValue: OnboardingPresentation.recommendedLevel(catalog: catalog))
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let chip = OnboardingPresentation.stepChip(
                    position: OnboardingPresentation.position(of: page, mode: mode, hasModel: hasModel),
                    count: OnboardingPresentation.pageCount(mode: mode, hasModel: hasModel),
                    language: currentLanguage
                ) {
                    Text(verbatim: chip)
                        .font(CounselTheme.Typography.supporting)
                        .foregroundStyle(CounselTheme.textSecondary)
                }

                switch page {
                case .language: languagePage
                case .model: modelAskPage
                case .steps: stepsPage
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
        // answer: there every page is (or leads only to) a statement, so
        // Escape is the same as working through to its single Continue.
        .interactiveDismissDisabled(page != .steps && route != .unavailable)
    }

    private var currentLanguage: AppLanguage { AppLanguage.from(rawValue: languageRaw) }

    // MARK: - Page 1: language

    /// A lawyer who reads Chinese must be able to read every page that
    /// follows this one, including the model ask, so the language choice
    /// comes first and answering it is the only way off the page.
    private var languagePage: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(verbatim: OnboardingPresentation.languageStepTitle(language: currentLanguage))
                .font(.system(.title2, design: .serif).weight(.semibold))
                .foregroundStyle(CounselTheme.textPrimary)
            Text(verbatim: OnboardingPresentation.languageStepExplanation(language: currentLanguage))
                .font(.callout)
                .foregroundStyle(CounselTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(AppLanguage.allCases) { language in
                    languageRow(language)
                }
            }

            HStack {
                Spacer()
                Button {
                    advance()
                } label: {
                    Text(verbatim: L10n.string("Continue", language: currentLanguage))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(CounselTheme.inkAccentFill)
            }
        }
    }

    private func languageRow(_ language: AppLanguage) -> some View {
        let isSelected = languageRaw == language.rawValue
        return Button {
            languageRaw = language.rawValue
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? CounselTheme.inkAccent : CounselTheme.textSecondary)
                Text(verbatim: language.nativeName(language: currentLanguage))
                    .foregroundStyle(CounselTheme.textPrimary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Page 2: the model ask

    /// Which ask this Mac gets.
    private var route: ModelSetupPresentation.AskRoute {
        ModelSetupPresentation.askRoute(
            canRunAModel: canRunAModel,
            canDownload: quickTier.map { AISettings.canDownload($0) } ?? false
        )
    }

    /// The tier the ask offers when memory rules out everything. Quick is the
    /// one rung that runs on the 16 GB minimum spec.
    private var quickTier: ModelTier? { catalog.tier(for: .quick) }

    private var installedGB: Double { MemoryGate.installedGB() }

    private func isSelectable(_ level: DetectionLevel) -> Bool {
        guard let tier = catalog.tier(for: level) else { return false }
        return MemoryGate.availability(for: tier, installedGB: installedGB).isSelectable
    }

    /// The rungs this Mac can run, in ladder order.
    private var selectableLevels: [DetectionLevel] {
        DetectionLevel.modelLevels.filter(isSelectable)
    }

    /// The rungs `MemoryGate` blocks on this Mac, collapsed into one sentence
    /// (`ModelSetupPresentation.blockedRungsLine`) rather than given rows:
    /// hiding them entirely would leave "how do I choose" unanswered on the
    /// machine where the answer is "your Mac decided", and a full row each
    /// would spend about 50 characters restating the same fact twice.
    private var blockedLevels: [DetectionLevel] {
        DetectionLevel.modelLevels.filter { !isSelectable($0) }
    }

    /// The rung the wizard pre-selects, never Most thorough.
    private var recommendedLevel: DetectionLevel? {
        OnboardingPresentation.recommendedLevel(catalog: catalog, installedGB: installedGB)
    }

    private var selectedTier: ModelTier? {
        selectedLevel.flatMap { catalog.tier(for: $0) }
    }

    /// The selected rung's download phase, or `.waiting` when nothing is
    /// selected or selectable.
    private var phase: ModelInstallPhase {
        selectedTier.map { installer.phase(for: $0) } ?? .waiting
    }

    private var isBusy: Bool {
        switch phase {
        case .waiting, .cancelled: return false
        default: return true
        }
    }

    /// The model ask: a choice among three rungs, the verified import, and
    /// deferring, or (on an 8/12 GB Mac) a statement with one Continue.
    ///
    /// Tinted with the accent rather than danger red: at first run this is a
    /// setup task, not an error. Danger red is reserved for the pre-scan
    /// advisory in AppShell, where the user is about to act on a reduced scan.
    private var modelAskPage: some View {
        Label {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: L10n.string(ModelSetupPresentation.askTitleKey(route: route), language: currentLanguage))
                    .font(.system(.title2, design: .serif).weight(.semibold))
                    .foregroundStyle(CounselTheme.textPrimary)

                Text(verbatim: ModelSetupPresentation.askBody(route: route, language: currentLanguage).first ?? "")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if route == .unavailable {
                    unavailableActions
                } else {
                    optionsList
                    askActions
                    footnotes
                }
            }
        } icon: {
            Image(systemName: route == .unavailable
                  ? "exclamationmark.circle"
                  : "arrow.down.circle")
                .foregroundStyle(CounselTheme.inkAccent)
        }
    }

    /// The three rungs (only the selectable ones get rows), the collapsed
    /// blocked-rungs sentence, and the verified-import row. Rows disable
    /// while a download is in flight rather than disappearing, so the choice
    /// stays legible.
    @ViewBuilder
    private var optionsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(selectableLevels, id: \.rawValue) { level in
                rungRow(level)
            }
            if !blockedLevels.isEmpty {
                Text(verbatim: ModelSetupPresentation.blockedRungsLine(
                    blockedLevels: blockedLevels,
                    installedGB: Int(installedGB.rounded()),
                    language: currentLanguage
                ))
                    .font(CounselTheme.Typography.supporting)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if route == .download {
                importRow
            }
        }
    }

    private func rungRow(_ level: DetectionLevel) -> some View {
        let tier = catalog.tier(for: level)
        let isSelected = selectedLevel == level
        let isRecommended = level == recommendedLevel
        return Button {
            selectedLevel = level
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? CounselTheme.inkAccent : CounselTheme.textSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        L10n.text(level.displayName)
                            .font(.body.weight(.medium))
                            .foregroundStyle(CounselTheme.textPrimary)
                        if isRecommended {
                            Text(verbatim: ModelSetupPresentation.recommendedBadge(language: currentLanguage))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(CounselTheme.inkAccent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3)
                                        .stroke(CounselTheme.inkAccent.opacity(0.4), lineWidth: 1)
                                )
                        }
                    }
                    if let tier {
                        Text(verbatim: ModelAnnotation.localizedFacts(
                            for: tier, bundled: false, language: currentLanguage
                        ))
                            .font(CounselTheme.Typography.supporting)
                            .foregroundStyle(CounselTheme.textSecondary)
                    }
                    // The deciding-factor line renders only when there is a
                    // decision to make: on the 16 GB Mac most PRC lawyers own,
                    // one rung is selectable and the honest answer is the
                    // blocked-rungs sentence above, not a guidance line
                    // restating that there is no choice.
                    if selectableLevels.count > 1 {
                        Text(verbatim: OnboardingPresentation.chooseLine(for: level, language: currentLanguage))
                            .font(CounselTheme.Typography.supporting)
                            .foregroundStyle(CounselTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// "I Already Have the File...", as a row on `.download` (secondary to
    /// the rungs above) and promoted to the page's one primary action on
    /// `.importOnly` (see `askActions`), never both: showing it twice would
    /// read as two different offers.
    private var importRow: some View {
        Button {
            chooseExistingFile()
        } label: {
            HStack {
                L10n.text("I Already Have the File\u{2026}")
                    .foregroundStyle(CounselTheme.textPrimary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    /// The primary action, then the defer link with its one consequence line.
    /// The fix is first and owns the default action, so Return spends
    /// bandwidth rather than confidentiality.
    @ViewBuilder
    private var askActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch phase {
            case .waiting, .cancelled:
                if route == .download {
                    Button {
                        guard let level = selectedLevel, let tier = selectedTier else { return }
                        AISettings.recordModelSetupAnswer(.accepted)
                        AISettings.setDetectionLevel(level)
                        installer.install(tier)
                    } label: {
                        Text(verbatim: ModelSetupPresentation.downloadAndUseButtonTitle(language: currentLanguage))
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(CounselTheme.inkAccentFill)
                    .disabled(selectedTier == nil)
                } else {
                    // Offline mode refuses the download and may be MDM-forced,
                    // so the verified import becomes the primary route.
                    // Nothing here offers to turn offline mode off: the app
                    // must not change a security setting for the user.
                    Button {
                        chooseExistingFile()
                    } label: {
                        L10n.text("I Already Have the File\u{2026}")
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(CounselTheme.inkAccentFill)
                }
            default:
                progressLine
            }

            HStack(spacing: 8) {
                L10n.button("Not Now") { decline() }
                    .buttonStyle(.link)
                Text(verbatim: ModelSetupPresentation.deferConsequenceLine(language: currentLanguage))
                    .font(CounselTheme.Typography.supporting)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The 8 GB and 12 GB Mac: the exact memory gap, then one Continue. There
    /// is no button to add a model here, because adding a file by hand would
    /// not make the model runnable.
    @ViewBuilder
    private var unavailableActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let tier = quickTier {
                Text(verbatim: MemoryGate.localizedRequirementText(for: tier, language: currentLanguage))
                    .font(CounselTheme.Typography.supporting)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                AISettings.recordModelSetupAnswer(.unavailable)
                advance()
            } label: {
                Text(verbatim: L10n.string("Continue", language: currentLanguage))
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .tint(CounselTheme.inkAccentFill)
        }
    }

    /// The provenance line: names the download host and the offline
    /// alternative in one sentence, or (offline mode) states that downloads
    /// are off and names the same alternative. Stays on screen through
    /// `.downloading`, `.verifying`, `.failed` and `.installed`, because
    /// today it renders only in `.waiting`/`.cancelled` and the "get it on
    /// another Mac" sentence vanishes at the exact moment a mainland download
    /// fails.
    private var footnotes: some View {
        Text(verbatim: ModelSetupPresentation.provenanceLine(
            route: route,
            hostDescription: quickTier?.sourceURL ?? "",
            language: currentLanguage
        ))
            .font(CounselTheme.Typography.supporting)
            .foregroundStyle(CounselTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The transfer, in place of the primary button. The user can read the
    /// next steps while it arrives: it is owned by the app, not by this
    /// sheet, so pressing Continue costs no waiting.
    @ViewBuilder
    private var progressLine: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch phase {
            case let .downloading(fraction, received, expected):
                Text(verbatim: ModelSetupPresentation.modelDownloadingLine(language: currentLanguage))
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ProgressView(value: fraction)
                HStack {
                    Text(verbatim: String(
                        format: L10n.string("%@ of %@", language: currentLanguage),
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
                    L10n.button("Cancel") { cancelDownload() }
                }
                continueButton
            case .verifying:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    L10n.text("Checking the file is exactly what it should be")
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
                        L10n.button("Try Again") { retryDownload() }
                    }
                    L10n.button("Manage Models\u{2026}") { openModelManagement() }
                }
                continueButton
            case .installed:
                Text(verbatim: ModelSetupPresentation.modelInstalledLine(language: currentLanguage))
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
        Button {
            advance()
        } label: {
            Text(verbatim: L10n.string("Continue", language: currentLanguage))
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .tint(CounselTheme.inkAccentFill)
    }

    // MARK: - Page 3: what the app does

    private var stepsPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: OnboardingPresentation.stepsTitle(language: currentLanguage))
                    .font(.system(.title2, design: .serif).weight(.semibold))
                    .foregroundStyle(CounselTheme.textPrimary)
                Text(verbatim: OnboardingPresentation.stepsLede(language: currentLanguage))
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                step(
                    number: "1",
                    icon: "tray.and.arrow.down",
                    title: OnboardingPresentation.step1Title(language: currentLanguage),
                    // Without a model the shipped sentence promises names
                    // three lines below the block that says they are not
                    // found. Which kinds of value a scan can find is exactly
                    // what the model page above decides.
                    text: OnboardingPresentation.step1Text(hasModel: hasModel, language: currentLanguage)
                )
                step(
                    number: "2",
                    icon: "doc.richtext",
                    title: OnboardingPresentation.step2Title(language: currentLanguage),
                    text: OnboardingPresentation.step2Text(language: currentLanguage)
                )
                step(
                    number: "3",
                    icon: "doc.badge.arrow.up",
                    title: OnboardingPresentation.step3Title(language: currentLanguage),
                    text: OnboardingPresentation.step3Text(language: currentLanguage)
                )
            }

            Divider()

            // The privacy summary distinguishes LDA's own processing from the
            // external services a user may choose for an exported document.
            Label {
                Text(verbatim: OnboardingPresentation.privacyParagraph(language: currentLanguage))
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
                    Text(verbatim: OnboardingPresentation.visibilityCaution(language: currentLanguage))
                    Text(verbatim: OnboardingPresentation.clipboardCaution(
                        autoClearSeconds: Int(SensitiveClipboard.autoClearAfter),
                        language: currentLanguage
                    ))
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
                    L10n.button("Set Up a Model\u{2026}") { openModelManagement() }
                        .controlSize(.small)
                }
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Text(verbatim: L10n.string("Get Started", language: currentLanguage))
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
        guard let tier = selectedTier else { return }
        installer.cancel(tier)
    }

    private func retryDownload() {
        guard let tier = selectedTier else { return }
        installer.install(tier)
    }

    /// Leave the current page: on to the next one at first run, or out of the
    /// sheet on a return visit or at the end of the sequence.
    private func advance() {
        guard let next = OnboardingPresentation.nextPage(after: page, mode: mode, hasModel: hasModel) else {
            isPresented = false
            return
        }
        page = next
    }

    private func step(
        number: String,
        icon: String,
        title: String,
        text: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(CounselTheme.inkAccent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                (Text(verbatim: number) + Text(verbatim: ". ") + Text(verbatim: title))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(CounselTheme.textPrimary)
                Text(verbatim: text)
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
