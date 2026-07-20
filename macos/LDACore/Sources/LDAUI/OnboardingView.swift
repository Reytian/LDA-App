//
//  OnboardingView.swift
//  LDAUI
//
//  The first-run sheet (R13): what the app does (the round-trip in three
//  steps), the honest privacy promise, the model status, and plain-language
//  guidance past the unsigned-build Gatekeeper warning (R17). Zero technical
//  setup: dismissing the sheet leaves the user at the drop zone.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import SwiftUI

/// The first-run onboarding sheet.
public struct OnboardingView: View {
    @Binding var isPresented: Bool

    /// Whether the on-device AI model is available (bundled or configured).
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

            Label {
                Text("Everything runs on this Mac. The app has no network access at all: "
                    + "documents, placeholders, and the encrypted mapping never leave your computer.")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock.laptopcomputer")
                    .foregroundStyle(CounselTheme.inkAccent)
            }

            if !modelAvailable {
                Label {
                    Text("The on-device AI model was not found, so detection is pattern-only "
                        + "for now (emails, phones, dates, amounts, IDs). You can pick a local "
                        + "model later in Settings.")
                        .font(.callout)
                        .foregroundStyle(CounselTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(CounselTheme.danger)
                }
            }

            Label {
                Text("If macOS warned you the first time you opened the app (it is not yet "
                    + "notarized), close the warning, right-click LDA in Finder, choose Open, "
                    + "then Open again. macOS remembers your choice afterwards.")
                    .font(.caption)
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
