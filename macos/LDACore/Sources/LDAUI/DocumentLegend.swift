//
//  DocumentLegend.swift
//  LDAUI
//
//  The legend in the document pane header: one chip per entity type present
//  in THIS document, in sidebar order, with the type hue dot, the localized
//  name, and the distinct-value count (the same number the sidebar header
//  shows, so there is one number per type across the UI). A chip dims when
//  every value of its type is kept visible. Clicking a chip selects every
//  group of that type in the sidebar and scrolls to it; right-clicking offers
//  the same bulk menu the sidebar header has.
//
//  The sidebar is already a legend; this one exists because the reviewer's
//  eye is on the paper and the sidebar is what a narrow window hides.
//
//  Collapse tiers: labeled chips, then dots and counts only, then one menu
//  button. LegendLayoutPolicy.tier picks the tier from the window state and
//  an estimate of the available width (pure, unit-tested); within the picked
//  tier ViewThatFits refines with the real localized label widths. A narrow
//  window (WindowLayoutPolicy.isNarrow, the flag that already hides the
//  workflow progress) forces the menu. More than six types puts the rest
//  behind a "+N" chip that opens the same menu.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import AppKit
import SwiftUI
import LDACore

// MARK: - Model

/// One legend chip.
struct LegendItem: Equatable, Identifiable {
    let type: EntityType
    /// Distinct values of the type (the sidebar header count).
    let valueCount: Int
    /// Every occurrence of every value of the type.
    let occurrenceCount: Int
    /// True when no value of the type will be redacted.
    let isAllKeptVisible: Bool

    var id: EntityType { type }
}

// MARK: - Policy

enum LegendLayoutPolicy {

    enum Tier: Equatable {
        /// No entities: the header keeps its caption.
        case hidden
        /// Dot, name, and count per chip.
        case labeled
        /// Dot and count per chip; the name lives in the tooltip.
        case compact
        /// One menu button listing every type.
        case menu
    }

    /// How many chips stay inline before the "+N" chip takes over.
    static let maxInlineChips = 6
    /// Width estimates for the coarse tier choice; ViewThatFits refines.
    static let labeledChipWidthEstimate: CGFloat = 104
    static let compactChipWidthEstimate: CGFloat = 44
    static let overflowChipWidthEstimate: CGFloat = 44
    static let chipSpacing: CGFloat = 6

    /// The tier for a window state, a type count, and the room available on
    /// the trailing side of the header.
    static func tier(isNarrow: Bool, typeCount: Int, availableWidth: CGFloat) -> Tier {
        guard typeCount > 0 else { return .hidden }
        guard !isNarrow else { return .menu }
        if estimatedWidth(typeCount: typeCount, chipWidth: labeledChipWidthEstimate) <= availableWidth {
            return .labeled
        }
        if estimatedWidth(typeCount: typeCount, chipWidth: compactChipWidthEstimate) <= availableWidth {
            return .compact
        }
        return .menu
    }

    private static func estimatedWidth(typeCount: Int, chipWidth: CGFloat) -> CGFloat {
        let inline = min(typeCount, maxInlineChips)
        let overflow = typeCount > maxInlineChips ? 1 : 0
        let gaps = max(inline + overflow - 1, 0)
        return CGFloat(inline) * chipWidth
            + CGFloat(overflow) * overflowChipWidthEstimate
            + CGFloat(gaps) * chipSpacing
    }

    /// The chips for a document, in sidebar order, present types only.
    static func items(groups: [ReviewGroup]) -> [LegendItem] {
        ReviewModel.groupTypeOrder.compactMap { type in
            let ofType = groups.filter { $0.type == type }
            guard !ofType.isEmpty else { return nil }
            return LegendItem(
                type: type,
                valueCount: ofType.count,
                occurrenceCount: ofType.reduce(0) { $0 + $1.occurrences },
                isAllKeptVisible: ofType.allSatisfy { !$0.anyAccepted }
            )
        }
    }

    /// The chips shown inline and the ones that go behind the "+N" chip.
    static func inlineSplit(_ items: [LegendItem]) -> (shown: [LegendItem], overflow: [LegendItem]) {
        guard items.count > maxInlineChips else { return (items, []) }
        return (Array(items.prefix(maxInlineChips)), Array(items.dropFirst(maxInlineChips)))
    }

    /// Select every group of a type in the sidebar and reveal the first.
    @MainActor
    static func select(type: EntityType, in model: ReviewModel) {
        let groups = model.groups(of: type)
        guard let first = groups.first else { return }
        model.selectedGroupIDs = Set(groups.map(\.id))
        model.groupToReveal = first.id
    }
}

// MARK: - Strings

enum LegendPresentation {
    static func tooltip(for item: LegendItem) -> String {
        String(
            format: L10n.string("%lld values \u{00B7} %lld occurrences in this document"),
            Int64(item.valueCount),
            Int64(item.occurrenceCount)
        )
    }

    static func accessibilityLabel(for item: LegendItem) -> String {
        let base = String(
            format: L10n.string("%@, %lld values, %lld occurrences"),
            EntityTypePresentation.localizedName(for: item.type) as NSString,
            Int64(item.valueCount),
            Int64(item.occurrenceCount)
        )
        guard item.isAllKeptVisible else { return base }
        return base + L10n.string(", all kept visible")
    }

    static func accessibilityHint(for item: LegendItem) -> String {
        String(
            format: L10n.string("Selects every %@ value in the sidebar."),
            EntityTypePresentation.localizedName(for: item.type) as NSString
        )
    }

