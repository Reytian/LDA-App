//
//  OnboardingView.swift
//  LDAUI
//
//  The first-run sheet (R13): what the app does (the round-trip in three
//  steps), the honest privacy promise, the model status, and plain-language
//  setup guidance. Dismissing the sheet leaves the user at the drop zone.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import SwiftUI

/// The first-run onboarding sheet.
public struct OnboardingView: View {
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

    /// Dismisses onboarding and opens Manage Models.
    ///
    /// One button into the existing sheet rather than a second download entry
    /// point here. That sheet and the app-owned installer already carry
    /// progress, cancel, resume, the memory gate, the offline-mode gate and
    /// every error string, and `AISettings.canDownload` exists because this
    /// codebase has a history of multi-entry actions where one path was gated
    /// and another was not.
    let onSetUpModel: () -> Void

    public init(
        isPresented: Binding<Bool>,
        hasModel: Bool,
        onSetUpModel: @escaping () -> Void
    ) {
        self._isPresented = isPresented
        self.hasModel = hasModel
        self.onSetUpModel = onSetUpModel
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Text("Language")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(CounselTheme.textPrimary)
                    Spacer()
                    Picker("Language", selection: languageBinding) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.nativeName).tag(language)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 210)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Use AI on confidential documents, safely")
                        .font(.system(.title2, design: .serif).weight(.semibold))
                        .foregroundStyle(CounselTheme.textPrimary)
                    Text("LDA protects client information before it reaches an AI tool, and puts it back afterwards. Three steps:")
                        .font(.callout)
                        .foregroundStyle(CounselTheme.textSecondary)
                }

            if !hasModel {
                modelSetupBlock
            }

            VStack(alignment: .leading, spacing: 14) {
                step(
                    number: "1",
                    icon: "tray.and.arrow.down",
                    title: "Bring documents in",
                    text: "Drop Word, PDF, or text files (or a .zip). The app finds names, companies, dates, amounts, emails, phones, and IDs, and you review what it will protect."
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
                    Spacer()
                    Button("Get Started") {
                        isPresented = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(CounselTheme.inkAccentFill)
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
    }

    /// The first-run model step, shown only when this Mac has no model.
    ///
    /// Placed before the three round-trip steps because it is a prerequisite,
    /// and tinted with the accent rather than danger red: at first run this is
    /// a setup task, not an error. Danger red is reserved for the pre-scan
    /// advisory in AppShell, where the user is about to act on a reduced scan.
    private var modelSetupBlock: some View {
        Label {
            VStack(alignment: .leading, spacing: 8) {
                Text("First, add a detection model")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(CounselTheme.textPrimary)
                Text("LDA needs a detection model on this Mac to find names, companies, and addresses. Until you add one, a scan finds only what patterns can match: emails, phones, dates, amounts, ID numbers, and case numbers. Names, companies, and addresses are not detected and stay in the document.")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Set Up a Model\u{2026}") { onSetUpModel() }
                    .buttonStyle(.borderedProminent)
                    .tint(CounselTheme.inkAccentFill)
                // Both routes are named so the offline one is discoverable at
                // first run. Online is stated first and marked as quicker,
                // which is how "preferred" is expressed here rather than by
                // hiding the alternative.
                VStack(alignment: .leading, spacing: 3) {
                    Text("Online, and quickest: download the model from Manage Models. About 2.74 GB.")
                    Text("No connection: download the model on another Mac, bring it over on a drive, and add the file in Manage Models. LDA checks it before installing it.")
                }
                .font(CounselTheme.Typography.supporting)
                .foregroundStyle(CounselTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(CounselTheme.inkAccent)
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
