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
        return view
    }

    func updateNSView(_ nsView: WindowContentInsetView, context: Context) {
        nsView.onInsetChange = updateTopInset
        nsView.reportCurrentInset()
    }

    static func dismantleNSView(_ nsView: WindowContentInsetView, coordinator: ()) {
        nsView.onInsetChange = nil
    }

    private func updateTopInset(_ newValue: CGFloat) {
        guard abs(topInset - newValue) > 0.5 else { return }
        DispatchQueue.main.async {
            topInset = newValue
        }
    }
}

final class WindowContentInsetView: NSView {
    var onInsetChange: ((CGFloat) -> Void)?
    private var contentLayoutObservation: NSKeyValueObservation?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        contentLayoutObservation = nil

        guard let window else { return }
        contentLayoutObservation = window.observe(
            \.contentLayoutRect,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            self?.reportCurrentInset()
        }
    }

    override func layout() {
        super.layout()
        reportCurrentInset()
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
