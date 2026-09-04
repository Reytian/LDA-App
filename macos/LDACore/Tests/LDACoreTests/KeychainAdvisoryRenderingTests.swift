//
//  KeychainAdvisoryRenderingTests.swift
//  LDACoreTests
//
//  Pins WHERE the Touch ID fallback is told to the user, which is the half of
//  that finding nothing was guarding.
//
//  The background: Touch ID protection had never engaged once on a real
//  machine. addProtectedKey's SecItemAdd fails, migrateToUserPresence catches
//  it, records an advisory, keeps the silent key, and everything keeps working.
//  KeychainAdvisoryStore existed and was already wired into two views, so a
//  banner should have appeared. None did. So the product spent every launch
//  silently asserting a security guarantee it was not keeping, and the
//  recording half of the fix is worthless without a rendering guard.
//
//  Two rules, both asserted here:
//
//  1. The fallback must reach the user as VISIBLE PROSE, never only as a
//     tooltip. A .help on a control is unreliable and a warning nobody hovers
//     is a warning nobody reads. This is the same lesson as the Save Redacted
//     availability work: a silent gate reads as success.
//  2. It must be said ONCE per screen. It briefly rendered both as a chip in
//     AppShellStatusBanner and as an AdvisoryRow in AppShell, a few points
//     apart in the same VStack, so one fallback read as two problems.
//
//  Source-text assertions rather than view rendering, matching the convention
//  in RootShellLayoutTests and UIClaimsDisciplineTests: a SwiftUI body cannot
//  be inspected without hosting it, and what needs pinning here is which file
//  owns the surface.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import XCTest

final class KeychainAdvisoryRenderingTests: XCTestCase {

    private static let uiSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/LDAUI")

    private func source(_ name: String) throws -> String {
        try String(
            contentsOf: Self.uiSources.appendingPathComponent(name),
            encoding: .utf8
        )
    }

    /// Every file that reads the store, so a new surface has to be considered
    /// here rather than appearing silently.
    private func filesReadingTheStore() throws -> [String] {
        let names = try FileManager.default
            .contentsOfDirectory(at: Self.uiSources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        return try names
            .filter { url in
                let text = try String(contentsOf: url, encoding: .utf8)
                return text.contains("keychainAdvisory.advisory")
            }
            .map(\.lastPathComponent)
            .sorted()
    }

    // MARK: - Rule 1: prose, not a tooltip

    func testTheFallbackIsStatedAsProseInTheAnonymizeShell() throws {
        let shell = try source("AppShell.swift")
        XCTAssertTrue(
            shell.contains("if let advice = keychainAdvisory.advisory {"),
            "AppShell must read the advisory. If this moved, the Touch ID "
                + "fallback may no longer reach the Anonymize shell at all, "
                + "which is the condition that shipped."
        )
        XCTAssertTrue(
            shell.contains("keychainProtectionAdvisory(advice)"),
            "the fallback must render through the AdvisoryRow helper, which "
                + "states it as visible prose beside the missing-model and "
                + "tracked-changes advisories"
        )
    }

    func testTheFallbackIsStatedAsProseInSettings() throws {
        let settings = try source("SettingsView.swift")
        let marker = "if let advisory = keychainAdvisory.advisory {"
        let start = try XCTUnwrap(
            settings.range(of: marker),
            "Settings must read the advisory: it is where a user checks their "
                + "security posture deliberately, rather than noticing a banner"
        )
        let block = settings[start.upperBound...].prefix(400)
        XCTAssertTrue(
            block.contains("Text(verbatim: advisory)"),
            "Settings must render the advisory sentence itself, not a short "
                + "label with the sentence hidden in a tooltip"
        )
    }

    // MARK: - Rule 2: once per screen

    func testTheStatusBannerDoesNotAlsoRenderTheFallback() throws {
        let banner = try source("AppShellStatusBanner.swift")
        XCTAssertFalse(
            banner.contains("keychainAdvisory.advisory"),
            "AppShellStatusBanner must NOT render the keychain fallback. "
                + "AppShell already renders it as an AdvisoryRow a few points "
                + "below in the same VStack, so a chip here makes one fallback "
                + "read as two problems, and the chip put its substance in a "
                + "tooltip. See the note in that file."
        )
    }

    func testTheFallbackHasExactlyTwoRenderSitesAndBothAreKnown() throws {
        XCTAssertEqual(
            try filesReadingTheStore(), ["AppShell.swift", "SettingsView.swift"],
            "the keychain fallback has exactly two intended surfaces: the "
                + "Anonymize shell's advisory stack and Settings. A third "
                + "reader is either a duplicate on a screen that already says "
                + "it, or a new surface that needs a rule of its own here."
        )
    }

    // MARK: - The advisory is never rendered through an unreliable channel

    func testNoFileStatesTheFallbackOnlyThroughHelpOrAccessibility() throws {
        for name in try filesReadingTheStore() {
            let text = try source(name)
            let start = try XCTUnwrap(text.range(of: "keychainAdvisory.advisory"))
            let block = text[start.upperBound...].prefix(500)
            let hasProse = block.contains("Text(verbatim: advisory)")
                || block.contains("keychainProtectionAdvisory(advice)")
            XCTAssertTrue(
                hasProse,
                "\(name) reads the advisory but does not appear to state it as "
                    + "visible text within the following block. A fallback "
                    + "surfaced only via .help or .accessibilityLabel is one "
                    + "nobody reads."
            )
        }
    }
}
