import AppKit
import AVKit
import SwiftUI

/// Bundled, offline tutorials shared by onboarding and integration setup.
struct TutorialGallery: View {
    @Environment(\.appLanguage) private var language
    @State private var selected: LDATutorial?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            L10n.text("Watch the walkthroughs")
                .font(CounselTheme.Typography.heading)
            // Only an explicit click opens this fixed page in the user's browser.
            Link(destination: URL(string: "https://github.com/Reytian/LDA-App/releases/tag/tutorials-20261103")!) {
                Label {
                    L10n.text("Watch on GitHub")
                } icon: {
                    Image(systemName: "arrow.up.right.square")
                }
            }
            .accessibilityHint(L10n.string("Open both video walkthroughs in your browser", language: language))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .top)], spacing: 12) {
                ForEach(LDATutorial.allCases) { tutorial in
                    Button { selected = tutorial } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            ZStack {
                                if let url = tutorial.resource("png"), let image = NSImage(contentsOf: url) {
                                    Image(nsImage: image)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .accessibilityHidden(true)
                                } else {
                                    Rectangle().fill(Color.secondary.opacity(0.12))
                                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                                }
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 38))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, CounselTheme.inkAccentFill)
                                    .accessibilityHidden(true)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            L10n.text(tutorial.title).font(CounselTheme.Typography.supporting.weight(.semibold))
                            L10n.text(tutorial.summary)
                                .font(CounselTheme.Typography.metadata)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.string(tutorial.title, language: language))
                    .accessibilityHint(L10n.string("Open the offline video player", language: language))
                }
            }
        }
        .sheet(item: $selected) { TutorialPlayer(tutorial: $0) }
    }
}

private enum LDATutorial: String, CaseIterable, Identifiable {
    case app = "lda-app-walkthrough"
    case codex = "lda-codex-walkthrough"
    var id: String { rawValue }
    var title: String { self == .app ? "Use the LDA app" : "Connect LDA through MCP" }
    var summary: String {
        self == .app ? "Scan, review, export and restore."
            : "Connect your AI workstation through MCP, with Codex as the example."
    }
    func resource(_ extensionName: String) -> URL? {
        LDAResourceBundle.resolve()?.url(forResource: rawValue, withExtension: extensionName)
    }
}

private struct TutorialPlayer: View {
    @Environment(\.appLanguage) private var language
    let tutorial: LDATutorial
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var transcript: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                L10n.text(tutorial.title).font(CounselTheme.Typography.sectionTitle.weight(.semibold))
                Spacer()
                L10n.button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let player {
                TutorialVideoView(player: player)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .accessibilityLabel(L10n.string(tutorial.title, language: language))
            } else {
                L10n.text("This tutorial is missing from the app. Reinstall a complete LDA release.")
                    .frame(maxWidth: .infinity, minHeight: 240)
            }
            if let transcript {
                FullRowDisclosure {
                    ScrollView {
                        Text(verbatim: transcript)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                    .frame(maxHeight: 180)
                } label: { L10n.text("Read the transcript") }
            }
        }
        .disclosureGroupStyle(FullRowDisclosureStyle())
        .padding(24)
        .frame(minWidth: 640, idealWidth: 960, minHeight: 480)
        .onAppear {
            // File URLs only. Opening the sheet never starts playback automatically.
            if let url = tutorial.resource("mp4"), url.isFileURL {
                player = AVPlayer(url: url)
            }
            if let url = tutorial.resource("txt"),
               let data = FileManager.default.contents(atPath: url.path) {
                transcript = String(data: data, encoding: .utf8)
            }
        }
        .onDisappear {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
        }
    }
}

/// AVKit's own player view, wrapped here rather than through SwiftUI's
/// VideoPlayer. VideoPlayer comes from the _AVKit_SwiftUI overlay, which on
/// macOS 27 no longer loads AVKit, and a binary that names no AVKit symbol
/// does not link it: opening a walkthrough aborted the app. Naming
/// AVPlayerView keeps AVKit linked; package-app.sh refuses a binary without it.
private struct TutorialVideoView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player = nil
    }
}
