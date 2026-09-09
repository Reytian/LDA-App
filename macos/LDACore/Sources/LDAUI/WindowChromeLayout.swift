//
//  WindowChromeLayout.swift
//  LDAUI
//
//  Shared native titlebar and toolbar clearance for full-height SwiftUI
//  surfaces. Unified macOS windows can extend SwiftUI content behind their
//  chrome, so interactive page content must follow NSWindow's live content
//  layout boundary instead of relying on a guessed constant.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import AppKit
import SwiftUI

enum WindowChromeLayoutPolicy {
    static func topInset(windowFrameHeight: CGFloat, contentLayoutHeight: CGFloat) -> CGFloat {
        max(0, windowFrameHeight - contentLayoutHeight)
    }
}

struct WindowChromeTopSpacer: View {
    let height: CGFloat
    let background: Color

    var body: some View {
        background
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct WindowContentTopInsetReader: NSViewRepresentable {
    @Binding var topInset: CGFloat

    func makeNSView(context: Context) -> WindowContentInsetView {
        let view = WindowContentInsetView()
        view.onInsetChange = updateTopInset
        view.scheduleRefresh()
        return view
    }

    func updateNSView(_ nsView: WindowContentInsetView, context: Context) {
        nsView.onInsetChange = updateTopInset
        nsView.scheduleRefresh()
    }

    static func dismantleNSView(_ nsView: WindowContentInsetView, coordinator: ()) {
        nsView.onInsetChange = nil
    }

    func updateTopInset(_ newValue: CGFloat) {
        DispatchQueue.main.async {
            // Compare when applying the update. A toolbar can disappear and
            // return before this queue drains; comparing earlier would drop
            // the final value and leave content underneath the restored bar.
            guard abs(topInset - newValue) > 0.5 else { return }
            topInset = newValue
        }
    }
}

final class WindowContentInsetView: NSView {
    var onInsetChange: ((CGFloat) -> Void)?
    private var contentLayoutObservation: NSKeyValueObservation?
    private weak var observedWindow: NSWindow?
    private var refreshIsScheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeCurrentWindow()
        scheduleRefresh()
    }

    private func observeCurrentWindow() {
        guard observedWindow !== window else { return }
        contentLayoutObservation = nil
        observedWindow = window
        guard let window else { return }
        contentLayoutObservation = window.observe(
            \.contentLayoutRect,
            options: [.new]
        ) { [weak self] _, _ in
            self?.scheduleRefresh()
        }
    }

    override func layout() {
        super.layout()
        scheduleRefresh()
    }

    /// SwiftUI can update the representable before AppKit attaches it to the
    /// window or finishes replacing a toolbar. Measure after that layout pass.
    func scheduleRefresh() {
        guard !refreshIsScheduled else { return }
        refreshIsScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshIsScheduled = false
            self.observeCurrentWindow()
            self.reportCurrentInset()
        }
    }

    func reportCurrentInset() {
        guard let window else { return }
        let topInset = WindowChromeLayoutPolicy.topInset(
            windowFrameHeight: window.frame.height,
            contentLayoutHeight: window.contentLayoutRect.height
        )
        onInsetChange?(topInset)
    }
}
