//
//  DocumentTextView.swift
//  LDAUI
//
//  The AppKit text surface under the document pane. SwiftUI's Text can show a
//  selection but cannot report its range, and "select a word, then protect it"
//  needs the range, so the reading column is a non-editable, selectable
//  NSTextView inside its own NSScrollView (never nested in a SwiftUI
//  ScrollView). It reproduces the pane's reading column: the serif body,
//  the capped measure centered with a minimum gutter, and the extra leading,
//  all through DocumentTextStyler's attributes and the text container inset.
//
//  Responsibilities:
//  - Report the selection (UTF-16, identical to Span offsets) through
//    onSelectionChange, but never for programmatic content updates.
//  - Prepend the Protect items to the standard text context menu: the
//    guessed kind first, a submenu in sidebar order, then a separator. In
//    Safe Preview a single item flips the picker back to Original.
//  - Present the kind chooser as an NSPopover anchored to the selection when
//    the Review menu command (Cmd+Shift+P) fires.
//  - Keep spelling, grammar, data detection, and link detection off so no
//    system underline ever competes with the dashed kept-visible underline.
//  - TextKit 1 on purpose: tooltips and dashed underlines render reliably.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import AppKit
import SwiftUI
import LDACore

// MARK: - Layout

/// The reading column geometry, shared with the tests.
enum DocumentTextLayout {
    /// The capped reading measure for the serif body column.
    static let columnWidth: CGFloat = 680
    /// Minimum horizontal gutter on each side of the column.
    static let gutter: CGFloat = 48
    /// Vertical inset above and below the column body.
    static let columnVerticalInset: CGFloat = 56
}

// MARK: - Context menu

/// What the text view needs from its host to build the Protect items.
struct DocumentTextMenuContext {
    /// False in Safe Preview, which adds the way back to Original under
    /// whatever it can say about the selection.
    let isOriginalVisible: Bool
    /// The state gate (a document is loaded, no scan is running).
    let canProtect: Bool
    /// The kinds of the submenu, in sidebar order.
    let assignableTypes: [EntityType]
    /// The kind to lead with for a trimmed value.
    let guess: (String) -> EntityType
    /// What the given selection range can be protected as. The range is read
    /// at menu time from the text view, because a right-click selects the
    /// word under the pointer before the menu is built, and it is resolved by
    /// the model so Safe Preview goes through the pairing (see
    /// SafePreviewSelection.swift).
    let resolve: (NSRange?) -> ProtectableSelection
    /// Protect the current selection as the chosen kind.
    let onProtect: (EntityType) -> Void
    /// Flip the pane back to Original.
    let onShowOriginal: () -> Void
}

/// Pure builder for the Protect section of the text context menu.
enum DocumentTextContextMenu {

