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
        // THE ENTERPRISE UNBRICK. A firm that sets offline mode and installs a
        // model-less build has no other way to get a model, so gating the
        // import would leave that configuration permanently patterns-only with
        // no in-app remedy. The import IS the remedy.
        //
        // Asserted as an asymmetry, which is the shape that cannot pass
        // vacuously: with offline mode on, the DOWNLOAD is refused and the
        // IMPORT still installs. The precondition on canDownload is what proves
        // the offline flag in this suite is real rather than inert.
        //
        // Deliberately through a namespaced suite rather than
        // UserDefaults.standard: that domain is shared by every test process on
        // the machine (see TestHermeticityTests). The structural half of this
        // invariant, that ModelImporter cannot read the flag through any
        // channel at all, is locked by
        // testImportNeverConsultsTheDownloadHostAllowlistOrAnyURL and by
        // testTheImporterTakesNoUserDefaultsSeamAtAll below.
        let (defaults, name) = TestNamespace.defaults("import-offline-mode")
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: AISettings.offlineModeKey)
        XCTAssertTrue(
            AISettings.isOfflineMode(defaults: defaults),
            "the test would be vacuous if the flag were not set"
        )

        let fixture = try makeFixture("offline")
        XCTAssertFalse(
            AISettings.canDownload(
                fixture.quick,
                installedGB: 32,
                fileManager: fixture.fileManager,
                defaults: defaults
            ),
            "precondition: downloading IS gated by offline mode, which is why "
                + "the import must not be"
        )
        let source = try place(bytes(64 * 1024, seed: 7), named: "q.gguf", in: fixture)
        let importer = makeImporter(fixture)

        await importer.importFile(at: source)?.value

        XCTAssertEqual(
            importer.phase, .installed(tierID: "quick"),
            "offline mode must not stop a local file from being added"
        )
    }

    func testTheImporterTakesNoUserDefaultsSeamAtAll() throws {
        // The structural half of the unbrick. A gate needs a value to read, and
        // the importer has no channel to any: no UserDefaults parameter on its
        // init or on importFile, and no reference to the flag in its source.
        // Someone reaching for the "check the gate at the bottom of the stack"
        // convention in ModelInstaller.install would have to add one, and this
        // is where that shows up.
        let text = try String(
            contentsOf: Self.uiSources.appendingPathComponent("ModelImporter.swift"),
            encoding: .utf8
        )
        for symbol in ["UserDefaults", "defaults:", "offlineMode"] {
            XCTAssertFalse(
                codeLines(of: text).contains { $0.contains(symbol) },
                "\(symbol) must not reach the import path"
            )
        }
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

    func testCancellingOnTheLastChunkDoesNotCompleteTheInstall() async throws {
#if DEBUG
        // A cancel raised while the FINAL chunk is being written must not end
        // as .installed. The loop's next-iteration check is what catches this
        // one, and this test pins that: without it, a user who cancels at 99%
        // gets a completed install.
        //
        // Honest scope note: this does NOT exercise the post-loop check in
        // `copy`. That one covers the remaining window between the loop's last
        // flag read and the move into place, which is a few microseconds wide
        // and cannot be hit deterministically from a test, because the only
        // seam available fires after a chunk write. It is hardening, kept
        // because the alternative is a Cancel press that silently installs.
        let fixture = try makeFixture("cancel-tail")
        let payload = bytes(64 * 1024, seed: 7)
        let source = try place(payload, named: "q.gguf", in: fixture)
        let importer = makeImporter(fixture, chunkBytes: 4096)
        let total = Int64(payload.count)
        ModelImporter.afterChunkSeam.value = { [weak importer] written in
            guard written == total else { return }
            importer?.cancelFromWorkerForTesting()
        }

        await importer.importFile(at: source)?.value

        XCTAssertEqual(
            importer.phase, .cancelled,
            "a cancel on the last chunk must not silently complete the install"
        )
        XCTAssertFalse(ModelCatalog.isInstalled(fixture.quick, fileManager: fixture.fileManager))
        XCTAssertTrue(leftoverTempFiles(fixture).isEmpty)
#else
        throw XCTSkip("the chunk seam is compiled out of release builds")
#endif
    }

    func testProgressIsReportedOnWholePercentChangesNotOncePerChunk() async throws {
        // Every report is a main-actor hop that re-renders the shell, and the
        // Quick model is 654 chunks. A progress bar cannot show more than 100
        // steps, so the copy coalesces to whole percents. The first and last
        // updates must still arrive, or a caller watching the phase stream
        // cannot tell the copy began.
        let fixture = try makeFixture("progress-throttle")
        let payload = bytes(64 * 1024, seed: 7)
        let source = try place(payload, named: "q.gguf", in: fixture)
        // 512 byte chunks over 64 KB is 128 chunks for 100 possible percents.
        let importer = makeImporter(fixture, chunkBytes: 512)
        var copying: [Int64] = []
        let subscription = importer.$phase.sink { phase in
            if case let .copying(_, received, _) = phase { copying.append(received) }
        }
        defer { subscription.cancel() }

        await importer.importFile(at: source)?.value

        XCTAssertEqual(importer.phase, .installed(tierID: "quick"))
        XCTAssertLessThanOrEqual(
            copying.count, 101,
            "one report per whole percent at most, not one per chunk"
        )
        XCTAssertGreaterThan(copying.count, 1, "progress must actually be reported")
        XCTAssertEqual(
            copying.last, Int64(payload.count),
            "the final byte count must be reported so the bar reaches the end"
        )
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

    // MARK: - The sheet keeps the two paths visibly apart

    func testTheVerifiedAndUncheckedSectionsAreLabelledDifferently() throws {
        // Two file pickers on one sheet will be confused by someone unless the
        // difference is stated in the titles, the buttons and the consequences.
        let text = try String(
            contentsOf: Self.uiSources.appendingPathComponent("ModelManagementView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(text.contains("Already have the model file?"))
        XCTAssertTrue(text.contains("Add Model File"))
        XCTAssertTrue(
            text.contains("Use your own model, unchecked"),
            "the unchecked path must say so in its own title"
        )
        XCTAssertTrue(text.contains("Choose File"))
        XCTAssertTrue(
            text.contains("LDA does not check this file and does not copy it"),
            "the consequences of the unchecked path must be explicit"
        )
        XCTAssertFalse(
            text.contains("Use another model"),
            "the old neutral title gave no hint that the file is unchecked"
        )
    }

    func testTheVerifiedImportSectionComesBeforeTheUncheckedOne() throws {
        let text = try String(
            contentsOf: Self.uiSources.appendingPathComponent("ModelManagementView.swift"),
            encoding: .utf8
        )
        guard let verified = text.range(of: "verifiedImportSection"),
              let custom = text.range(of: "customModelSection") else {
            XCTFail("both sections must exist")
            return
        }
        XCTAssertLessThan(
            verified.lowerBound, custom.lowerBound,
            "the checked path is the one to reach for first"
        )
    }

    func testARefusalNeverPointsAtTheUncheckedPath() throws {
        // A refusal that teaches the user how to route around itself is not a
        // refusal. The unchecked section is on the same sheet for anyone who
        // genuinely wants it; the failure message must not send them there.
        for error in [
            ModelImportError.digestUnmatched,
            .sizeUnmatched(actualBytes: 10),
            .unreadable("x")
        ] {
            let message = error.localizedMessage(language: .english).lowercased()
            XCTAssertFalse(message.contains("choose file"))
            XCTAssertFalse(message.contains("use your own"))
            XCTAssertFalse(message.contains("anyway"))
        }
    }

    func testTheOfflineURLIsCopiedRatherThanOpened() throws {
        // NetworkChokepointTests gates Link( and openURL across all of Sources,
        // so this asserts the positive half: the sheet offers a copy instead.
        let text = try String(
            contentsOf: Self.uiSources.appendingPathComponent("ModelManagementView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(text.contains("NSPasteboard.general"))
        XCTAssertFalse(
            codeLines(of: text).contains { $0.contains("SensitiveClipboard") },
            "a public release URL is not client data and does not want a self-clear"
        )
    }

    func testTheImportIsNotGatedOnAScanRunningElsewhere() throws {
        // Ruled deliberately: the import writes a new file and mutates nothing
        // llama.cpp has mmapped, and the imported tier cannot become the active
        // model mid-scan because ReviewModel captures modelPath at scan start.
        let text = try String(
            contentsOf: Self.uiSources.appendingPathComponent("ModelManagementView.swift"),
            encoding: .utf8
        )
        guard let start = text.range(of: "private var verifiedImportSection") else {
            XCTFail("verifiedImportSection is missing")
            return
        }
        let body = text[start.lowerBound...].prefix(3_000)
        XCTAssertFalse(
            body.contains("isBusyElsewhere"),
            "wiring the import into isBusyElsewhere would block the one remedy "
                + "a managed offline install has"
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
