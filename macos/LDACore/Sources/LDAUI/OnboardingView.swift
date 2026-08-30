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
                VStack(alignment: .leading, spacing: 6) {
                    Text("Use AI on confidential documents, safely")
                        .font(.system(.title2, design: .serif).weight(.semibold))
                        .foregroundStyle(CounselTheme.textPrimary)
                    Text("LDA protects client information before it reaches an AI tool, "
                        + "and puts it back afterwards. Three steps:")
                        .font(.callout)
                        .foregroundStyle(CounselTheme.textSecondary)
                }

            VStack(alignment: .leading, spacing: 14) {
                step(
                    number: "1",
                    icon: "tray.and.arrow.down",
                    title: "Bring documents in",
                    text: "Drop Word, PDF, or text files (or a .zip). The app finds names, "
                        + "companies, dates, amounts, emails, phones, and IDs, and you review "
                        + "what it will protect."
                )
                step(
                    number: "2",
                    icon: "arrow.right.doc.on.clipboard",
                    title: "Hand the safe copy to any AI",
                    text: "Copy for AI puts a redacted copy on the clipboard. Paste it into "
                        + "ChatGPT, Claude, or any tool, with your instructions."
                )
                step(
                    number: "3",
                    icon: "arrow.left.doc.on.clipboard",
                    title: "Bring the answer back",
                    text: "The Restore tab puts the real values back in the AI's answer, "
                        + "and flags anything it cannot match with certainty. Save the final "
                        + "document in its original format."
                )
            }

            Divider()

            // The promise. Kept alone under the lock mark: this is the app's
            // reassurance signal (the same icon and accent as the On-device
            // status indicator), and filing a caution beneath it would dress a
            // caveat up as part of the guarantee.
            Label {
                Text("Your documents never leave this Mac. Detection, redaction, and the "
                    + "encrypted mapping all run here, and nothing about a document is ever "
                    + "sent anywhere. LDA uses the network for one thing only: downloading "
                    + "a detection model when you ask it to.")
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
                Text("Anything you choose to keep visible stays visible in the exported "
                    + "document.\n"
                    + "Restore Clipboard, in the menu-bar icon, is the one action that puts "
                    + "real values on your clipboard; it tries to clear them again about "
                    + "\(Int(SensitiveClipboard.autoClearAfter)) seconds later, so paste "
                    + "promptly and do not rely on the clearing.")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "hand.raised")
                    .foregroundStyle(CounselTheme.textSecondary)
            }

            if !modelAvailable {
                Label {
                    Text("No AI model is installed yet, so detection is pattern-only for now: "
                        + "emails, phones, dates, amounts, and ID numbers. Names, companies, "
                        + "and addresses are NOT detected until you add one. "
                        + "Open Settings, then AI, to choose and install a model.")
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

    private func step(number: String, icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(CounselTheme.inkAccent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(number). \(title)")
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
