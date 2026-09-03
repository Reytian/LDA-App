//
//  BundledModelClaimTests.swift
//  LDACoreTests
//
//  No model ships inside the app. The shipping build downloads one or accepts
//  one through the verified import, and only a deliberate BUNDLE_MODEL=1 build
//  carries a model in its Resources.
//
//  Every user-visible sentence that asserted otherwise was false the moment
//  that changed, and this is the boring half of the work where a rushed pass
//  leaves a lie in the product. So the assertion is a test rather than a memory:
//  a claim can only come back through this file.
//
//  What is DELIBERATELY still allowed: strings guarded by
//  ModelCatalog.isBundled, which are correct exactly when they render, and
//  which a BUNDLE_MODEL=1 build still needs. Those are enumerated below with
//  the guard that makes each one true.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import XCTest

final class BundledModelClaimTests: XCTestCase {

    /// User-visible copy that asserts a model is part of the app.
    ///
    /// Lowercased substrings, matched against string literals only, so a
    /// comment may still explain the invariant it does not break.
    private let forbiddenClaims = [
        "quick is built in",
        "quick ships inside",
        "the built-in model",
        "the built in model",
        "ships inside the app",
        "quick is bundled"
    ]

    /// Literals that name the bundled state and are correct because the view
    /// only renders them behind a check. Each is paired with the guard.
    ///
    /// Kept as an explicit list rather than an exemption by file, so removing
    /// one of these guards makes the exemption stale and visible.
    private let guardedByIsBundled: [String: String] = [
        "Built in": "modelRow: `if bundled { tag(...) }`",
        "Built in and verified. Part of the app, so it cannot be removed.":
            "statusLine: `if bundled`",
        "A downloaded copy of %@ is also on this Mac. It is not needed because %@ is built into the app.":
            "modelRow: `if let redundant = ModelCatalog.redundantContainerCopy(...)`",
        // Matched on its distinctive prefix: the shipped literal spells its
        // middle dot as a \u escape, which is not the character itself.
        "%@, inside the app": "ModelAnnotation.localizedFacts(bundled:)"
    ]

    private func sourcesDirectory() throws -> URL {
        let here = URL(fileURLWithPath: #filePath)
        let root = here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        guard FileManager.default.fileExists(atPath: sources.path) else {
            XCTFail("Sources not found at \(sources.path); this check must not be skipped")
            throw CocoaError(.fileNoSuchFile)
        }
        return sources
    }

    func testNoSourceFileClaimsAModelShipsInsideTheApp() throws {
        let sources = try sourcesDirectory()
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            return XCTFail("could not walk \(sources.path)")
        }
        var offenders: [String: Set<String>] = [:]
        var scanned = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            for literal in stringLiterals(in: text) {
                let normalized = literal.lowercased()
                for claim in forbiddenClaims where normalized.contains(claim) {
                    offenders[url.lastPathComponent, default: []].insert(claim)
                }
            }
        }
        XCTAssertGreaterThan(scanned, 50, "the walk found almost nothing; check the path")
        XCTAssertTrue(
            offenders.isEmpty,
            """
            User-visible copy still claims a model is part of the app: \(offenders).
            No model ships inside the app by default. If a BUNDLE_MODEL=1 build \
            needs to say this, guard the string on ModelCatalog.isBundled and \
            add it to guardedByIsBundled here with its guard.
            """
        )
    }

    func testTheBundledCopyThatSurvivesIsStillGuarded() throws {
        // The exemptions must not go stale. Each guarded literal has to be
        // present AND the file it lives in has to still consult isBundled,
        // otherwise the string has become an unconditional claim.
        let sources = try sourcesDirectory()
        let view = sources.appendingPathComponent("LDAUI/ModelManagementView.swift")
        let text = try String(contentsOf: view, encoding: .utf8)
        XCTAssertTrue(
            text.contains("ModelCatalog.isBundled"),
            "the guarded strings in this file are only true behind isBundled"
        )
        for (literal, reason) in guardedByIsBundled {
            XCTAssertTrue(
                text.contains(literal),
                "stale exemption (\(reason)): remove it rather than leaving it"
            )
        }
    }

    func testTheCatalogsCarryNoRetiredBundledClaim() throws {
        let here = URL(fileURLWithPath: #filePath)
        let resources = here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LDAUI/Resources", isDirectory: true)
        for identifier in ["en", "fr", "zh-Hans", "zh-Hant"] {
            let url = resources
                .appendingPathComponent("\(identifier).lproj/Localizable.strings")
            let catalog = try XCTUnwrap(
                NSDictionary(contentsOf: url) as? [String: String],
                "could not parse \(identifier)"
            )
            XCTAssertNil(
                catalog[
                    "Quick is built in and works on every Mac LDA supports. With 24 GB of memory or more, Balanced finds the same amount and leaves you far less to dismiss. Most thorough is the only one that missed nothing in our testing."
                ],
                "\(identifier) still carries the retired built-in claim"
            )
            XCTAssertNotNil(
                catalog[
                    "Quick is the smallest download and works on every Mac LDA supports. With 24 GB of memory or more, Balanced finds the same amount and leaves you far less to dismiss. Most thorough is the only one that missed nothing in our testing."
                ],
                "\(identifier) is missing the replacement"
            )
            // The relabelled custom-model section: its old neutral title gave
            // no hint that the file is unchecked.
            XCTAssertNil(catalog["Use another model"], "\(identifier) has an orphan key")
            XCTAssertNil(
                catalog["Choose a local GGUF model for on-device detection."],
                "\(identifier) has an orphan key"
            )
        }
    }

    /// Ordinary Swift string literals, joined across `+` the way the UI splits
    /// long copy, so a claim cannot hide in a concatenation.
    private func stringLiterals(in source: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #""(?:\\.|[^"\\])*""#) else {
            return []
        }
        let text = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: text.length))
        var groups: [String] = []
        var current = ""
        var previousEnd: Int?
        for match in matches {
            if let previousEnd {
                let separator = text.substring(
                    with: NSRange(
                        location: previousEnd, length: match.range.location - previousEnd
                    )
                )
                let adjacent = separator.allSatisfy { $0.isWhitespace || $0 == "+" }
                if !adjacent, !current.isEmpty {
                    groups.append(current)
                    current = ""
                }
            }
            current += text.substring(with: match.range).dropFirst().dropLast()
            previousEnd = match.range.location + match.range.length
        }
        if !current.isEmpty { groups.append(current) }
        return groups.map {
            $0.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
    }
}