    /// The items to insert at the top of the standard menu, ending with a
    /// separator.
    ///
    /// A selection that cannot be protected is not merely grayed: a stand-in
    /// and an unpairable preview each carry their own sentence, followed by
    /// the way back to Original, so the answer is never silence.
    static func protectItems(
        _ selection: ProtectableSelection,
        context: DocumentTextMenuContext
    ) -> [NSMenuItem] {
        guard context.canProtect else {
            return [disabledItem(L10n.string("Protect Selection\u{2026}")), .separator()]
        }

        let value: String
        switch selection {
        case .value(let selected):
            value = selected
        case .nothing:
            var items = [disabledItem(L10n.string("Protect Selection\u{2026}"))]
            if !context.isOriginalVisible {
                items.append(showOriginalItem(context))
            }
            items.append(.separator())
            return items
        case .standIn(let shown):
            let quoted = ProtectableSelection.standIn(ProtectSelectionPresentation.menuValue(shown))
            return [
                disabledItem(ProtectSelectionPresentation.refusal(for: quoted) ?? ""),
                showOriginalItem(context),
                .separator()
            ]
        case .undecidable:
            return [
                disabledItem(ProtectSelectionPresentation.refusal(for: selection) ?? ""),
                showOriginalItem(context),
                .separator()
            ]
        }

        let shown = ProtectSelectionPresentation.menuValue(value)
        let guessed = context.guess(value)
        let primary = ClosureMenuItem(
            title: String(
                format: L10n.string("Protect “%@” as %@"),
                shown as NSString,
                EntityTypePresentation.localizedName(for: guessed) as NSString
            ),
            action: { context.onProtect(guessed) }
        )

        let submenuItem = NSMenuItem(
            title: String(format: L10n.string("Protect “%@” as\u{2026}"), shown as NSString),
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu(title: submenuItem.title)
        for type in context.assignableTypes {
            submenu.addItem(ClosureMenuItem(
                title: String(
                    format: L10n.string("Protect as %@"),
                    EntityTypePresentation.localizedName(for: type) as NSString
                ),
                action: { context.onProtect(type) }
            ))
        }
        submenuItem.submenu = submenu

        var items: [NSMenuItem] = [primary, submenuItem]
        if !context.isOriginalVisible {
            items.append(showOriginalItem(context))
        }
        items.append(.separator())
        return items
    }

    /// Run an item's action the way a click would (used by tests).
    static func perform(_ item: NSMenuItem) {
        (item as? ClosureMenuItem)?.fire()
    }

    /// A grayed item that only states something.
    private static func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// The way back to the surface where every selection is the document's
    /// own text. Offered in every Safe Preview menu.
    private static func showOriginalItem(_ context: DocumentTextMenuContext) -> NSMenuItem {
        ClosureMenuItem(
            title: L10n.string("Show Original to Select Text"),
            action: context.onShowOriginal
        )
    }
}

/// A menu item that runs a closure. It is its own target, so the menu that
/// holds it keeps the closure alive.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("ClosureMenuItem is never archived")
    }

    @objc func fire() {
        handler()
    }
}

// MARK: - Text view

/// The selectable, non-editable document text view.
final class ProtectableTextView: NSTextView {

    /// Called with the selection after a user change; nil for an empty one.
    var onSelectionChange: ((NSRange?) -> Void)?
    /// Called when the user presses Escape in the text.
    var onCancel: (() -> Void)?
    /// The host's context for the Protect menu items.
    var menuContext: DocumentTextMenuContext?

    /// True while content or selectability is being set programmatically, so
    /// those changes are never reported as user selections.
    private var isApplyingContent = false

