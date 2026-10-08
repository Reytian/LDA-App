//
//  LDAV4SettingsTests.swift
//  LDACoreTests
//
//  LDA V4 on the detection ladder. It is the default rung wherever the build
//  carries the model; it resolves to the model folder inside the app; a user
//  stuck on a downloadable rung with no file is moved to it once; a working
//  choice, a custom model and a deliberate Patterns only are left alone; and
//  the Fill flow, which needs a generative model, never receives it.
//
//  The bundled folder is injected through the `builtIn` parameters. Under
//  test Bundle.main is the XCTest runner, which carries no model, so every
//  existing test keeps its model-less defaults.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

final class LDAV4SettingsTests: XCTestCase {

    private let builtIn = "/Applications/LDA.app/Contents/Resources/LDA-V4"

    private func makeDefaults(_ name: String = #function) -> UserDefaults {
        let suite = TestNamespace.suiteName("ldav4.\(name)")
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func tier(id: String, level: String, file: String) -> ModelTier {
        ModelTier(
            id: id, level: level, displayName: id, fileName: file,
            sizeBytes: 16, sha256: "aa", peakRSSGB: 3.6, secondsPerDocument: 10,
            architecture: "qwen35", blockCount: 32, embeddingLength: 2560,
            sourceURL: "https://example.invalid/m.gguf"
        )
    }

    private func smallCatalog() -> ModelCatalog {
        ModelCatalog(tiers: [
            tier(id: "quick", level: "quick", file: "q.gguf"),
            tier(id: "balanced", level: "balanced", file: "b.gguf"),
            tier(id: "most-thorough", level: "mostThorough", file: "t.gguf")
        ])
    }

    private func container(_ label: String) throws -> (ModelContainerStub, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lda-v4-settings-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (ModelContainerStub(supportRoot: root), root)
    }

    private func place(_ tier: ModelTier, using stub: ModelContainerStub) throws {
        let url = try XCTUnwrap(ModelCatalog.installedURL(for: tier, fileManager: stub))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(count: Int(tier.sizeBytes)).write(to: url)
    }

    // MARK: - The ladder

    func testLDAV4IsARungButNotADownloadableTier() {
        XCTAssertEqual(DetectionLevel.allCases.first, .patternsOnly)
        XCTAssertEqual(DetectionLevel.allCases.dropFirst().first, .ldaV4, "listed right after Patterns only")
        XCTAssertFalse(DetectionLevel.modelLevels.contains(.ldaV4))
        XCTAssertNil(DetectionLevel.ldaV4.tierID)
        XCTAssertTrue(DetectionLevel.ldaV4.usesLLM, "it runs a model, so a missing one is reported")
        XCTAssertEqual(DetectionLevel.ldaV4.displayName, "LDA V4")
    }

    func testTheXCTestRunnerCarriesNoBundledModel() {
        XCTAssertNil(ModelCatalog.ldaV4Path(), "tests must not depend on a model next to the runner")
        XCTAssertNil(ModelCatalog.ldaV4SizeDescription(), "no size is shown for a model the build lacks")
    }

    // MARK: - Default and resolution

    func testAFreshInstallDefaultsToLDAV4WhenTheBuildCarriesIt() {
        let d = makeDefaults()
        XCTAssertEqual(AISettings.defaultLevel(builtIn: builtIn), .ldaV4)
        XCTAssertEqual(AISettings.detectionLevel(defaults: d, catalog: smallCatalog(), builtIn: builtIn), .ldaV4)
        XCTAssertEqual(
            AISettings.resolveModelPath(defaults: d, catalog: smallCatalog(), builtIn: builtIn),
            builtIn
        )
        XCTAssertFalse(AISettings.isModelMissing(defaults: d, catalog: smallCatalog(), builtIn: builtIn))
    }

    func testWithoutTheModelTheDefaultStaysQuick() {
        let d = makeDefaults()
        XCTAssertEqual(AISettings.defaultLevel(builtIn: nil), .quick)
        XCTAssertEqual(AISettings.detectionLevel(defaults: d, catalog: smallCatalog(), builtIn: nil), .quick)
    }

    func testAStoredLDAV4WithoutTheModelIsReportedMissing() {
        let d = makeDefaults()
        AISettings.setDetectionLevel(.ldaV4, defaults: d)
        XCTAssertNil(AISettings.resolveModelPath(defaults: d, catalog: smallCatalog(), builtIn: nil))
        XCTAssertTrue(
            AISettings.isModelMissing(defaults: d, catalog: smallCatalog(), builtIn: nil),
            "a rung that wants a model it cannot find must say so, never run as patterns only"
        )
    }

    func testACustomModelStillOverridesTheSelectedRung() throws {
        let (_, root) = try container("custom")
        defer { try? FileManager.default.removeItem(at: root) }
        let d = makeDefaults()
        let file = root.appendingPathComponent("firm-fine-tune.gguf")
        try Data("gguf".utf8).write(to: file)
        AISettings.setDetectionLevel(.ldaV4, defaults: d)
        AISettings.setCustomModel(url: file, defaults: d)
        defer { AISettings.setCustomModel(url: nil, defaults: d) }
        let resolved = AISettings.resolveModelPath(defaults: d, catalog: smallCatalog(), builtIn: builtIn)
        XCTAssertEqual(
            resolved.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            file.resolvingSymlinksInPath().path
        )
    }

    func testABuildWithTheModelAlwaysHasAModel() throws {
        let (stub, root) = try container("any")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(AISettings.hasAnyModelAvailable(
            catalog: smallCatalog(), fileManager: stub, defaults: makeDefaults(), builtIn: builtIn
        ))
        XCTAssertFalse(AISettings.hasAnyModelAvailable(
            catalog: smallCatalog(), fileManager: stub, defaults: makeDefaults(), builtIn: nil
        ))
    }

    func testLDAV4IsTheFloorWhenNoDownloadedTierRemains() throws {
        let (stub, root) = try container("floor")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(
            AISettings.bestAvailableLevel(catalog: smallCatalog(), installedGB: 16, fileManager: stub, builtIn: builtIn),
            .ldaV4
        )
        XCTAssertEqual(
            AISettings.bestAvailableLevel(
                catalog: smallCatalog(), installedGB: 16, fileManager: stub, notAbove: .quick, builtIn: builtIn
            ),
            .ldaV4,
            "removing Quick falls back to the model that comes with the app"
        )
        XCTAssertEqual(
            AISettings.bestAvailableLevel(catalog: smallCatalog(), installedGB: 16, fileManager: stub, builtIn: nil),
            .patternsOnly
        )
    }

    // MARK: - One-time move

    func testQuickIsNotADetectionLevelWhereLDAV4Ships() {
        XCTAssertEqual(
            DetectionLevel.detectionRungs(builtIn: builtIn),
            [.patternsOnly, .ldaV4, .balanced, .mostThorough]
        )
        XCTAssertEqual(
            DetectionLevel.detectionRungs(builtIn: nil),
            [.patternsOnly, .quick, .balanced, .mostThorough],
            "a build without LDA V4 keeps the earlier ladder"
        )
        XCTAssertTrue(DetectionLevel.modelLevels.contains(.quick), "Quick stays a download, for Fill")
    }

    func testAStoredQuickReadsAsLDAV4() throws {
        let (stub, root) = try container("quick-read")
        defer { try? FileManager.default.removeItem(at: root) }
        let d = makeDefaults()
        let catalog = smallCatalog()
        try place(catalog.tier(id: "quick")!, using: stub)
        AISettings.setDetectionLevel(.quick, defaults: d)
        XCTAssertEqual(
            AISettings.detectionLevel(defaults: d, catalog: catalog, builtIn: builtIn, fileManager: stub),
            .ldaV4,
            "even with Quick downloaded, detection runs LDA V4"
        )
        // Written again by any path, Quick still reads as LDA V4.
        AISettings.setDetectionLevel(.quick, defaults: d)
        XCTAssertEqual(
            AISettings.detectionLevel(defaults: d, catalog: catalog, builtIn: builtIn, fileManager: stub),
            .ldaV4
        )
        XCTAssertEqual(
            AISettings.detectionLevel(defaults: d, catalog: catalog, builtIn: nil, fileManager: stub),
            .quick,
            "a build without LDA V4 still runs Quick"
        )
    }

    func testADownloadedQuickStaysForFill() throws {
        let (stub, root) = try container("quick-fill")
        defer { try? FileManager.default.removeItem(at: root) }
        let d = makeDefaults()
        let catalog = smallCatalog()
        try place(catalog.tier(id: "quick")!, using: stub)
        AISettings.setDetectionLevel(.quick, defaults: d)
        let quick = try XCTUnwrap(ModelCatalog.installedURL(for: catalog.tier(id: "quick")!, fileManager: stub))
        XCTAssertEqual(
            AISettings.resolveModelPath(defaults: d, catalog: catalog, fileManager: stub, builtIn: builtIn),
            builtIn
        )
        XCTAssertEqual(
            AISettings.resolveFillModelPath(defaults: d, catalog: catalog, fileManager: stub, builtIn: builtIn),
            quick.path
        )
    }

    func testALargerRungWithNoFileMovesToLDAV4Once() throws {
        let (stub, root) = try container("move")
        defer { try? FileManager.default.removeItem(at: root) }
        let d = makeDefaults()
        AISettings.setDetectionLevel(.balanced, defaults: d)
        XCTAssertEqual(
            AISettings.detectionLevel(defaults: d, catalog: smallCatalog(), builtIn: builtIn, fileManager: stub),
            .ldaV4
        )
        // Choosing Balanced again afterwards is honoured: the move runs once.
        AISettings.setDetectionLevel(.balanced, defaults: d)
        XCTAssertEqual(
            AISettings.detectionLevel(defaults: d, catalog: smallCatalog(), builtIn: builtIn, fileManager: stub),
            .balanced
        )
    }

    func testAWorkingRungIsLeftAlone() throws {
        let (stub, root) = try container("working")
        defer { try? FileManager.default.removeItem(at: root) }
        let d = makeDefaults()
        let catalog = smallCatalog()
        try place(catalog.tier(id: "balanced")!, using: stub)
        AISettings.setDetectionLevel(.balanced, defaults: d)
        XCTAssertEqual(
            AISettings.detectionLevel(defaults: d, catalog: catalog, builtIn: builtIn, fileManager: stub),
            .balanced
        )
    }

    func testPatternsOnlyIsLeftAlone() throws {
        let (stub, root) = try container("patterns")
        defer { try? FileManager.default.removeItem(at: root) }
        let d = makeDefaults()
        AISettings.setDetectionLevel(.patternsOnly, defaults: d)
        XCTAssertEqual(
            AISettings.detectionLevel(defaults: d, catalog: smallCatalog(), builtIn: builtIn, fileManager: stub),
            .patternsOnly
        )
    }

    func testABuildWithoutTheModelDoesNotUseUpTheMove() throws {
        let (stub, root) = try container("deferred")
        defer { try? FileManager.default.removeItem(at: root) }
        let d = makeDefaults()
        AISettings.setDetectionLevel(.balanced, defaults: d)
        _ = AISettings.detectionLevel(defaults: d, catalog: smallCatalog(), builtIn: nil, fileManager: stub)
        XCTAssertFalse(d.bool(forKey: AISettings.ldaV4MigratedKey))
        XCTAssertEqual(
            AISettings.detectionLevel(defaults: d, catalog: smallCatalog(), builtIn: builtIn, fileManager: stub),
            .ldaV4
        )
    }

    // MARK: - Fill

    func testFillNeverReceivesTheTagger() throws {
        let (stub, root) = try container("fill")
        defer { try? FileManager.default.removeItem(at: root) }
        let d = makeDefaults()
        let catalog = smallCatalog()
        AISettings.setDetectionLevel(.ldaV4, defaults: d)
        XCTAssertNil(
            AISettings.resolveFillModelPath(defaults: d, catalog: catalog, fileManager: stub, builtIn: builtIn),
            "with no downloaded tier, Fill asks for a model rather than receiving LDA V4"
        )

        try place(catalog.tier(id: "quick")!, using: stub)
        let quick = try XCTUnwrap(ModelCatalog.installedURL(for: catalog.tier(id: "quick")!, fileManager: stub))
        XCTAssertEqual(
            AISettings.resolveFillModelPath(defaults: d, catalog: catalog, fileManager: stub, builtIn: builtIn),
            quick.path,
            "with LDA V4 selected, Fill uses the downloaded tier"
        )
    }

    func testFillFollowsDetectionOnADownloadableRung() throws {
        let (stub, root) = try container("fill-tier")
        defer { try? FileManager.default.removeItem(at: root) }
        let d = makeDefaults()
        let catalog = smallCatalog()
        try place(catalog.tier(id: "balanced")!, using: stub)
        AISettings.setDetectionLevel(.balanced, defaults: d)
        XCTAssertEqual(
            AISettings.resolveFillModelPath(defaults: d, catalog: catalog, fileManager: stub, builtIn: builtIn),
            AISettings.resolveModelPath(defaults: d, catalog: catalog, fileManager: stub, builtIn: builtIn)
        )
    }
}
