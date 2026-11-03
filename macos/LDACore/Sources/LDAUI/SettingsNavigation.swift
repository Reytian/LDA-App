import AppKit
import SwiftUI

/// Settings are grouped by the job the user came to do. Technical setup
/// remains available without occupying the everyday toolbar.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case detection = "AI"
    case vocabulary = "Vocabulary"
    case learned = "Learned"
    case history = "History"
    case tutorials = "Tutorials"
    case sharing = "Sharing"
    case assistants = "MCP Setup"
    case commandLine = "CLI Setup"
    case legal = "Legal"

    var id: Self { self }
    var isAdvanced: Bool { [.sharing, .assistants, .commandLine].contains(self) }
    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .detection: return "text.magnifyingglass"
        case .vocabulary: return "text.book.closed"
        case .learned: return "checkmark.bubble"
        case .history: return "clock.arrow.circlepath"
        case .tutorials: return "play.rectangle"
        case .sharing: return "square.and.arrow.up.on.square"
        case .assistants: return "bubble.left.and.bubble.right"
        case .commandLine: return "terminal"
        case .legal: return "hand.raised"
        }
    }
}

struct SettingsNavigation<Page: View>: View {
    @State private var selection: SettingsSection? = .general
    @State private var visited: Set<SettingsSection> = [.general]
    @ViewBuilder let page: (SettingsSection) -> Page

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    ForEach(SettingsSection.allCases.filter { !$0.isAdvanced }) { section in
                        row(section)
                    }
                } header: {
                    L10n.text("Everyday settings")
                }
                Section {
                    ForEach(SettingsSection.allCases.filter(\.isAdvanced)) { section in
                        row(section)
                    }
                } header: {
                    L10n.text("Advanced tools")
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        } detail: {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    // Keep visited pages alive so switching categories does
                    // not discard a draft term, search, or setup progress.
                    ForEach(SettingsSection.allCases.filter { visited.contains($0) }) { section in
                        page(section)
                            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                            .opacity(selection == section ? 1 : 0)
                            .disabled(selection != section)
                            .allowsHitTesting(selection == section)
                            .accessibilityHidden(selection != section)
                    }
                }
                .clipped()
            }
            .background(CounselTheme.paper)
        }
        .font(CounselTheme.Typography.readingBody)
        .controlSize(.large)
        .l10nNavigationTitle("Settings")
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) { windowHeading }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) { windowHeading }
            }
        }
        .background(SettingsWindowToolbar())
        .onChange(of: selection) { _, section in
            if let section { visited.insert(section) }
        }
    }

    private var windowHeading: some View {
        L10n.text("Settings")
            .font(CounselTheme.Typography.sectionTitle)
            .foregroundStyle(CounselTheme.textPrimary)
            .fixedSize()
            .padding(.leading, CounselTheme.Space.sm)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ section: SettingsSection) -> some View {
        L10n.label(section.rawValue, systemImage: section.icon)
            .font(CounselTheme.Typography.supporting)
            .lineLimit(2)
            .padding(.vertical, 5)
            .tag(section)
    }
}

/// Settings scenes do not consistently apply the scene toolbar style on macOS.
private struct SettingsWindowToolbar: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsToolbarView { SettingsToolbarView() }
    func updateNSView(_ nsView: SettingsToolbarView, context: Context) { nsView.scheduleStyleUpdate() }
}

final class SettingsToolbarView: NSView {
    private var titleObservation: NSKeyValueObservation?
    private var styleUpdateScheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        titleObservation = window?.observe(\.titleVisibility, options: [.new]) { [weak self] _, _ in
            self?.scheduleStyleUpdate()
        }
        scheduleStyleUpdate()
    }

    func scheduleStyleUpdate() {
        guard !styleUpdateScheduled else { return }
        styleUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.styleUpdateScheduled = false
            self.applyStyle()
        }
    }

    private func applyStyle() {
        guard let window else { return }
        // The visible toolbar heading owns its readable type size; keep the
        // native title for window menus and accessibility without duplicating it.
        if window.titleVisibility != .hidden {
            window.titleVisibility = .hidden
        }
        if window.toolbarStyle != .unifiedCompact {
            window.toolbarStyle = .unifiedCompact
        }
    }
}