    /// A configured TextKit 1 text view (storage, layout manager, container).
    static func make() -> ProtectableTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        let view = ProtectableTextView(frame: .zero, textContainer: container)
        view.configure()
        return view
    }

    private func configure() {
        isEditable = false
        isSelectable = true
        isRichText = true
        usesFontPanel = false
        usesRuler = false
        allowsUndo = false
        drawsBackground = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainerInset = NSSize(
            width: DocumentTextLayout.gutter,
            height: DocumentTextLayout.columnVerticalInset
        )
    }

    /// Replace the content. When only attributes changed (same text) the
    /// user's selection survives, so a follow-up right-click still works.
    func apply(content: NSAttributedString) {
        guard let storage = textStorage else { return }
        let preserved = storage.string == content.string ? selectedRange() : nil
        isApplyingContent = true
        defer { isApplyingContent = false }
        storage.setAttributedString(content)
        if let preserved, NSMaxRange(preserved) <= content.length {
            setSelectedRange(preserved)
        } else {
            setSelectedRange(NSRange(location: 0, length: 0))
        }
    }

    /// Turn selection on or off. Turning it off clears the selection without
    /// reporting; the pane clears its model when Safe Preview shows.
    func setSelectable(_ selectable: Bool) {
        guard isSelectable != selectable else { return }
        isApplyingContent = true
        defer { isApplyingContent = false }
        if !selectable {
            setSelectedRange(NSRange(location: 0, length: 0))
        }
        isSelectable = selectable
    }

    override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting stillSelectingFlag: Bool
    ) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
        guard !isApplyingContent, !stillSelectingFlag else { return }
        let range = selectedRange()
        onSelectionChange?(range.length > 0 ? range : nil)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateColumnInset(for: newSize.width)
    }

    /// Center the capped measure, never narrower than the minimum gutter.
    private func updateColumnInset(for width: CGFloat) {
        let centered = ((width - DocumentTextLayout.columnWidth) / 2).rounded(.down)
        let inset = NSSize(
            width: max(DocumentTextLayout.gutter, centered),
            height: DocumentTextLayout.columnVerticalInset
        )
        guard textContainerInset != inset else { return }
        textContainerInset = inset
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // The standard text menu is shared between text views; work on a copy
        // so the Protect items never accumulate.
        let menu = (super.menu(for: event)?.copy() as? NSMenu) ?? NSMenu()
        guard let context = menuContext else { return menu }
        // super.menu(for:) is what selects the word under the pointer, so the
        // range is read after it and taken from the view itself, never from a
        // report that may not have landed yet.
        let selected = selectedRange()
        let items = DocumentTextContextMenu.protectItems(
            context.resolve(selected.length > 0 ? selected : nil),
            context: context
        )
        for (offset, item) in items.enumerated() {
            menu.insertItem(item, at: offset)
        }
        return menu
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

// MARK: - Representable

/// The SwiftUI wrapper. It owns the scroll view; the pane composes the header
/// above it and never wraps it in another ScrollView.
struct DocumentTextView: NSViewRepresentable {
    let content: NSAttributedString
    let isSelectable: Bool
    let menuContext: DocumentTextMenuContext
    /// Bumped by the Review menu command; a change opens the kind chooser.
    let chooserRequestToken: Int
    /// Builds the chooser for the current selection; the argument closes it.
    let makeChooser: (@escaping () -> Void) -> AnyView
    let onSelectionChange: (NSRange?) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(lastChooserToken: chooserRequestToken)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ProtectableTextView.make()
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        context.coordinator.textView = textView
        apply(to: textView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        apply(to: textView, coordinator: context.coordinator)
        guard chooserRequestToken != context.coordinator.lastChooserToken else { return }
        context.coordinator.lastChooserToken = chooserRequestToken
        // Presenting during SwiftUI's update pass would re-enter it; defer.
        let builder = makeChooser
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            coordinator.presentChooser(builder)
        }
    }

    private func apply(to textView: ProtectableTextView, coordinator: Coordinator) {
        textView.menuContext = menuContext
        textView.onSelectionChange = onSelectionChange
        textView.onCancel = onCancel
        if coordinator.appliedContent !== content {
            coordinator.appliedContent = content
            textView.apply(content: content)
        }
        textView.setSelectable(isSelectable)
    }

    final class Coordinator {
        weak var textView: ProtectableTextView?
        var appliedContent: NSAttributedString?
        var lastChooserToken: Int
        private var popover: NSPopover?

        init(lastChooserToken: Int) {
            self.lastChooserToken = lastChooserToken
        }

        /// Show the kind chooser anchored to the first line of the selection.
        func presentChooser(_ makeChooser: (@escaping () -> Void) -> AnyView) {
            guard let textView, let window = textView.window else { return }
            let selected = textView.selectedRange()
            guard selected.length > 0 else { return }
            popover?.close()

            let popover = NSPopover()
            popover.behavior = .transient
            let dismiss: () -> Void = { [weak popover] in popover?.close() }
            popover.contentViewController = NSHostingController(rootView: makeChooser(dismiss))

            let screenRect = textView.firstRect(forCharacterRange: selected, actualRange: nil)
            var anchor = textView.convert(window.convertFromScreen(screenRect), from: nil)
            if anchor.isEmpty {
                anchor = NSRect(x: 0, y: 0, width: 1, height: 1)
            }
            popover.show(relativeTo: anchor, of: textView, preferredEdge: .maxY)
            self.popover = popover
        }
    }
}