    static func menuButtonLabel(typeCount: Int) -> String {
        typeCount == 1
            ? L10n.string("1 type")
            : String(format: L10n.string("%lld types"), Int64(typeCount))
    }

    static func menuButtonAccessibilityLabel(typeCount: Int) -> String {
        String(format: L10n.string("Legend, %lld types"), Int64(typeCount))
    }

    /// A menu row: the type name and its distinct-value count.
    static func menuItemTitle(for item: LegendItem) -> String {
        String(
            format: L10n.string("%@  \u{00B7}  %@"),
            EntityTypePresentation.localizedName(for: item.type) as NSString,
            String(item.valueCount) as NSString
        )
    }
}

// MARK: - View

struct DocumentLegend: View {
    @ObservedObject var model: ReviewModel
    let isNarrow: Bool
    let availableWidth: CGFloat

    var body: some View {
        let items = LegendLayoutPolicy.items(groups: model.entityGroups)
        switch LegendLayoutPolicy.tier(isNarrow: isNarrow, typeCount: items.count, availableWidth: availableWidth) {
        case .hidden:
            EmptyView()
        case .menu:
            menuButton(items)
        case .labeled:
            ViewThatFits(in: .horizontal) {
                inlineChips(items, labeled: true)
                inlineChips(items, labeled: false)
                menuButton(items)
            }
        case .compact:
            ViewThatFits(in: .horizontal) {
                inlineChips(items, labeled: false)
                menuButton(items)
            }
        }
    }

    private func inlineChips(_ items: [LegendItem], labeled: Bool) -> some View {
        let split = LegendLayoutPolicy.inlineSplit(items)
        return HStack(spacing: LegendLayoutPolicy.chipSpacing) {
            ForEach(split.shown) { item in
                chip(item, labeled: labeled)
            }
            if !split.overflow.isEmpty {
                overflowMenu(split.overflow)
            }
        }
    }

    private func chip(_ item: LegendItem, labeled: Bool) -> some View {
        Button {
            LegendLayoutPolicy.select(type: item.type, in: model)
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(CounselTheme.color(for: item.type))
                    .frame(width: 8, height: 8)
                if labeled {
                    L10n.text(EntityTypePresentation.key(for: item.type))
                        .font(.caption)
                        .foregroundStyle(CounselTheme.textPrimary)
                        .lineLimit(1)
                }
                Text(verbatim: String(item.valueCount))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(CounselTheme.textSecondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: CounselTheme.Radius.sm, style: .continuous)
                    .fill(CounselTheme.raised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CounselTheme.Radius.sm, style: .continuous)
                    .strokeBorder(CounselTheme.hairline, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(item.isAllKeptVisible ? 0.55 : 1.0)
        .help(Text(verbatim: LegendPresentation.tooltip(for: item)))
        .contextMenu {
            EntityTypeBulkActions(type: item.type) { accepted in
                model.setAccepted(type: item.type, accepted)
            }
        }
        .accessibilityLabel(Text(verbatim: LegendPresentation.accessibilityLabel(for: item)))
        .accessibilityHint(Text(verbatim: LegendPresentation.accessibilityHint(for: item)))
    }

    private func overflowMenu(_ items: [LegendItem]) -> some View {
        Menu {
            legendMenuItems(items)
        } label: {
            Text(verbatim: "+" + String(items.count))
                .font(.caption.monospacedDigit())
                .foregroundStyle(CounselTheme.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text(verbatim: LegendPresentation.menuButtonLabel(typeCount: items.count)))
    }

    private func menuButton(_ items: [LegendItem]) -> some View {
        Menu {
            legendMenuItems(items)
        } label: {
            Label {
                Text(verbatim: LegendPresentation.menuButtonLabel(typeCount: items.count))
            } icon: {
                Image(systemName: "circle.grid.2x2")
            }
            .font(.caption)
            .foregroundStyle(CounselTheme.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(Text(verbatim: LegendPresentation.menuButtonAccessibilityLabel(typeCount: items.count)))
    }

    @ViewBuilder
    private func legendMenuItems(_ items: [LegendItem]) -> some View {
        ForEach(items) { item in
            Button {
                LegendLayoutPolicy.select(type: item.type, in: model)
            } label: {
                Label {
                    Text(verbatim: LegendPresentation.menuItemTitle(for: item))
                } icon: {
                    Image(nsImage: EntityTypePresentation.dotImage(for: item.type))
                }
            }
        }
    }
}

// MARK: - Window narrowness

/// Reports whether the hosting window is narrow (WindowLayoutPolicy), so the
/// legend can collapse with the rest of the chrome. Zero-size; place it in a
/// background.
struct WindowNarrownessReader: NSViewRepresentable {
    @Binding var isNarrow: Bool

    func makeNSView(context: Context) -> WindowWidthObservingView {
        let view = WindowWidthObservingView()
        view.onChange = update
        return view
    }

    func updateNSView(_ nsView: WindowWidthObservingView, context: Context) {
        nsView.onChange = update
        nsView.report()
    }

    private func update(_ narrow: Bool) {
        guard isNarrow != narrow else { return }
        DispatchQueue.main.async {
            isNarrow = narrow
        }
    }
}

final class WindowWidthObservingView: NSView {
    var onChange: ((Bool) -> Void)?
    private var resizeObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
        }
        resizeObserver = nil
        guard let window else { return }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.report()
        }
        report()
    }

    deinit {
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
        }
    }

    func report() {
        guard let window else { return }
        onChange?(WindowLayoutPolicy.isNarrow(windowWidth: window.frame.width))
    }
}
