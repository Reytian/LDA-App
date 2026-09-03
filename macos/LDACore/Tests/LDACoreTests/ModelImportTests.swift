//
//  ModelImportTests.swift
//  LDACoreTests
//
//  The verified offline import: a model file the user carried over on a drive
//  is checked against the checksum published inside the signed app and copied
//  into the app container, so it behaves exactly like a download.
//
//  The invariants under test, in order of what they protect:
//    1. The BYTES decide which tier a file becomes. Not the file name, and
//       never the user, because a wrong answer attaches a tier's measured
//       memory ceiling and timing to a model they do not describe.
//    2. A file that fails either check installs nothing and modifies nothing.
//    3. The import never consults offline mode. A firm with managed offline
//       mode and a model-less build has no other way to get a model, so a gate
//       here would brick that configuration permanently.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Combine
import CryptoKit
import Foundation
import XCTest
@testable import LDAUI

@MainActor
final class ModelImportTests: XCTestCase {

    // MARK: - Fixture

    /// One import scenario: a fake Application Support container, a fixture
    /// catalog whose files are small enough to hash in a test, and a source
    /// file sitting OUTSIDE the container the way a mounted drive would.
    private struct Fixture {
        let container: URL
        let external: URL
        let fileManager: ModelContainerStub
        let catalog: ModelCatalog
        let quick: ModelTier
        let balanced: ModelTier
    }

    private var fixtures: [URL] = []

    override func tearDown() async throws {
#if DEBUG
        ModelImporter.afterChunkSeam.clear()
#endif
        for url in fixtures { try? FileManager.default.removeItem(at: url) }
        fixtures = []
        try await super.tearDown()
    }

    /// Deterministic bytes, so a digest computed here is stable across runs.
    private func bytes(_ count: Int, seed: UInt8) -> Data {
        var data = Data(capacity: count)
        var value = seed
        for _ in 0..<count {
            data.append(value)
            value = value &* 31 &+ 17
        }
        return data
    }

    private func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func tier(
        id: String,
        level: String,
        fileName: String,
        size: Int64,
        sha256: String
    ) -> ModelTier {
        ModelTier(
            id: id, level: level, displayName: id, fileName: fileName,
            sizeBytes: size, sha256: sha256, peakRSSGB: 3.6,
            secondsPerDocument: 53, architecture: "qwen35", blockCount: 32,
            embeddingLength: 2560, sourceURL: "https://example.invalid/\(fileName)"
        )
    }

    private func makeFixture(_ label: String) throws -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("lda-import-\(label)-\(UUID().uuidString)")
        let container = base.appendingPathComponent("Support", isDirectory: true)
        let external = base.appendingPathComponent("Drive", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        fixtures.append(base)

        let quickBytes = bytes(64 * 1024, seed: 7)
        let balancedBytes = bytes(96 * 1024, seed: 11)
        let quick = tier(
            id: "quick", level: "quick", fileName: "Quick-Q4_K_M.gguf",
            size: Int64(quickBytes.count), sha256: digest(of: quickBytes)
        )
        let balanced = tier(
            id: "balanced", level: "balanced", fileName: "Balanced-Q4_K_M.gguf",
            size: Int64(balancedBytes.count), sha256: digest(of: balancedBytes)
        )
        return Fixture(
            container: container,
            external: external,
            fileManager: ModelContainerStub(supportRoot: container),
            catalog: ModelCatalog(tiers: [quick, balanced]),
            quick: quick,
            balanced: balanced
        )
    }

    /// Writes a source file on the fake drive and returns its URL.
    private func place(_ data: Data, named name: String, in fixture: Fixture) throws -> URL {
        let url = fixture.external.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func makeImporter(
        _ fixture: Fixture,
        freeSpace: Int64? = nil,
        chunkBytes: Int = 4096
    ) -> ModelImporter {
        ModelImporter(
            catalog: fixture.catalog,
            fileManager: fixture.fileManager,
            freeSpaceBytes: { freeSpace ?? Int64(64) * 1_024 * 1_024 * 1_024 },
            chunkBytes: chunkBytes
        )
    }

    /// Every `.part` file currently under the fake models root.
    private func leftoverTempFiles(_ fixture: Fixture) -> [String] {
        guard let root = ModelCatalog.modelsRoot(fileManager: fixture.fileManager),
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path)
        else { return [] }
        return names.filter { $0.hasSuffix(".part") }
    }

