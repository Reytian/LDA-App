import SwiftUI
import LDACore

/// A stable action area remains visible while translated content scrolls.
struct OnboardingPageLayout<Content: View, Footer: View>: View {
    var pageID: AnyHashable = 0
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24, content: content)
                    .frame(maxWidth: 664, alignment: .leading)
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .id(pageID)
            Divider()
            footer()
                .frame(maxWidth: 664, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 520, idealWidth: 680, minHeight: 500, idealHeight: 680)
        .background(CounselTheme.raised)
    }
}

struct OnboardingWorkflowContent: View {
    let hasModel: Bool
    let language: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: OnboardingPresentation.stepsTitle(language: language))
                    .font(CounselTheme.Typography.pageTitle)
                    .foregroundStyle(CounselTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: OnboardingPresentation.stepsLede(language: language))
                    .foregroundStyle(CounselTheme.textSecondary)
            }
            VStack(alignment: .leading, spacing: 20) {
                step(1, title: OnboardingPresentation.step1Title(language: language),
                     text: OnboardingPresentation.step1Text(hasModel: hasModel, language: language))
                step(2, title: OnboardingPresentation.step2Title(language: language),
                     text: OnboardingPresentation.step2Text(language: language))
                step(3, title: OnboardingPresentation.step3Title(language: language),
                     text: OnboardingPresentation.step3Text(language: language))
            }
            Label {
                Text(verbatim: OnboardingPresentation.visibilityCaution(language: language))
                    .font(CounselTheme.Typography.supporting)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "eye").accessibilityHidden(true)
            }
            .foregroundStyle(CounselTheme.textSecondary)
            Divider()
            FullRowDisclosure {
                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: OnboardingPresentation.privacyParagraph(language: language))
                    Text(verbatim: OnboardingPresentation.clipboardCaution(
                        autoClearSeconds: Int(SensitiveClipboard.autoClearAfter), language: language))
                }
                .font(CounselTheme.Typography.supporting)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            } label: { L10n.text("Privacy and clipboard details") }
            FullRowDisclosure {
                TutorialGallery().padding(.top, 8)
            } label: { L10n.text("Watch the walkthroughs") }
        }
        .font(CounselTheme.Typography.readingBody)
        .disclosureGroupStyle(FullRowDisclosureStyle())
    }

    private func step(_ number: Int, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(verbatim: number.formatted(.number.locale(language.locale)))
                .font(CounselTheme.Typography.heading)
                .foregroundStyle(CounselTheme.inkAccent)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: title).font(CounselTheme.Typography.heading)
                Text(verbatim: text)
                    .font(CounselTheme.Typography.supporting)
                    .foregroundStyle(CounselTheme.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct OnboardingConnectionContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            L10n.text("Connect your AI workstation through MCP")
                .font(CounselTheme.Typography.pageTitle)
                .fixedSize(horizontal: false, vertical: true)
            L10n.text("You can use LDA on its own: export a redacted copy, then upload it to the AI app you choose.")
                .foregroundStyle(CounselTheme.textSecondary)
            L10n.text("MCP lets your AI workstation ask LDA to prepare documents. You still choose the files on this Mac.")
                .foregroundStyle(CounselTheme.textSecondary)
            FullRowDisclosure {
                MCPSetupView(showsIntroduction: false).padding(.top, 12)
            } label: { L10n.text("Set up a connection") }
            Divider()
            L10n.text("You can do this later in Settings > AI Assistants. Choose Get Started to open LDA.")
                .font(CounselTheme.Typography.supporting)
                .foregroundStyle(CounselTheme.textSecondary)
        }
        .font(CounselTheme.Typography.readingBody)
        .fixedSize(horizontal: false, vertical: true)
        .disclosureGroupStyle(FullRowDisclosureStyle())
    }
}
