import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import LDAUI

final class RootShellLayoutTests: XCTestCase {
    func testModePickerUsesCompactControlSize() throws {
        let source = try String(contentsOf: Self.sourceURL, encoding: .utf8)
        let modePickerStart = try XCTUnwrap(source.range(of: #"Picker("Mode""#))
        let modePickerEnd = try XCTUnwrap(
            source.range(of: ".help(", range: modePickerStart.lowerBound..<source.endIndex)
        )
        let modePicker = source[modePickerStart.lowerBound..<modePickerEnd.lowerBound]

        XCTAssertTrue(
            modePicker.contains(".controlSize(.small)"),
            "The principal mode picker must stay compact so it does not overlap "
                + "window content when macOS collapses the toolbar height."
        )
    }

    func testWindowPresentationSeparatesTitleExpansionFromNarrowContent() throws {
        let source = try String(contentsOf: Self.appShellSourceURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains("WindowLayoutPolicy.isNarrow(windowWidth: window.frame.width)"),
            "Workflow visibility must follow available window width."
        )
        XCTAssertTrue(source.contains("WindowLayoutPolicy.usesFullProductTitle("))
        XCTAssertTrue(source.contains("window.isZoomed"))
        XCTAssertTrue(source.contains("styleMask.contains(.fullScreen)"))
    }

    func testWindowTitleResolutionPreservesContextAndAdaptsFallback() {
        XCTAssertEqual(
            WindowTitleResolver.resolve(client: nil, document: nil, usesFullProductTitle: true),
            "Legal Document Anonymizer"
        )
        XCTAssertEqual(
            WindowTitleResolver.resolve(client: nil, document: nil, usesFullProductTitle: false),
            "LDA"
        )
        XCTAssertEqual(
            WindowTitleResolver.resolve(client: nil, document: "Agreement.docx", usesFullProductTitle: false),
            "Agreement.docx"
        )
        XCTAssertEqual(
            WindowTitleResolver.resolve(client: "Northstar", document: nil, usesFullProductTitle: false),
            "Northstar"
        )
        XCTAssertEqual(
            WindowTitleResolver.resolve(
                client: "Northstar",
                document: "Agreement.docx",
                usesFullProductTitle: false
            ),
            "Northstar \u{00B7} Agreement.docx"
        )
    }

    func testNarrowWindowPolicyAbbreviatesChromeAndHidesWorkflowRow() {
        XCTAssertTrue(WindowLayoutPolicy.isNarrow(windowWidth: 1_100))
        XCTAssertTrue(WindowLayoutPolicy.isNarrow(windowWidth: 1_199))
        XCTAssertFalse(WindowLayoutPolicy.isNarrow(windowWidth: 1_200))
        XCTAssertFalse(WindowLayoutPolicy.isNarrow(windowWidth: 2_560))

        XCTAssertFalse(WindowLayoutPolicy.showsWorkflowProgress(isWindowNarrow: true))
        XCTAssertTrue(WindowLayoutPolicy.showsWorkflowProgress(isWindowNarrow: false))

        XCTAssertFalse(
            WindowLayoutPolicy.usesFullProductTitle(isFullScreen: false, isZoomed: false)
        )
        XCTAssertTrue(
            WindowLayoutPolicy.usesFullProductTitle(isFullScreen: true, isZoomed: false)
        )
        XCTAssertTrue(
            WindowLayoutPolicy.usesFullProductTitle(isFullScreen: false, isZoomed: true)
        )
    }

    @MainActor
    func testCompactModePickerFitsNativeTwentyPointToolbarBudget() {
        let picker = Picker("Mode", selection: .constant("Anonymize")) {
            Text("Matters").tag("Matters")
            Text("Anonymize").tag("Anonymize")
            Text("Restore").tag("Restore")
            Text("Fill").tag("Fill")
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .frame(width: 430)

        let hostingView = NSHostingView(rootView: picker)
        XCTAssertLessThanOrEqual(hostingView.fittingSize.height, 20)
    }

    func testWorkflowHeaderFitsMinimumWindowWithWidestSidebar() throws {
        let appSource = try String(contentsOf: Self.ldaAppSourceURL, encoding: .utf8)
        let shellSource = try String(contentsOf: Self.appShellSourceURL, encoding: .utf8)

        XCTAssertTrue(appSource.contains(".frame(minWidth: 1100, minHeight: 720)"))
        XCTAssertTrue(shellSource.contains("min: 260, ideal: 320, max: 420"))
        XCTAssertTrue(shellSource.contains(".frame(maxWidth: 72)"))

        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let textWidth = ["Add", "Scan", "Review", "Share"].reduce(CGFloat.zero) {
            $0 + ($1 as NSString).size(withAttributes: [.font: font]).width
        }
        let stepIconsAndSpacing: CGFloat = 4 * (13 + 6)
        let connectors: CGFloat = 3 * (72 + 16)
        let outerPadding: CGFloat = 40
        let conservativeHeaderWidth = textWidth + stepIconsAndSpacing + connectors + outerPadding
        let minimumDetailWidth: CGFloat = 1100 - 420

        XCTAssertLessThan(conservativeHeaderWidth, minimumDetailWidth)
    }

    func testTopLevelSurfacesAvoidManualTitleBarOffsets() throws {
        for url in Self.topLevelSurfaceURLs {
            let source = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(source.contains(".offset("), "Unexpected manual offset in \(url.lastPathComponent)")
        }
    }

    func testRestoreCardsAndFillColumnsFitMinimumWindowBudget() throws {
        let restoreSource = try String(contentsOf: Self.restoreSourceURL, encoding: .utf8)
        let fillSource = try String(contentsOf: Self.fillViewsSourceURL, encoding: .utf8)

        XCTAssertTrue(restoreSource.contains(".frame(maxWidth: 860)"))
        XCTAssertTrue(restoreSource.contains(".padding(32)"))
        XCTAssertLessThan(CGFloat(860 + 64), 1100)

        for marker in [
            ".frame(width: 220)",
            #"columnHeader("Field", width: 180)"#,
            #"columnHeader("Value", minWidth: 200)"#,
            #"columnHeader("Source", width: 160)"#,
            #"columnHeader("Confidence", width: 100)"#,
            #"columnHeader("", width: 24)"#
        ] {
            XCTAssertTrue(fillSource.contains(marker), "Missing Fill layout marker: \(marker)")
        }
        let fillSidebarWidth: CGFloat = 220
        let fillTableWidth: CGFloat = 180 + 200 + 160 + 100 + 24
        XCTAssertLessThan(fillSidebarWidth + fillTableWidth, 1100)
    }

    func testFillLibraryChromeRemainsInNormalContentFlow() throws {
        let source = try String(contentsOf: Self.fillLibrarySourceURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains("WindowContentTopInsetReader(topInset: $windowChromeTopInset)"),
            "Fill must read the native window content boundary instead of guessing toolbar height."
        )
        XCTAssertTrue(
            source.contains(".frame(height: windowChromeTopInset)"),
            "Fill must reserve the measured native toolbar clearance before page controls."
        )
        XCTAssertFalse(
            source.contains(".safeAreaInset(edge: .top"),
            "A top safe-area inset can place Fill notices inside the compact macOS toolbar."
        )
    }

    func testWindowChromeInsetPolicyUsesTheNativeContentLayoutDifference() {
        XCTAssertEqual(
            WindowChromeLayoutPolicy.topInset(windowFrameHeight: 772, contentLayoutHeight: 720),
            52
        )
        XCTAssertEqual(
            WindowChromeLayoutPolicy.topInset(windowFrameHeight: 772, contentLayoutHeight: 772),
            0
        )
        XCTAssertEqual(
            WindowChromeLayoutPolicy.topInset(windowFrameHeight: 720, contentLayoutHeight: 772),
            0
        )
    }

    private static let packageRootURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let sourceURL = packageRootURL
        .appendingPathComponent("Sources/LDAUI/RootShell.swift")

    private static let appShellSourceURL = sourceURL
        .deletingLastPathComponent()
        .appendingPathComponent("AppShell.swift")

    private static let ldaAppSourceURL = packageRootURL
        .appendingPathComponent("Sources/LDAApp/LDAApp.swift")

    private static let restoreSourceURL = packageRootURL
        .appendingPathComponent("Sources/LDAUI/DeanonymizeShell.swift")

    private static let fillViewsSourceURL = packageRootURL
        .appendingPathComponent("Sources/LDAUI/FillShellViews.swift")

    private static let fillLibrarySourceURL = packageRootURL
        .appendingPathComponent("Sources/LDAUI/FillLibraryViews.swift")

    private static let topLevelSurfaceURLs = [
        "RootShell.swift",
        "AppShell.swift",
        "MatterWorkspaceView.swift",
        "DeanonymizeShell.swift",
        "FillShell.swift",
        "FillLibraryViews.swift"
    ].map {
        packageRootURL.appendingPathComponent("Sources/LDAUI/\($0)")
    }
}
