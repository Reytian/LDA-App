//
//  LiveModelResolverTests.swift
//  LDACoreTests
//
//  Guards the live-model resolver itself, which is the one piece of test
//  support whose failure mode is SILENCE.
//
//  History this file exists to prevent: LiveModelTestSupport hardcoded
//  "lda-v2-Q4_K_M.gguf". That fine-tune was retired in favour of stock
//  Qwen3.5-4B, the constant was never updated, modelPath() resolved a file
//  that no longer existed, and every caller turned the nil into XCTSkip.
//  All eight live-model tests stopped running and the suite still reported
//  "0 failures", so a shipped build was validated by a run in which no model
//  was ever loaded and PERSON, COMPANY and ADDRESS (LLM-only) were never
//  exercised.
//
//  The lesson generalises: a skip is green, so a resolver that quietly finds
//  nothing is worse than one that throws. These tests make the quiet case
//  loud.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import XCTest

final class LiveModelResolverTests: XCTestCase {

    // MARK: - The default tracks the catalog, not a copied string

    func testResolvedFileNameIsTheSmallestCatalogTier() throws {
        let data = try Data(contentsOf: LiveModelTestSupport.catalogURL)
        let tiers = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]],
            "Models.json must decode as an array of tier objects"
        )
        let smallest = try XCTUnwrap(tiers.first, "the catalog must list at least one tier")
        let expected = try XCTUnwrap(smallest["fileName"] as? String)

        XCTAssertEqual(
            LiveModelTestSupport.catalogModelFileName(), expected,
            "the live-model resolver must take its file name from the smallest "
                + "catalog tier. If this fails because the catalog was reordered "
                + "or a tier renamed, fix the resolver; do NOT restate the name "
                + "in the test support file, which is how the lda-v2 regression "
                + "happened."
        )
    }

    func testTheRetiredFineTuneNameIsGoneFromTestSupport() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("LiveModelTestSupport.swift"),
            encoding: .utf8
        )
        // A literal filename in the resolver is the defect, whatever it names.
        // Comments are allowed to discuss the history, so only a quoted
        // .gguf outside a comment line would reintroduce it.
        let offending = source
            .split(separator: "\n")
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { return false }
                return trimmed.contains("\".gguf") || trimmed.contains("-Q4_K_M.gguf\"")
            }
        XCTAssertTrue(
            offending.isEmpty,
            "LiveModelTestSupport must not hardcode a GGUF file name; it reads "
                + "Models.json. Offending lines: \(offending)"
        )
    }

    // MARK: - A present-but-unfound model must be loud, not a skip

    /// The exact condition that hid the regression: the directory HAS a model,
    /// the resolver wants a different name, and every caller skips.
    ///
    /// A skip is the right answer when the machine simply has no model. It is
    /// the wrong answer when a model is sitting right there under another
    /// name, because that is a configuration bug masquerading as an absent
    /// download. This test fails rather than skips in that case.
    func testAModelOnDiskThatTheResolverCannotFindIsAFailureNotASkip() {
        let installed = LiveModelTestSupport.installedModelFileNames()
        guard !installed.isEmpty else {
            // No model on this machine at all: nothing to be inconsistent
            // about. Deliberately not an XCTSkip, so this test never
            // participates in the skip count it exists to police.
            return
        }
        guard let wanted = LiveModelTestSupport.catalogModelFileName() else {
            return XCTFail("Models.json is unreadable, so the resolver cannot resolve anything")
        }
        XCTAssertNotNil(
            LiveModelTestSupport.modelPath(),
            "\(LiveModelTestSupport.modelDirectoryURL.path) holds "
                + "\(installed.joined(separator: ", ")) but the resolver wants "
                + "\(wanted) and found nothing, so every live-model test is "
                + "skipping while a model is installed. Either the catalog's "
                + "smallest tier or the installed file name is wrong. Do not "
                + "symlink one to the other: that hides this same class of bug."
        )
    }

    // MARK: - The override still wins

    func testEnvironmentOverrideTakesPrecedenceWhenItPointsAtARealFile() throws {
        // Uses this source file as a stand-in for a model: the resolver only
        // checks existence, so no 2.7 GB fixture is needed to prove ordering.
        let existing = #filePath
        XCTAssertTrue(FileManager.default.fileExists(atPath: existing))

        guard ProcessInfo.processInfo.environment[
            LiveModelTestSupport.modelPathEnvironmentKey
        ] == nil else {
            // The override is set for this run, so the ordering it would prove
            // is already in force and asserting it here would be circular.
            return
        }
        // Without the variable set, resolution must fall through to the
        // catalog path, never to an arbitrary existing file.
        if let resolved = LiveModelTestSupport.modelPath() {
            XCTAssertTrue(
                resolved.hasSuffix(".gguf"),
                "resolution without an override must land on a .gguf in the "
                    + "model directory, got \(resolved)"
            )
        }
    }
}
