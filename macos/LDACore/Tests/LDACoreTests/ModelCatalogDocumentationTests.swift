//
//  ModelCatalogDocumentationTests.swift
//  LDACoreTests
//
//  Keeps the model-installation instructions in macos/LDACore/README.md in
//  agreement with the shipped catalog. A reader of the offline path compares
//  the digest and the byte count by eye and then copies a release URL, so a
//  catalog change that leaves those figures behind sends someone to the wrong
//  file with no way to notice.
//
//  The manifest is read as raw JSON from the source tree rather than through
//  ModelCatalog, deliberately: this check has to be able to look for keys that
//  ModelTier does not decode yet (offlineSourceURL arrives with the in-app
//  import path), and it has to fail on a missing file rather than quietly
//  passing on an empty catalog.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import XCTest

final class ModelCatalogDocumentationTests: XCTestCase {

    func testTheReadmePublishesTheQuickTierChecksumAndSize() throws {
        let quick = try quickTier()
        let readme = try readmeText()

        let digest = try XCTUnwrap(quick["sha256"] as? String, "quick tier has no sha256")
        XCTAssertEqual(digest.count, 64, "a SHA-256 is 64 hex characters: \(digest)")
        XCTAssertTrue(
            readme.contains(digest),
            "macos/LDACore/README.md must publish the quick tier digest \(digest) verbatim, "
            + "because the offline path tells the reader to compare it by eye"
        )

        let sizeBytes = try XCTUnwrap(quick["sizeBytes"] as? NSNumber, "quick tier has no sizeBytes")
        XCTAssertTrue(
            readme.contains(sizeBytes.stringValue),
            "macos/LDACore/README.md must publish the quick tier byte count "
            + "\(sizeBytes.stringValue) verbatim"
        )
    }

    func testTheReadmePublishesTheQuickTierOfflineSourceURL() throws {
        let quick = try quickTier()

        // offlineSourceURL is added by the in-app import work, not here. Until
        // that lands the key is absent from Models.json and there is nothing to
        // agree with, so skip rather than fail. Once the key exists this
        // assertion goes live and a release URL that is not documented in the
        // README becomes a test failure.
        guard let offlineSourceURL = quick["offlineSourceURL"] as? String,
              !offlineSourceURL.isEmpty else {
            throw XCTSkip(
                "Models.json has no offlineSourceURL for the quick tier yet; "
                + "the README agreement becomes live when that field ships"
            )
        }

        let readme = try readmeText()
        XCTAssertTrue(
            readme.contains(offlineSourceURL),
            "macos/LDACore/README.md must name the offline release URL "
            + "\(offlineSourceURL) verbatim so a reader can reach the assets"
        )
    }

    // MARK: - Fixtures

    /// The package root, located the way UIClaimsDisciplineTests locates
    /// Sources/LDAUI: from this file rather than from a bundle, so the check
    /// reads the tree that is about to be committed.
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func quickTier() throws -> [String: Any] {
        let url = Self.packageRoot
            .appendingPathComponent("Sources/LDAUI/Resources/Models.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("Models.json not found at \(url.path); this check must not be skipped")
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        let tiers = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
            "Models.json is not an array of objects"
        )
        return try XCTUnwrap(
            tiers.first { $0["id"] as? String == "quick" },
            "Models.json has no quick tier"
        )
    }

    private func readmeText() throws -> String {
        let url = Self.packageRoot.appendingPathComponent("README.md")
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("README.md not found at \(url.path); this check must not be skipped")
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