    // MARK: - The happy path

    func testImportingAFileWhoseChecksumMatchesAQuickTierInstallsItAsThatTier() async throws {
        let fixture = try makeFixture("match")
        let payload = bytes(64 * 1024, seed: 7)
        let source = try place(payload, named: "carried-over.gguf", in: fixture)
        let importer = makeImporter(fixture)

        await importer.importFile(at: source)?.value

        XCTAssertEqual(importer.phase, .installed(tierID: "quick"))
        let installed = try XCTUnwrap(
            ModelCatalog.installedURL(for: fixture.quick, fileManager: fixture.fileManager)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path))
        XCTAssertEqual(try Data(contentsOf: installed), payload)
        XCTAssertTrue(ModelCatalog.isInstalled(fixture.quick, fileManager: fixture.fileManager))
        XCTAssertTrue(leftoverTempFiles(fixture).isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: source.path),
            "the user's own file must be copied, never moved"
        )
    }

    func testImportedModelIsIndistinguishableFromADownload() async throws {
        let fixture = try makeFixture("same-as-download")
        let source = try place(bytes(64 * 1024, seed: 7), named: "q.gguf", in: fixture)
        let (defaults, name) = TestNamespace.defaults("import-resolution")
        defer { defaults.removePersistentDomain(forName: name) }
        let importer = makeImporter(fixture)

        await importer.importFile(at: source)?.value

        let installed = try XCTUnwrap(
            ModelCatalog.installedURL(for: fixture.quick, fileManager: fixture.fileManager)
        )
        XCTAssertEqual(
            AISettings.resolveModelPath(
                defaults: defaults, catalog: fixture.catalog, fileManager: fixture.fileManager
            ),
            installed.path,
            "an imported tier must resolve exactly the way a downloaded one does"
        )
        XCTAssertFalse(
            AISettings.isModelMissing(
                defaults: defaults, catalog: fixture.catalog, fileManager: fixture.fileManager
            )
        )
        XCTAssertNil(
            defaults.string(forKey: AISettings.customModelPathKey),
            "a verified import is a tier, not a custom model path"
        )
        XCTAssertNil(
            defaults.data(forKey: AISettings.customModelBookmarkKey),
            "a file inside the container needs no security-scoped bookmark"
        )
    }

    func testImportAttributesTheTierByChecksumNotByFileName() async throws {
        // The file is named after the Balanced tier and its bytes are Quick's.
        // The bytes must win: they are what decides the redaction.
        let fixture = try makeFixture("bytes-decide")
        let source = try place(
            bytes(64 * 1024, seed: 7),
            named: fixture.balanced.fileName,
            in: fixture
        )
        let importer = makeImporter(fixture)

        await importer.importFile(at: source)?.value

        XCTAssertEqual(importer.phase, .installed(tierID: "quick"))
        XCTAssertTrue(ModelCatalog.isInstalled(fixture.quick, fileManager: fixture.fileManager))
        XCTAssertFalse(
            ModelCatalog.isInstalled(fixture.balanced, fileManager: fixture.fileManager),
            "the file name must not be able to claim a tier"
        )
    }

    // MARK: - Refusals

    func testImportRefusesAFileWithARightSizeAndWrongBytes() async throws {
        let fixture = try makeFixture("wrong-bytes")
        // Same byte count as Quick, different content.
        let source = try place(bytes(64 * 1024, seed: 200), named: "joined.gguf", in: fixture)
        let before = try Data(contentsOf: source)
        let importer = makeImporter(fixture)

        await importer.importFile(at: source)?.value

        XCTAssertEqual(importer.phase, .failed(.digestUnmatched))
        let installed = try XCTUnwrap(
            ModelCatalog.installedURL(for: fixture.quick, fileManager: fixture.fileManager)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path))
        XCTAssertTrue(leftoverTempFiles(fixture).isEmpty, "the temp file must be removed")
        XCTAssertEqual(
            try Data(contentsOf: source), before,
            "the user's source file must not be touched"
        )
    }

    func testImportRefusesAFileWhoseSizeMatchesNoTierWithoutHashingIt() async throws {
        // The size prefilter exists so a wrong file is refused in microseconds
        // rather than after streaming gigabytes. Proof that no streaming pass
        // ran: the phase never reaches .copying, which is emitted once per
        // chunk and is the only way the copy loop reports itself.
        let fixture = try makeFixture("wrong-size")
        let source = try place(bytes(1_234, seed: 3), named: "part-aa", in: fixture)
        let importer = makeImporter(fixture)
        var seen: [ModelImportPhase?] = []
        let subscription = importer.$phase.sink { seen.append($0) }
        defer { subscription.cancel() }

        await importer.importFile(at: source)?.value

        XCTAssertEqual(importer.phase, .failed(.sizeUnmatched(actualBytes: 1_234)))
        for phase in seen {
            if case .copying = phase {
                XCTFail("the copy loop ran for a file the prefilter should have refused")
            }
            if case .verifying = phase {
                XCTFail("verification ran for a file the prefilter should have refused")
            }
        }
        XCTAssertTrue(leftoverTempFiles(fixture).isEmpty)
    }

    func testImportRefusesWhenFreeSpaceIsShort() async throws {
        let fixture = try makeFixture("no-room")
        let source = try place(bytes(64 * 1024, seed: 7), named: "q.gguf", in: fixture)
        // Below size plus the 1 GB of headroom both paths require.
        let importer = makeImporter(fixture, freeSpace: 500_000_000)
        var seen: [ModelImportPhase?] = []
        let subscription = importer.$phase.sink { seen.append($0) }
        defer { subscription.cancel() }

        await importer.importFile(at: source)?.value

        guard case let .failed(.insufficientDisk(needed, free)) = importer.phase else {
            return XCTFail("expected insufficientDisk, got \(String(describing: importer.phase))")
        }
        XCTAssertEqual(free, 500_000_000)
        XCTAssertEqual(needed, Int64(64 * 1024) + 1_000_000_000)
        for phase in seen {
            if case .copying = phase {
                XCTFail("nothing may be opened when there is no room")
            }
        }
        XCTAssertTrue(leftoverTempFiles(fixture).isEmpty)
    }

    func testImportRefusesAFileThatCannotBeRead() async throws {
        let fixture = try makeFixture("unreadable")
        let missing = fixture.external.appendingPathComponent("never-written.gguf")
        let importer = makeImporter(fixture)

        await importer.importFile(at: missing)?.value

        guard case .failed(.unreadable) = importer.phase else {
            return XCTFail("expected unreadable, got \(String(describing: importer.phase))")
        }
        XCTAssertTrue(leftoverTempFiles(fixture).isEmpty)
    }

    // MARK: - The enterprise unbrick

    func testImportWorksWithOfflineModeOn() async throws {
        // A firm that sets offline mode and installs a model-less build has no
        // other way to get a model, so gating the import would leave that
        // configuration permanently patterns-only with no in-app remedy.
        //
        // The importer takes no UserDefaults at all, so the only channel by
        // which offline mode could reach it is UserDefaults.standard. This flips
        // that real key and restores it, which is why the assertion is worth the
        // intrusion: it is the one place the invariant can be observed rather
        // than merely read.
        let key = AISettings.offlineModeKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.set(true, forKey: key)
        XCTAssertTrue(AISettings.isOfflineMode(), "the test would be vacuous otherwise")

        let fixture = try makeFixture("offline")
        let source = try place(bytes(64 * 1024, seed: 7), named: "q.gguf", in: fixture)
        let importer = makeImporter(fixture)

        await importer.importFile(at: source)?.value

        XCTAssertEqual(
            importer.phase, .installed(tierID: "quick"),
            "offline mode must not stop a local file from being added"
        )
    }

    // MARK: - Cancellation and litter

    func testCancellingAnImportLeavesNothingBehind() async throws {
#if DEBUG
        let fixture = try makeFixture("cancel")
        let source = try place(bytes(64 * 1024, seed: 7), named: "q.gguf", in: fixture)
        let importer = makeImporter(fixture, chunkBytes: 4096)
        // Cancel after the first chunk, so the copy is genuinely in flight.
        // Synchronously, on the worker thread: hopping through the main actor
        // would race a copy this small and make the test flaky.
        ModelImporter.afterChunkSeam.value = { [weak importer] _ in
            importer?.cancelFromWorkerForTesting()
        }

        await importer.importFile(at: source)?.value

        XCTAssertEqual(importer.phase, .cancelled)
        XCTAssertTrue(leftoverTempFiles(fixture).isEmpty, "a cancelled copy must leave no .part")
        let installed = try XCTUnwrap(
            ModelCatalog.installedURL(for: fixture.quick, fileManager: fixture.fileManager)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path))
        XCTAssertFalse(ModelCatalog.isInstalled(fixture.quick, fileManager: fixture.fileManager))
