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

    /// Whether an on-device AI model is available. Quick ships inside the app,
    /// so this is normally true; it is false only when the bundled model is
    /// absent, which package-app.sh refuses to produce.
    let modelAvailable: Bool

    public init(isPresented: Binding<Bool>, modelAvailable: Bool) {
        self._isPresented = isPresented
        self.modelAvailable = modelAvailable
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

            VStack(alignment: .leading, spacing: 14) {
                step(
                    number: "1",
                    icon: "tray.and.arrow.down",
                    title: "Bring documents in",
                    text: "Drop Word, PDF, or text files (or a .zip). The app finds names, companies, dates, amounts, emails, phones, and IDs, and you review what it will protect."
                )
                step(
                    number: "2",
                    icon: "arrow.right.doc.on.clipboard",
                    title: "Hand the safe copy to any AI",
                    text: "Copy for AI puts a redacted copy on the clipboard. Paste it into ChatGPT, Claude, or any tool, with your instructions."
                )
                step(
                    number: "3",
                    icon: "arrow.left.doc.on.clipboard",
                    title: "Bring the answer back",
                    text: "The Restore tab puts the real values back in the AI's answer, and flags anything it cannot match with certainty. Save the final document in its original format."
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
            // the clipboard; Restore's own paste-back and file flows write a
            // file and never touch it. An unscoped version told every user that
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

            if !modelAvailable {
                Label {
                    Text("No AI model is installed yet, so detection is pattern-only for now: emails, phones, dates, amounts, and ID numbers. Names, companies, and addresses are NOT detected until you add one. Open Settings, then AI, to choose and install a model.")
                        .font(.callout)
                        .foregroundStyle(CounselTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(CounselTheme.danger)
                }
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
