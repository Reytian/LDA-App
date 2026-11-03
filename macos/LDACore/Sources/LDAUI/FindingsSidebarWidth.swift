import AppKit
import SwiftUI

/// Enforce readable native sidebar bounds after macOS restores a saved split position.
struct FindingsSidebarWidth: NSViewRepresentable {
    func makeNSView(context: Context) -> FindingsSidebarWidthView { FindingsSidebarWidthView() }
    func updateNSView(_ view: FindingsSidebarWidthView, context: Context) { view.scheduleUpdate() }
}

final class FindingsSidebarWidthView: NSView {
    private var updatePending = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleUpdate()
    }

    override func layout() {
        super.layout()
        scheduleUpdate()
    }

    func scheduleUpdate() {
        guard !updatePending else { return }
        updatePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updatePending = false
            var ancestor = self.superview
            while let view = ancestor {
                if let split = view as? NSSplitView,
                   let controller = split.delegate as? NSSplitViewController,
                   let item = controller.splitViewItems.first,
                   self.isDescendant(of: item.viewController.view) {
                    Self.apply(to: controller, sidebar: item)
                    return
                }
                ancestor = view.superview
            }
        }
    }

    static func apply(to controller: NSSplitViewController, sidebar: NSSplitViewItem) {
        if sidebar.minimumThickness != 260 { sidebar.minimumThickness = 260 }
        if sidebar.maximumThickness != 420 { sidebar.maximumThickness = 420 }
        guard !sidebar.isCollapsed, sidebar.viewController.view.frame.width < 260 else { return }
        controller.splitView.setPosition(320, ofDividerAt: 0)
    }
}