#else
        throw XCTSkip("the chunk seam is compiled out of release builds")
#endif
    }

    func testAbandonedTempFilesAreSweptWhenTheImporterIsCreated() throws {
        // The app can be killed mid-copy. A 2.6 GB .part must not sit in the
        // container forever waiting for somebody to notice it.
        let fixture = try makeFixture("sweep")
        let root = try XCTUnwrap(ModelCatalog.modelsRoot(fileManager: fixture.fileManager))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let litter = root.appendingPathComponent(".import-abandoned.part")
        try Data("stale".utf8).write(to: litter)
        let keep = root.appendingPathComponent("keep-me.txt")
        try Data("keep".utf8).write(to: keep)

        _ = makeImporter(fixture)

        XCTAssertFalse(FileManager.default.fileExists(atPath: litter.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: keep.path),
            "the sweep must only remove its own temp files"
        )
    }

    func testASecondImportIsRefusedWhileOneIsRunning() async throws {
        let fixture = try makeFixture("one-at-a-time")
        let source = try place(bytes(64 * 1024, seed: 7), named: "q.gguf", in: fixture)
        let importer = makeImporter(fixture)

        let first = importer.importFile(at: source)
        let second = importer.importFile(at: source)
        XCTAssertNil(second, "one copy at a time, or two writers race on the same temp name")
        XCTAssertTrue(
            importer.isImporting,
            "the refusal must leave the first copy running, not replace it with a failure"
        )
        await first?.value
        XCTAssertEqual(importer.phase, .installed(tierID: "quick"))
    }

    // MARK: - Source discipline

    private static var uiSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LDAUI", isDirectory: true)
    }

    func testImportNeverConsultsTheDownloadHostAllowlistOrAnyURL() throws {
        let url = Self.uiSources.appendingPathComponent("ModelImporter.swift")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("ModelImporter.swift is missing; this check must not be skipped")
            return
        }
        for symbol in ["ModelHostAllowlist", "sourceURL", "offlineSourceURL", "isOfflineMode"] {
            XCTAssertFalse(
                codeLines(of: text).contains { $0.contains(symbol) },
                "the import path must not reference \(symbol): it makes no request, and "
                    + "an offline-mode gate here bricks a managed offline install"
            )
        }
        XCTAssertFalse(
            codeLines(of: text).contains { $0.contains("Data(contentsOf:") },
            "a 2.6 GB file must be streamed, not held in memory"
        )
        XCTAssertTrue(text.contains("FileHandle"), "the copy must stream")
    }

    func testTheOfflineSourceURLIsNeverUsedByTheInstaller() throws {
        let url = Self.uiSources.appendingPathComponent("ModelInstaller.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(
            text.contains("offlineSourceURL"),
            "the offline mirror is copyable text, never something the downloader fetches"
        )
    }

    /// Lines that are not comments, so a file may discuss an invariant it does
    /// not violate.
    private func codeLines(of text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//")
            }
    }
}
