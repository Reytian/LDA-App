//
//  OnboardingView.swift
//  LDAUI
//
//  First-run pages: language, the document workflow, and optional AI setup.
//  Installs without a usable detection model also show the model choice.
//  Dismissing leaves the user at the document intake screen.
//
//  Language is page 1 because a lawyer who reads Chinese must be able to read
//  every page that follows it, including the ask. The model page exists
//  because the app cannot find people's names or company names without a
//  detection model. Current releases include LDA V4. It is a CHOICE among
//  four routes (three rungs, an import, or defer), not a consent ritual:
//  there is no acknowledgement checkbox, because a tick box before a lawyer's
//  first document buys a defensible log entry rather than an informed
//  reader, and it is unresolvable on an 8 GB Mac.
//
//  Escape is blocked before the workflow (.steps) page, and nowhere on
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
    /// `.firstRun` is the four-page sheet (three when a model is already
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
    /// Current releases include LDA V4, so the model ask is a fallback for
    /// installations without a usable model. It asks about the machine, not
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
        OnboardingPageLayout(pageID: page) {
            switch page {
            case .language: languagePage
            case .model: modelAskPage
            case .steps: stepsPage
            case .integrations: integrationPage
            }
        } footer: {
            navigationFooter
        }
        // macOS otherwise presents the sheet at its minimum size. Keep a
        // comfortable initial reading width; the content scrolls independently.
        .frame(width: 680, height: 640)
        .font(CounselTheme.Typography.readingBody)
        .controlSize(.large)
        .environment(\.appLanguage, currentLanguage)
        .interactiveDismissDisabled(page != .steps && page != .integrations && route != .unavailable)
    }

    private var currentLanguage: AppLanguage { AppLanguage.from(rawValue: languageRaw) }

    // MARK: - Page 1: language

    /// A lawyer who reads Chinese must be able to read every page that
    /// follows this one, including the model ask, so the language choice
    /// comes first and answering it is the only way off the page.
    private var languagePage: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(verbatim: OnboardingPresentation.languageStepTitle(language: currentLanguage))
                .font(CounselTheme.Typography.pageTitle)
                .foregroundStyle(CounselTheme.textPrimary)
            Text(verbatim: OnboardingPresentation.languageStepExplanation(language: currentLanguage))
                .font(CounselTheme.Typography.supporting)
                .foregroundStyle(CounselTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(AppLanguage.allCases) { language in
                    languageRow(language)
                }
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
                    .accessibilityHidden(true)
                Text(verbatim: language.nativeName(language: currentLanguage))
                    .foregroundStyle(CounselTheme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(isSelected ? CounselTheme.inkAccent.opacity(0.08) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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
                    .font(CounselTheme.Typography.pageTitle)
                    .foregroundStyle(CounselTheme.textPrimary)

                Text(verbatim: ModelSetupPresentation.askBody(route: route, language: currentLanguage).first ?? "")
                    .font(CounselTheme.Typography.supporting)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if route == .unavailable {
                    if let tier = quickTier {
                        Text(verbatim: MemoryGate.localizedRequirementText(for: tier, language: currentLanguage))
                            .font(CounselTheme.Typography.supporting)
                            .foregroundStyle(CounselTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    optionsList
                    if isBusy { progressLine }
                    footnotes
                    Text(verbatim: ModelSetupPresentation.deferConsequenceLine(language: currentLanguage))
                        .font(CounselTheme.Typography.supporting)
                        .foregroundStyle(CounselTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
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
            FullRowDisclosure {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(selectableLevels, id: \.rawValue) { level in
                        if let tier = catalog.tier(for: level) {
                            VStack(alignment: .leading, spacing: 4) {
                                L10n.text(level.displayName).font(CounselTheme.Typography.supporting.weight(.medium))
                                Text(verbatim: ModelAnnotation.localizedFacts(
                                    for: tier, bundled: false, language: currentLanguage
                                ))
                                Text(verbatim: MemoryGate.localizedRequirementText(
                                    for: tier, installedGB: installedGB, language: currentLanguage
                                ))
                                Text(verbatim: ModelAnnotation.localizedBody(
                                    for: level, language: currentLanguage
                                ))
                            }
                        }
                    }
                }
                .font(CounselTheme.Typography.supporting)
                .foregroundStyle(CounselTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            } label: {
                L10n.text("Memory and test results")
                    .font(CounselTheme.Typography.supporting)
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
                            .font(CounselTheme.Typography.readingBody.weight(.medium))
                            .foregroundStyle(CounselTheme.textPrimary)
                        if isRecommended {
                            Text(verbatim: ModelSetupPresentation.recommendedBadge(language: currentLanguage))
                                .font(CounselTheme.Typography.metadata.weight(.medium))
                                .foregroundStyle(CounselTheme.inkAccent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3)
                                        .stroke(CounselTheme.inkAccent.opacity(0.4), lineWidth: 1)
                                )
                        }
                    }
                    Text(verbatim: ModelAnnotation.summary(for: level, language: currentLanguage))
                        .font(CounselTheme.Typography.supporting)
                        .foregroundStyle(CounselTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let tier {
                        Text(verbatim: ModelAnnotation.storage(
                            for: tier, language: currentLanguage
                        ))
                            .font(CounselTheme.Typography.supporting)
                            .foregroundStyle(CounselTheme.textSecondary)
                        if MemoryGate.availability(for: tier, installedGB: installedGB) == .tight {
                            Text(verbatim: MemoryGate.localizedRequirementText(
                                for: tier, installedGB: installedGB, language: currentLanguage
                            ))
                                .font(CounselTheme.Typography.supporting)
                                .foregroundStyle(CounselTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
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

    /// The model action owns Return. Deferring remains a separate explicit
    /// answer, with its consequences in the scrollable content above.
    @ViewBuilder
    private var askActions: some View {
        HStack(spacing: 12) {
            L10n.button("Not Now") { decline() }
                .buttonStyle(.bordered)
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
                continueButton
            }

        }
    }

    /// The 8 GB and 12 GB Mac: the exact memory gap, then one Continue. There
    /// is no button to add a model here, because adding a file by hand would
    /// not make the model runnable.
    @ViewBuilder
    private var unavailableActions: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                    .font(CounselTheme.Typography.supporting)
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
            case .verifying:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    L10n.text("Checking the file is exactly what it should be")
                        .font(CounselTheme.Typography.supporting)
                        .foregroundStyle(CounselTheme.textSecondary)
                }
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
            case .installed:
                Text(verbatim: ModelSetupPresentation.modelInstalledLine(language: currentLanguage))
                    .font(CounselTheme.Typography.supporting)
                    .foregroundStyle(CounselTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
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
        OnboardingWorkflowContent(hasModel: hasModel, language: currentLanguage)
    }

    private var integrationPage: some View {
        OnboardingConnectionContent()
    }

    private var navigationFooter: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let chip = OnboardingPresentation.stepChip(
                position: OnboardingPresentation.position(of: page, mode: mode, hasModel: hasModel),
                count: OnboardingPresentation.pageCount(mode: mode, hasModel: hasModel),
                language: currentLanguage
            ) {
                Text(verbatim: chip)
                    .font(CounselTheme.Typography.metadata)
                    .foregroundStyle(CounselTheme.textSecondary)
            }
            HStack(spacing: 12) {
                if let previous = OnboardingPresentation.previousPage(before: page, mode: mode, hasModel: hasModel) {
                    L10n.button("Back") { page = previous }
                }
                if !hasModel, page == .steps, canRunAModel {
                    L10n.button("Set Up a Model\u{2026}") { openModelManagement() }
                }
                Spacer(minLength: 8)
                if page == .model {
                    if route == .unavailable { unavailableActions }
                    else { askActions }
                } else if page == .integrations {
                    L10n.button("Get Started") { isPresented = false }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .tint(CounselTheme.inkAccentFill)
                } else if page != .model {
                    L10n.button("Continue") { advance() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .tint(CounselTheme.inkAccentFill)
                }
            }
            .font(CounselTheme.Typography.supporting)
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

}
