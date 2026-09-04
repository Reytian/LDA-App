import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import LDAUI

// The source markers below name L10n.text / L10n.picker / .l10nHelp rather
// than Text / Picker / .help. That is not a cosmetic rename: those are the
// only spellings that reach the in-app language override, so a marker naming
// the bare SwiftUI form would now be pinning a site that renders in the
// system language instead of the picked one. See LocalizationRoutingTests.
final class RootShellLayoutTests: XCTestCase {
    func testModePickerUsesCompactControlSize() throws {
        let source = try String(contentsOf: Self.sourceURL, encoding: .utf8)
        let modePickerStart = try XCTUnwrap(source.range(of: #"L10n.picker("Mode""#))
        let modePickerEnd = try XCTUnwrap(
            source.range(of: ".l10nHelp(", range: modePickerStart.lowerBound..<source.endIndex)
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
        let headerSource = try String(contentsOf: Self.workflowHeaderSourceURL, encoding: .utf8)

        XCTAssertTrue(appSource.contains(".frame(minWidth: 1100, minHeight: 720)"))
        XCTAssertTrue(shellSource.contains("min: 260, ideal: 320, max: 420"))
        XCTAssertTrue(headerSource.contains(".frame(maxWidth: 72)"))

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

    func testExportForAIDelegatesToTheFlowAndNoLongerTouchesTheClipboard() throws {
        let source = try String(contentsOf: Self.appShellSourceURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains("ExportForAIFlow.run(session: session)"),
            "the shell must route Export for AI through the flow that asks for the destination first"
        )
        XCTAssertFalse(
            source.contains("NSPasteboard.general.setString(handoff.combined"),
            "the clipboard handoff is gone; the file is the only outbound artifact"
        )
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
        XCTAssertTrue(
            restoreSource.contains(".dropDestination(for: URL.self)"),
            "Dropping a file onto the Restore card must start the same flow as the button."
        )

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
        let source = try String(contentsOf: Self.fillShellSourceURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains("WindowContentTopInsetReader(topInset: $windowChromeTopInset)"),
            "Every Fill stage must read the native window content boundary."
        )
        XCTAssertTrue(
            source.contains("WindowChromeTopSpacer(height: windowChromeTopInset"),
            "Fill must reserve native toolbar clearance outside its stage switch."
        )
        XCTAssertFalse(
            source.contains(".safeAreaInset(edge: .top"),
            "A top safe-area inset can place Fill notices inside the compact macOS toolbar."
        )

        let librarySource = try String(contentsOf: Self.fillLibrarySourceURL, encoding: .utf8)
        XCTAssertFalse(
            librarySource.contains("WindowContentTopInsetReader"),
            "The reader must not disappear when Fill leaves the portfolio library."
        )
    }

    func testMatterSidebarReservesNativeWindowChromeBeforeItsCustomHeader() throws {
        let source = try String(contentsOf: Self.matterSourceURL, encoding: .utf8)
        let sidebarStart = try XCTUnwrap(source.range(of: "private var sidebar: some View"))
        let headerStart = try XCTUnwrap(
            source.range(of: "L10n.text(\"Matters\")", range: sidebarStart.lowerBound..<source.endIndex)
        )
        let sidebarPrefix = source[sidebarStart.lowerBound..<headerStart.lowerBound]

        XCTAssertTrue(source.contains("WindowContentTopInsetReader(topInset: $windowChromeTopInset)"))
        XCTAssertTrue(sidebarPrefix.contains("WindowChromeTopSpacer(height: windowChromeTopInset"))
        XCTAssertFalse(source.contains(".safeAreaInset(edge: .top"))
    }

    func testRestoreReservesNativeWindowChromeBeforeScrollablePageContent() throws {
        let source = try String(contentsOf: Self.restoreSourceURL, encoding: .utf8)
        let bodyStart = try XCTUnwrap(source.range(of: "public var body: some View"))
        let scrollStart = try XCTUnwrap(
            source.range(of: "ScrollView", range: bodyStart.lowerBound..<source.endIndex)
        )
        let bodyPrefix = source[bodyStart.lowerBound..<scrollStart.lowerBound]

        XCTAssertTrue(source.contains("WindowContentTopInsetReader(topInset: $windowChromeTopInset)"))
        XCTAssertTrue(bodyPrefix.contains("WindowChromeTopSpacer(height: windowChromeTopInset"))
        XCTAssertFalse(source.contains(".safeAreaInset(edge: .top"))
    }

    func testWindowChromeReaderLivesInSharedUIInfrastructure() throws {
        let source = try String(contentsOf: Self.windowChromeSourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("struct WindowContentTopInsetReader"))
        XCTAssertTrue(source.contains("final class WindowContentInsetView"))
        XCTAssertTrue(source.contains("struct WindowChromeTopSpacer"))
        XCTAssertTrue(source.contains("window.observe("))
        XCTAssertTrue(source.contains("contentLayoutObservation = nil"))
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

    @MainActor
    func testWindowChromeSpacerKeepsItsMeasuredHeight() {
        let hostingView = NSHostingView(
            rootView: WindowChromeTopSpacer(height: 52, background: Color.clear)
                .frame(width: 800)
        )

        XCTAssertEqual(hostingView.fittingSize.height, 52, accuracy: 0.5)
    }

    @MainActor
    func testWindowContentInsetViewReportsTheAttachedNativeWindow() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.toolbar = NSToolbar(identifier: "RootShellLayoutTests.Toolbar")

        let probe = WindowContentInsetView(frame: .zero)
        var reportedInset: CGFloat?
        probe.onInsetChange = { reportedInset = $0 }
        try XCTUnwrap(window.contentView).addSubview(probe)
        probe.reportCurrentInset()

        XCTAssertEqual(
            try XCTUnwrap(reportedInset),
            WindowChromeLayoutPolicy.topInset(
                windowFrameHeight: window.frame.height,
                contentLayoutHeight: window.contentLayoutRect.height
            ),
            accuracy: 0.5
        )

        probe.removeFromSuperview()
        reportedInset = nil
        probe.reportCurrentInset()
        XCTAssertNil(reportedInset, "A detached reader must stop reporting its former window.")
    }

    func testReadableTypographyRolesAreUsedForSentencesAndInstructions() throws {
        let themeSource = try String(contentsOf: Self.themeSourceURL, encoding: .utf8)
        let restoreSource = try String(contentsOf: Self.restoreSourceURL, encoding: .utf8)
        // The shell's own prose renders through AdvisoryRow (both the
        // tracked-changes row and the missing-model row are two-line wrappers
        // around it), so the supporting role is asserted where those sentences
        // actually live. The completion card has its own font-role check below,
        // keyed on "private func completionNote", so pointing this at the card
        // would duplicate that and leave the advisory path unasserted.
        let advisorySource = try String(contentsOf: Self.advisoryRowSourceURL, encoding: .utf8)
        let sidebarSource = try String(contentsOf: Self.entitySidebarSourceURL, encoding: .utf8)
        let matterSource = try String(contentsOf: Self.matterSourceURL, encoding: .utf8)

        for role in ["pageTitle", "sectionTitle", "readingBody", "supporting", "metadata"] {
            XCTAssertTrue(themeSource.contains("static let \(role)"), "Missing typography role: \(role)")
        }
        XCTAssertTrue(restoreSource.contains("CounselTheme.Typography.pageTitle"))
        XCTAssertGreaterThanOrEqual(
            restoreSource.components(separatedBy: "CounselTheme.Typography.readingBody").count - 1,
            2
        )
        XCTAssertTrue(restoreSource.contains("CounselTheme.Typography.sectionTitle"))
        XCTAssertTrue(restoreSource.contains("CounselTheme.Typography.supporting"))
        XCTAssertTrue(advisorySource.contains("CounselTheme.Typography.supporting"))
        XCTAssertTrue(sidebarSource.contains("CounselTheme.Typography.supporting"))
        XCTAssertTrue(matterSource.contains("CounselTheme.Typography.supporting"))
    }

    func testExplanatoryCopyDoesNotFallBackToMetadataTypography() throws {
        try assertFontRole(
            in: Self.entitySidebarSourceURL,
            after: "Text(verbatim: localizedEmptyStateDetail)",
            role: "CounselTheme.Typography.supporting"
        )
        try assertFontRole(
            in: Self.entitySidebarSourceURL,
            after: "L10n.text(\"This text stands in for the value in the safe copy.",
            role: "CounselTheme.Typography.supporting"
        )
        try assertFontRole(
            in: Self.entitySidebarSourceURL,
            after: "Text(replacementError)",
            role: "CounselTheme.Typography.supporting"
        )
        try assertFontRole(
            in: Self.matterSourceURL,
            after: "The matter appears in this workspace after your first Export for AI.",
            role: "CounselTheme.Typography.supporting"
        )
        try assertFontRole(
            in: Self.fillReviewSourceURL,
            after: "Text(verbatim: FillServicePresentation.skippedReason(",
            role: "CounselTheme.Typography.supporting"
        )
        try assertFontRole(
            in: Self.handoffCardSourceURL,
            after: "private func completionNote",
            role: "CounselTheme.Typography.supporting"
        )
        try assertFontRole(
            in: Self.settingsSourceURL,
            after: "LDA processes document contents on this Mac.",
            role: "CounselTheme.Typography.supporting"
        )
        try assertFontRole(
            in: Self.settingsSourceURL,
            after: "OnboardingPresentation.chooseLine(for: rung",
            role: "CounselTheme.Typography.supporting"
        )
        try assertFontRole(
            in: Self.modelManagementSourceURL,
            after: "Detection models process document text on this Mac.",
            role: "CounselTheme.Typography.readingBody"
        )
        try assertFontRole(
            in: Self.modelManagementSourceURL,
            after: "Refuse all network requests, including model downloads.",
            role: "CounselTheme.Typography.supporting"
        )
        try assertFontRole(
            in: Self.modelManagementSourceURL,
            after: "Quick is the smallest download and works on every Mac LDA supports.",
            role: "CounselTheme.Typography.readingBody"
        )
        try assertFontRole(
            in: Self.modelManagementSourceURL,
            after: "Text(verbatim: ModelAnnotation.localizedBody(for: lvl))",
            role: "CounselTheme.Typography.supporting"
        )
        try assertFontRole(
            in: Self.modelManagementSourceURL,
            after: "Text(verbatim: ModelAnnotation.localizedFacts(for: tier, bundled: bundled))",
            role: "CounselTheme.Typography.supporting"
        )
    }

    private func assertFontRole(in url: URL, after marker: String, role: String) throws {
        let source = try String(contentsOf: url, encoding: .utf8)
        let markerRange = try XCTUnwrap(source.range(of: marker), "Missing marker: \(marker)")
        let styleEnd = try XCTUnwrap(
            source.range(of: ".foregroundStyle", range: markerRange.lowerBound..<source.endIndex),
            "Missing style boundary after: \(marker)"
        )
        let styledCopy = source[markerRange.lowerBound..<styleEnd.lowerBound]
        XCTAssertTrue(styledCopy.contains(role), "\(marker) must use \(role)")
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

    /// The guided workflow row, extracted from AppShell.
    private static let workflowHeaderSourceURL = sourceURL
        .deletingLastPathComponent()
        .appendingPathComponent("AppShellWorkflowHeader.swift")

    /// The shared advisory row. The shell's advisories are wrappers around it,
    /// so this file, not AppShell.swift, is where their typography lives.
    private static let advisoryRowSourceURL = sourceURL
        .deletingLastPathComponent()
        .appendingPathComponent("AdvisoryRow.swift")

    /// The handoff completion card, extracted from AppShell.
    private static let handoffCardSourceURL = sourceURL
        .deletingLastPathComponent()
        .appendingPathComponent("HandoffCompletionCard.swift")

    private static let ldaAppSourceURL = packageRootURL
        .appendingPathComponent("Sources/LDAApp/LDAApp.swift")

    private static let restoreSourceURL = packageRootURL
        .appendingPathComponent("Sources/LDAUI/DeanonymizeShell.swift")

    private static let matterSourceURL = packageRootURL
        .appendingPathComponent("Sources/LDAUI/MatterWorkspaceView.swift")

    private static let fillShellSourceURL = packageRootURL
        .appendingPathComponent("Sources/LDAUI/FillShell.swift")

    private static let fillViewsSourceURL = packageRootURL
        .appendingPathComponent("Sources/LDAUI/FillShellViews.swift")

    private static let fillLibrarySourceURL = packageRootURL
        .appendingPathComponent("Sources/LDAUI/FillLibraryViews.swift")

    private static let fillReviewSourceURL = packageRootURL
        .appendingPathComponent("Sources/LDAUI/FillReviewViews.swift")

    private static let windowChromeSourceURL = packageRootURL
        .appendingPathComponent("Sources/LDAUI/WindowChromeLayout.swift")

    private static let themeSourceURL = packageRootURL
        .appendingPathComponent("Sources/LDAUI/CounselTheme.swift")

    private static let entitySidebarSourceURL = packageRootURL
        .appendingPathComponent("Sources/LDAUI/EntitySidebar.swift")

    private static let settingsSourceURL = packageRootURL
        .appendingPathComponent("Sources/LDAUI/SettingsView.swift")

    private static let modelManagementSourceURL = packageRootURL
        .appendingPathComponent("Sources/LDAUI/ModelManagementView.swift")

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
