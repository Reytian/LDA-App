import Foundation
import XCTest

final class OnboardingContentTests: XCTestCase {
    func testOnboardingDoesNotDescribeReleaseAsUnnotarized() throws {
        let source = try String(contentsOf: Self.sourceURL, encoding: .utf8)

        XCTAssertFalse(source.localizedCaseInsensitiveContains("not yet notarized"))
        XCTAssertFalse(source.contains("right-click LDA in Finder"))
    }

    private static let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/LDAUI/OnboardingView.swift")
}
