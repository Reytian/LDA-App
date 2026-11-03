import AppKit
import SwiftUI
import XCTest
@testable import LDAUI

@MainActor
final class ReadableInterfaceTests: XCTestCase {
    func testReadingSizesDoNotDependOnWindowWidth() {
        XCTAssertGreaterThanOrEqual(CounselTheme.Typography.bodySize, 16)
        XCTAssertGreaterThanOrEqual(CounselTheme.Typography.supportingSize, 15)
        XCTAssertGreaterThanOrEqual(CounselTheme.Typography.metadataSize, 14)
        let text = "请检查需要隐藏的信息。Review the information before sharing."
        let original = DocumentTextStyler.styledOriginal(text: text, entities: [])
        let preview = DocumentTextStyler.styledSafePreview(text: text)
        for rendered in [original, preview] {
            let font = rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            XCTAssertGreaterThanOrEqual(font?.pointSize ?? 0, 17)
        }
    }

    func testChromeInsetDoesNotDoubleCountAnExistingSafeAreaDuringResize() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.toolbar = NSToolbar(identifier: "ReadableInterfaceTests.Toolbar")
        let content = try XCTUnwrap(window.contentView)
        let reader = WindowContentInsetView()
        content.addSubview(reader)
        var inset: CGFloat = -1
        reader.onInsetChange = { inset = $0 }
        for size in [NSSize(width: 640, height: 560), NSSize(width: 1440, height: 900), NSSize(width: 900, height: 640)] {
            window.setContentSize(size)
            reader.frame = window.contentLayoutRect
            reader.reportCurrentInset()
            XCTAssertEqual(inset, 0, accuracy: 0.5, "Content already below the toolbar must not acquire a second top gap.")
            reader.frame = content.bounds
            reader.reportCurrentInset()
            XCTAssertEqual(inset, max(0, content.bounds.maxY - window.contentLayoutRect.maxY), accuracy: 0.5)
        }
        reader.removeFromSuperview()
    }

    func testNativeModeControlsKeepReadableTextAndSwitchEveryMode() throws {
        var selected = AppMode.anonymize
        let binding = Binding(get: { selected }, set: { selected = $0 })
        for compact in [false, true] {
            let host = NSHostingView(rootView: AppModePicker(selection: binding, compact: compact)
                .environment(\.appLanguage, .simplifiedChinese))
            host.frame = NSRect(x: 0, y: 0, width: compact ? 240 : 500, height: 28)
            host.layoutSubtreeIfNeeded()
            let control = try XCTUnwrap(descendants(host).compactMap { $0 as? NSControl }.first)
            XCTAssertGreaterThanOrEqual(control.font?.pointSize ?? 0, 15)
            for (index, mode) in AppMode.allCases.enumerated() {
                if let segmented = control as? NSSegmentedControl { segmented.selectedSegment = index }
                if let menu = control as? NSPopUpButton { menu.selectItem(at: index) }
                _ = control.sendAction(control.action, to: control.target)
                XCTAssertEqual(selected, mode)
            }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    func testSettingsKeepsOnlyItsReadableHeadingAfterNativeTitleChanges() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.toolbar = NSToolbar(identifier: "ReadableInterfaceTests.Settings")
        let bridge = SettingsToolbarView()
        try XCTUnwrap(window.contentView).addSubview(bridge)
        for _ in 0..<3 {
            window.titleVisibility = .visible
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            XCTAssertEqual(window.titleVisibility, .hidden)
            XCTAssertEqual(window.toolbarStyle, .unifiedCompact)
        }
        bridge.removeFromSuperview()
        window.titleVisibility = .visible
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(window.titleVisibility, .visible, "Detached bridges must stop managing their former window.")
    }

    func testAdvancedSettingsStayFindableAndSeparateFromDailyWork() {
        let advanced = SettingsSection.allCases.filter(\.isAdvanced)
        XCTAssertEqual(Set(advanced), [.assistants, .commandLine, .sharing])
        XCTAssertFalse(SettingsSection.general.isAdvanced)
        XCTAssertFalse(SettingsSection.detection.isAdvanced)
        XCTAssertEqual(Set(SettingsSection.allCases).count, 10)
    }

    func testLongLocalizedInstructionsWrapAtTheNarrowContentWidth() {
        for language in [AppLanguage.english, .french, .simplifiedChinese, .traditionalChinese] {
            for key in ["Add your files, review sensitive details, then export a redacted copy.",
                        "Or anonymize every document in a folder at once, with no review step."] {
                let text = L10n.text(key).font(CounselTheme.Typography.supporting)
                    .environment(\.appLanguage, language)
                let wide = NSHostingView(rootView: text.fixedSize())
                let narrow = NSHostingView(rootView: text.fixedSize(horizontal: false, vertical: true).frame(width: 280))
                XCTAssertGreaterThanOrEqual(narrow.fittingSize.height, wide.fittingSize.height)
                XCTAssertLessThanOrEqual(narrow.fittingSize.width, 280.5)
            }
        }
    }

    func testRenderProductionIntakeAtReviewSizesWhenRequested() throws {
        guard let directory = ProcessInfo.processInfo.environment["LDA_UX_CAPTURE_DIR"] else { return }
        let destination = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for language in [AppLanguage.english, .french, .simplifiedChinese, .traditionalChinese] {
            for dark in [false, true] {
                for size in [NSSize(width: 640, height: 560), NSSize(width: 900, height: 720)] {
                    let view = DocumentIntakeView(onChooseFiles: {}, onBatch: {})
                        .environment(\.appLanguage, language)
                        .environment(\.colorScheme, dark ? .dark : .light)
                    let host = NSHostingView(rootView: view)
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.frame = NSRect(origin: .zero, size: size)
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    let name = "intake-\(language.rawValue)-\(dark ? "dark" : "light")-\(Int(size.width)).png"
                    try data.write(to: destination.appendingPathComponent(name))
                }
            }
        }
    }
}
