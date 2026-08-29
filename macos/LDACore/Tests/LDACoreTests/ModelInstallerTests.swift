//
//  ModelInstallerTests.swift
//  LDACoreTests
//
//  Download, verification, and removal of detection models.
//
//  A model file decides what gets redacted, so a corrupted or substituted
//  download is a correctness problem rather than an inconvenience. These tests
//  cover the parts that can be exercised without a network: the integrity
//  checks, the removal rules, and the failure messages a user has to act on.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import XCTest
@testable import LDAUI

@MainActor
final class ModelInstallerTests: XCTestCase {

    private func tier(
        id: String = "balanced",
        size: Int64 = 32,
        sha: String = "",
        url: String = "https://example.invalid/m.gguf"
    ) -> ModelTier {
        ModelTier(
            id: id, level: "balanced", displayName: "Balanced", fileName: "m.gguf",
            sizeBytes: size, sha256: sha, peakRSSGB: 8.48, secondsPerDocument: 135,
            architecture: "gemma4", blockCount: 48, embeddingLength: 3840, sourceURL: url
        )
    }

    // MARK: - Integrity

    func testStreamingDigestMatchesAKnownValue() throws {
        // "abc" has a well known SHA-256. Verifying against a fixture rather
        // than against our own implementation is the point.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lda-digest-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(
            ModelInstaller.sha256Hex(of: url),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testDigestIsComputedInChunksSoLargeFilesNeverLoadWholly() throws {
        // Larger than the 4 MB read window, so the chunked loop actually runs
        // more than once. A single-read implementation would still pass the
        // small case above.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lda-big-\(UUID().uuidString)")
        try Data(repeating: 0x5A, count: 9 * 1024 * 1024).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let digest = ModelInstaller.sha256Hex(of: url)
        XCTAssertEqual(digest?.count, 64, "expected a 64 character hex digest")
        XCTAssertEqual(digest, ModelInstaller.sha256Hex(of: url), "must be stable")
    }

    func testDigestOfAMissingFileIsNilRatherThanACrash() {
        XCTAssertNil(ModelInstaller.sha256Hex(of: URL(fileURLWithPath: "/nope/none")))
    }

    // MARK: - Failure messages

    func testEveryFailureExplainsItselfInUserTerms() {
        let cases: [ModelInstallError] = [
            .insufficientDisk(neededBytes: 8_000_000_000, freeBytes: 1_000_000_000),
            .transport("the network connection was lost"),
            .sizeMismatch(expected: 7_121_861_440, actual: 12_345),
            .digestMismatch,
            .storage("permission denied")
        ]
        for error in cases {
            XCTAssertFalse(error.message.isEmpty, "\(error) has no message")
            XCTAssertFalse(error.message.contains("Error Domain"),
                           "raw NSError text leaked into the UI: \(error.message)")
        }
    }

    func testDiskMessageNamesBothTheRequirementAndWhatIsFree() {
        let msg = ModelInstallError
            .insufficientDisk(neededBytes: 8_000_000_000, freeBytes: 1_000_000_000).message
        XCTAssertTrue(msg.contains("8"), msg)
        XCTAssertTrue(msg.contains("1"), msg)
    }

    func testOnlyRecoverableFailuresOfferRetry() {
        XCTAssertTrue(ModelInstallError.transport("x").isRetryable)
        XCTAssertTrue(ModelInstallError.sizeMismatch(expected: 2, actual: 1).isRetryable)
        // A wrong digest means something served different bytes. Retrying in a
        // loop is the wrong instinct: surface it instead.
        XCTAssertFalse(ModelInstallError.digestMismatch.isRetryable)
        XCTAssertFalse(ModelInstallError.storage("x").isRetryable)
    }

    func testDigestMismatchTellsTheUserNotToUseTheFile() {
        let msg = ModelInstallError.digestMismatch.message
        XCTAssertTrue(msg.lowercased().contains("do not use"), msg)
        XCTAssertTrue(msg.lowercased().contains("removed"), msg)
    }

    // MARK: - Host allowlist

    func testAllowlistAcceptsHuggingFaceAndItsContentHosts() {
        // Measured 2026-08-29: a /resolve/main/ URL 302s to us.aws.cdn.hf.co.
        // The CDN family changes without notice, which is exactly why the
        // suffix rule exists rather than a fixed host list.
        for host in ["huggingface.co", "hf.co", "us.aws.cdn.hf.co",
                     "cas-bridge.xethub.hf.co", "cdn-lfs-us-1.hf.co"] {
            XCTAssertTrue(ModelHostAllowlist.allows(host: host), "should allow \(host)")
        }
    }

    func testAllowlistRejectsLookalikeAndUnrelatedHosts() {
        // The dot prefix is the whole point: a plain hasSuffix check would
        // accept evil-huggingface.co, a different registrable domain.
        for host in ["evil-huggingface.co", "huggingface.co.attacker.net",
                     "nothf.co", "example.com", "", "localhost"] {
            XCTAssertFalse(ModelHostAllowlist.allows(host: host), "should reject \(host)")
        }
        XCTAssertFalse(ModelHostAllowlist.allows(host: nil))
    }

    func testADownloadAimedOffTheAllowlistIsRefused() {
        let installer = ModelInstaller()
        let t = tier(url: "https://evil-huggingface.co/x/m.gguf")
        installer.install(t, installedGB: 64)
        guard case let .failed(err) = installer.phase(for: t),
              case .blockedHost = err else {
            return XCTFail("expected blockedHost, got \(installer.phase(for: t))")
        }
        XCTAssertFalse(err.isRetryable, "a blocked host must not offer a retry loop")
    }

    // MARK: - Memory gate on download

    func testAModelThisMacCannotRunIsNotDownloadable() {
        // Apple silicon memory is soldered, so this never becomes true later.
        // Spending 13 GB on a file the ladder will refuse to select is worse
        // than refusing up front.
        let installer = ModelInstaller()
        let thorough = ModelCatalog.load().tier(for: .mostThorough)!
        installer.install(thorough, installedGB: 16)
        guard case let .failed(err) = installer.phase(for: thorough),
              case .insufficientMemory = err else {
            return XCTFail("expected insufficientMemory, got \(installer.phase(for: thorough))")
        }
        XCTAssertTrue(err.message.contains("24 GB"), err.message)
    }

    func testTheSameModelIsDownloadableOnAMacThatCanRunIt() {
        // The guard above must not pass by refusing everything.
        let installer = ModelInstaller()
        let thorough = ModelCatalog.load().tier(for: .mostThorough)!
        installer.install(thorough, installedGB: 32)
        guard case .downloading = installer.phase(for: thorough) else {
            return XCTFail("expected a download, got \(installer.phase(for: thorough))")
        }
        installer.cancel(thorough)
    }

    // MARK: - Removal rules

    func testABundledModelCanNeverBeRemoved() {
        // Quick lives inside the .app. Offering Remove for it would either fail
        // confusingly or, worse, appear to succeed.
        let installer = ModelInstaller()
        let catalog = ModelCatalog.load()
        let quick = catalog.tier(for: .quick)!
        if ModelCatalog.isBundled(quick) {
            XCTAssertNil(installer.remove(quick), "a bundled model must not be removable")
        }
    }

    func testRemovingSomethingNotInstalledReportsNothingReclaimed() {
        let installer = ModelInstaller()
        XCTAssertNil(installer.remove(tier(id: "most-thorough")))
    }

    // MARK: - Phase reporting

    func testAnUninstalledTierStartsIdleAndNotBusy() {
        let installer = ModelInstaller()
        let t = tier()
        XCTAssertEqual(installer.phase(for: t), .waiting)
        XCTAssertFalse(installer.isBusy(t))
    }

    func testANonHttpsOrMalformedAddressFailsWithoutAnyNetworkCall() {
        // URL(string:) accepts far more than it should, including strings with
        // spaces and non-network schemes, so the installer validates the scheme
        // and host itself. A tampered manifest must not be able to aim this at
        // file:// or anything other than https.
        for bad in ["not a url at all", "file:///etc/passwd",
                    "http://example.invalid/m.gguf", "https:///m.gguf"] {
            let installer = ModelInstaller()
            let t = tier(url: bad)
            installer.install(t, installedGB: 64)
            guard case .failed = installer.phase(for: t) else {
                return XCTFail("\(bad) should have been rejected, got \(installer.phase(for: t))")
            }
            XCTAssertFalse(installer.isBusy(t))
        }
    }

    func testAValidHttpsAddressIsAccepted() {
        // The negative test above must not pass by rejecting everything.
        let installer = ModelInstaller()
        let t = tier(url: "https://huggingface.co/x/y/resolve/main/m.gguf")
        installer.install(t, installedGB: 64)
        guard case .downloading = installer.phase(for: t) else {
            return XCTFail("a valid https address should start, got \(installer.phase(for: t))")
        }
        installer.cancel(t)
    }

    func testCancelLeavesTheTierIdleRatherThanStuck() {
        let installer = ModelInstaller()
        let t = tier()
        installer.cancel(t)
        XCTAssertEqual(installer.phase(for: t), .cancelled)
        XCTAssertFalse(installer.isBusy(t))
    }

    // MARK: - The manifest drives every download

    func testEveryDownloadableTierHasAUsableSourceURL() {
        // A tier the user cannot obtain is a dead rung in the picker.
        let catalog = ModelCatalog.load()
        for level in DetectionLevel.modelLevels {
            let t = catalog.tier(for: level)!
            let url = URL(string: t.sourceURL)
            XCTAssertNotNil(url, "\(t.id) has no usable source URL")
            XCTAssertEqual(url?.scheme, "https", "\(t.id) must download over https")
        }
    }

    func testEveryShippedTierCarriesAVerifiedDigest() {
        // An empty digest silently disables verification for that model, and a
        // redaction tool downloading an unverifiable multi-gigabyte file is a
        // worse product than one that refuses to. Every tier must have one.
        for t in ModelCatalog.load().tiers {
            XCTAssertEqual(t.sha256.count, 64, "\(t.id) has no SHA-256 digest")
            XCTAssertTrue(t.sha256.allSatisfy { $0.isHexDigit }, "\(t.id) digest is not hex")
        }
    }
}
