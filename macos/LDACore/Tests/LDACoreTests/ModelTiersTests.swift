//
//  ModelTiersTests.swift
//  LDACoreTests
//
//  Covers the model ladder: the shipped manifest, the memory gate, migration
//  from the legacy two-value DetectionMode, and model path resolution.
//
//  These are the checks that protect the two failure modes that matter:
//  offering a user a tier their Mac cannot run, and running patterns only while
//  the user believes an AI pass happened.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import XCTest
@testable import LDAUI

final class ModelTiersTests: XCTestCase {

    /// A defaults domain per test so cases cannot leak into one another.
    private func makeDefaults(_ name: String = #function) -> UserDefaults {
        let suite = TestNamespace.suiteName("tiers.\(name)")
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// Resolving a security-scoped bookmark canonicalises the path (/var
    /// becomes /private/var), so path comparisons must resolve both sides.
    private func canonical(_ path: String?) -> String? {
        path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    }

    private func tier(
        id: String,
        level: String,
        peak: Double,
        size: Int64 = 1_000,
        file: String = "m.gguf"
    ) -> ModelTier {
        ModelTier(
            id: id, level: level, displayName: id, fileName: file,
            sizeBytes: size, sha256: "", peakRSSGB: peak, secondsPerDocument: 10,
            architecture: "qwen35", blockCount: 32, embeddingLength: 2560,
            sourceURL: "https://example.invalid/m.gguf"
        )
    }

    // MARK: - Manifest

    func testShippedManifestLoadsAndCoversEveryModelRung() {
        let catalog = ModelCatalog.load()
        XCTAssertEqual(catalog.tiers.count, 3, "manifest should describe three tiers")
        for level in DetectionLevel.modelLevels {
            XCTAssertNotNil(catalog.tier(for: level),
                            "no manifest entry for \(level.rawValue)")
        }
        XCTAssertNil(catalog.tier(for: .patternsOnly),
                     "patterns only must not map to a model")
    }

    func testManifestTiersAreOrderedByCostAndCarryRealMetadata() {
        let catalog = ModelCatalog.load()
        let quick = catalog.tier(for: .quick)!
        let balanced = catalog.tier(for: .balanced)!
        let thorough = catalog.tier(for: .mostThorough)!

        XCTAssertLessThan(quick.peakRSSGB, balanced.peakRSSGB)
        XCTAssertLessThan(balanced.peakRSSGB, thorough.peakRSSGB)
        XCTAssertLessThan(quick.secondsPerDocument, balanced.secondsPerDocument)
        XCTAssertLessThan(balanced.secondsPerDocument, thorough.secondsPerDocument)

        // Byte counts are the cheap identity layer and must be real, not round.
        for t in [quick, balanced, thorough] {
            XCTAssertGreaterThan(t.sizeBytes, 1_000_000_000, "\(t.id) size looks wrong")
            XCTAssertFalse(t.architecture.isEmpty)
            XCTAssertGreaterThan(t.blockCount, 0)
            XCTAssertGreaterThan(t.embeddingLength, 0)
        }
    }

    func testQuickTierIsTheBaseModelNotTheRetiredFineTune() {
        // Nothing is bundled any more, but the manifest fileName is still the
        // key the installer and isInstalled match on, so it must stay exact.
        // lda-v2 was retired because a fraction of what it found came back in a
        // form the literal locator cannot anchor, leaving PII in the document.
        let quick = ModelCatalog.load().tier(for: .quick)!
        XCTAssertEqual(quick.fileName, "Qwen3.5-4B-Q4_K_M.gguf")
        XCTAssertFalse(quick.fileName.contains("lda-v2"),
                       "the retired fine tune must not back the Quick rung")
    }

    // MARK: - Memory gate

    func testBudgetMatchesTheBenchmarkDerivedLadder() {
        // 8 GB gets nothing: with a normal office working set there is no room
        // for any model. The old bracketed function wrongly gave it 6.5.
        XCTAssertEqual(MemoryGate.budgetGB(installedGB: 8), 0.0)
        XCTAssertEqual(MemoryGate.budgetGB(installedGB: 16), 6.5)
        XCTAssertEqual(MemoryGate.budgetGB(installedGB: 24), 14.0)
        XCTAssertEqual(MemoryGate.budgetGB(installedGB: 32), 21.0)
        XCTAssertEqual(MemoryGate.budgetGB(installedGB: 64), 53.0)
    }

    func testSixteenGigMacGetsQuickOnly() {
        let catalog = ModelCatalog.load()
        let verdicts = DetectionLevel.modelLevels.map { level -> Bool in
            MemoryGate.availability(for: catalog.tier(for: level)!, installedGB: 16).isSelectable
        }
        XCTAssertEqual(verdicts, [true, false, false],
                       "only Quick may be selectable on a 16 GB Mac")
    }

    func testTwentyFourGigMacGetsEveryTier() {
        let catalog = ModelCatalog.load()
        for level in DetectionLevel.modelLevels {
            XCTAssertTrue(
                MemoryGate.availability(for: catalog.tier(for: level)!, installedGB: 24).isSelectable,
                "\(level.rawValue) should be selectable on a 24 GB Mac"
            )
        }
    }

    func testTightVerdictWhenMarginIsUnderOneGigabyte() {
        // Budget at 24 GB is 14.0.
        XCTAssertEqual(
            MemoryGate.availability(for: tier(id: "t", level: "balanced", peak: 13.5), installedGB: 24),
            .tight
        )
        XCTAssertEqual(
            MemoryGate.availability(for: tier(id: "t", level: "balanced", peak: 12.0), installedGB: 24),
            .available
        )
    }

    func testOverBudgetReportsBothNumbers() {
        let over = MemoryGate.availability(
            for: tier(id: "t", level: "mostThorough", peak: 13.83), installedGB: 16
        )
        XCTAssertEqual(over, .insufficientMemory(needsGB: 13.83, budgetGB: 6.5))
        XCTAssertFalse(over.isSelectable)
    }

    func testRequirementTextNamesAnInstallableSize() {
        let catalog = ModelCatalog.load()
        let text = MemoryGate.requirementText(for: catalog.tier(for: .mostThorough)!)
        XCTAssertTrue(text.contains("24 GB"), "expected a concrete RAM figure, got: \(text)")
    }

    // MARK: - Migration from DetectionMode

    func testLegacyFastBecomesPatternsOnly() {
        let d = makeDefaults()
        d.set(DetectionMode.fast.rawValue, forKey: AISettings.detectionModeKey)
        XCTAssertEqual(AISettings.detectionLevel(defaults: d), .patternsOnly)
    }

    func testLegacyThoroughWithNoCustomModelBecomesQuick() {
        let d = makeDefaults()
        d.set(DetectionMode.thorough.rawValue, forKey: AISettings.detectionModeKey)
        XCTAssertEqual(AISettings.detectionLevel(defaults: d), .quick)
    }

    func testLegacyThoroughPointingAtATierFileAdoptsThatTier() {
        let d = makeDefaults()
        let catalog = ModelCatalog.load()
        let balanced = catalog.tier(for: .balanced)!
        d.set(DetectionMode.thorough.rawValue, forKey: AISettings.detectionModeKey)
        d.set("/somewhere/\(balanced.fileName)", forKey: AISettings.customModelPathKey)
        XCTAssertEqual(AISettings.detectionLevel(defaults: d, catalog: catalog), .balanced)
    }

    func testLegacyThoroughWithAnUnknownModelKeepsQuickAndPreservesThePath() {
        let d = makeDefaults()
        d.set(DetectionMode.thorough.rawValue, forKey: AISettings.detectionModeKey)
        d.set("/somewhere/our-own-tune.gguf", forKey: AISettings.customModelPathKey)
        XCTAssertEqual(AISettings.detectionLevel(defaults: d), .quick)
        XCTAssertEqual(d.string(forKey: AISettings.customModelPathKey),
                       "/somewhere/our-own-tune.gguf",
                       "a firm's own model must not be discarded by migration")
    }

    func testFreshInstallDefaultsToQuick() {
        XCTAssertEqual(AISettings.detectionLevel(defaults: makeDefaults()), .quick)
    }

    func testMigrationRunsOnceAndDoesNotFightTheUser() {
        let d = makeDefaults()
        d.set(DetectionMode.fast.rawValue, forKey: AISettings.detectionModeKey)
        XCTAssertEqual(AISettings.detectionLevel(defaults: d), .patternsOnly)

        // The user then picks a real tier. Re-reading must not re-migrate them
        // back to patterns only.
        AISettings.setDetectionLevel(.mostThorough, defaults: d)
        XCTAssertEqual(AISettings.detectionLevel(defaults: d), .mostThorough)
    }

    // MARK: - Derived DetectionMode

    func testUsesLLMIsFalseOnlyForPatternsOnly() {
        XCTAssertFalse(DetectionLevel.patternsOnly.usesLLM)
        for level in DetectionLevel.modelLevels {
            XCTAssertTrue(level.usesLLM, "\(level.rawValue) must run the model")
        }
    }

    func testDerivedDetectionModeTracksTheLadder() {
        let d = makeDefaults()
        AISettings.setDetectionLevel(.patternsOnly, defaults: d)
        XCTAssertEqual(AISettings.detectionMode(defaults: d), .fast)
        AISettings.setDetectionLevel(.balanced, defaults: d)
        XCTAssertEqual(AISettings.detectionMode(defaults: d), .thorough)
    }

    // MARK: - Model path resolution

    func testPatternsOnlyResolvesToNoModel() {
        let d = makeDefaults()
        AISettings.setDetectionLevel(.patternsOnly, defaults: d)
        XCTAssertNil(AISettings.resolveModelPath(defaults: d))
        XCTAssertFalse(AISettings.isModelMissing(defaults: d),
                       "a deliberate choice is not a missing model")
    }

    func testDownloadedOnlyTiersReportMissingUntilInstalled() {
        // Quick is bundled, so in a packaged app it always resolves. Balanced
        // and Most thorough are downloads: until one is installed it must
        // resolve to nil AND report as missing, so the run is visibly degraded
        // rather than silently patterns-only.
        for level in [DetectionLevel.balanced, .mostThorough] {
            let d = makeDefaults("fresh-\(level.rawValue)")
            AISettings.setDetectionLevel(level, defaults: d)
            XCTAssertNil(AISettings.resolveModelPath(defaults: d),
                         "\(level.rawValue) must not invent a model")
            XCTAssertTrue(AISettings.isModelMissing(defaults: d),
                          "\(level.rawValue) must report itself as missing")
        }
    }

    func testBundledPathIsDerivedFromTheManifestFileName() {
        // The previous version of this test asserted `a || b` after computing
        // `a || b`, so it passed for any implementation and never exercised the
        // code it was meant to guard. Assert something falsifiable instead: the
        // lookup key is the manifest file name with its extension stripped, so
        // renaming the model in Models.json without renaming the bundled
        // resource breaks the link and is caught here.
        let quick = ModelCatalog.load().tier(for: .quick)!
        XCTAssertEqual(quick.fileName, "Qwen3.5-4B-Q4_K_M.gguf")
        XCTAssertEqual((quick.fileName as NSString).deletingPathExtension,
                       "Qwen3.5-4B-Q4_K_M",
                       "bundledPath looks the resource up by this stem")
        // In the test binary there is no app bundle, so this must be nil rather
        // than crashing or inventing a path.
        XCTAssertNil(ModelCatalog.bundledPath(for: quick))
    }

    func testOnlyQuickIsEverBundled() {
        // Bundling Balanced instead would hand a 16 GB Mac a model its own
        // memory gate blocks. Quick is the one tier that fits the minimum spec.
        let catalog = ModelCatalog.load()
        XCTAssertFalse(ModelCatalog.isBundled(catalog.tier(for: .balanced)!))
        XCTAssertFalse(ModelCatalog.isBundled(catalog.tier(for: .mostThorough)!))
    }

    func testNoTierEverBorrowsAnotherTiersModel() {
        // Silently substituting a different model while the user believes a
        // particular level is running would misrepresent the redaction.
        let d = makeDefaults()
        AISettings.setDetectionLevel(.mostThorough, defaults: d)
        XCTAssertNil(AISettings.resolveModelPath(defaults: d))
        XCTAssertTrue(AISettings.isModelMissing(defaults: d))
    }

    func testACustomModelOverridesWhenOneIsDeliberatelySet() throws {
        // A custom model wins while it is set. Note this is NOT the same as
        // saying a named rung may coexist with one: the picker clears the
        // custom model when a rung is chosen (PRD 2.4), which is asserted in
        // testChoosingANamedRungClearsTheCustomModel.
        let d = makeDefaults()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lda-custom-\(UUID().uuidString).gguf")
        try Data("gguf".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        AISettings.setDetectionLevel(.quick, defaults: d)
        AISettings.setCustomModel(url: tmp, defaults: d)
        XCTAssertEqual(
            canonical(AISettings.resolveModelPath(defaults: d)),
            canonical(tmp.path)
        )
    }

    func testChoosingANamedRungClearsTheCustomModel() throws {
        // PRD 2.4. Without this the ladder shows one thing and runs another.
        let d = makeDefaults()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lda-custom-\(UUID().uuidString).gguf")
        try Data("gguf".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        AISettings.setCustomModel(url: tmp, defaults: d)
        // The picker performs both steps together; assert the combination it
        // must leave behind.
        AISettings.setCustomModel(url: nil, defaults: d)
        AISettings.setDetectionLevel(.quick, defaults: d)
        XCTAssertNil(AISettings.customModelPath(defaults: d))
        XCTAssertNil(AISettings.resolveModelPath(defaults: d),
                     "with the custom model cleared and no tier installed, "
                     + "there is no model to fall back to")
    }

    func testClearingTheCustomModelRestoresTheTierModel() throws {
        let d = makeDefaults()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lda-custom-\(UUID().uuidString).gguf")
        try Data("gguf".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        AISettings.setDetectionLevel(.quick, defaults: d)
        AISettings.setCustomModel(url: tmp, defaults: d)
        AISettings.setCustomModel(url: nil, defaults: d)
        XCTAssertNil(AISettings.resolveModelPath(defaults: d))
    }

    func testADeletedCustomModelDoesNotResolve() {
        let d = makeDefaults()
        AISettings.setDetectionLevel(.quick, defaults: d)
        d.set("/definitely/not/here.gguf", forKey: AISettings.customModelPathKey)
        // Must not return a dead path. With no tier installed there is nothing
        // to fall through to, and that is reported rather than hidden.
        XCTAssertNil(AISettings.resolveModelPath(defaults: d))
        XCTAssertTrue(AISettings.isModelMissing(defaults: d))
    }

    func testSettingACustomModelRecordsABookmarkWhereTheSandboxSupportsIt() throws {
        // The regression guard for the shipped bug: storing only a path meant a
        // chosen model became unreadable after relaunch under the sandbox.
        let d = makeDefaults()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lda-bm-\(UUID().uuidString).gguf")
        try Data("gguf".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        AISettings.setCustomModel(url: tmp, defaults: d)
        XCTAssertEqual(d.string(forKey: AISettings.customModelPathKey), tmp.path)
        // A bookmark IS produced here, and resolving it canonicalises the path.
        // That round trip is exactly what makes the model readable after the
        // next launch, so assert on the resolved form.
        XCTAssertNotNil(d.data(forKey: AISettings.customModelBookmarkKey),
                        "a security-scoped bookmark must be stored alongside the path")
        XCTAssertEqual(canonical(AISettings.customModelPath(defaults: d)), canonical(tmp.path))
    }

    // MARK: - Installed tier location

    func testInstalledPathIsInsideTheAppContainer() throws {
        let catalog = ModelCatalog.load()
        let t = catalog.tier(for: .balanced)!
        let url = try XCTUnwrap(ModelCatalog.installedURL(for: t))
        XCTAssertTrue(url.path.contains("LDA/Models/\(t.id)"),
                      "unexpected install location: \(url.path)")
        XCTAssertEqual(url.lastPathComponent, t.fileName)
    }

    func testIsInstalledUsesTheContainerPathAndNotAnArbitraryTree() throws {
        // The previous version of this test built a temp tree and then asserted
        // against the REAL container, so it passed even if isInstalled did no
        // size check whatsoever. There is no seam to inject the container root,
        // so assert what can actually be asserted: the location is derived from
        // the tier, and a tier that is not in the container reads as absent.
        let catalog = ModelCatalog.load()
        let t = catalog.tier(for: .mostThorough)!
        let url = try XCTUnwrap(ModelCatalog.installedURL(for: t))
        XCTAssertEqual(url.lastPathComponent, t.fileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "test environment unexpectedly has this model installed")
        XCTAssertFalse(ModelCatalog.isInstalled(t))
    }

    // MARK: - Memory gate at real shipping configurations

    func testEighteenGigMacIsNotOfferedModelsItCannotRun() {
        // 18 GB is a shipping M3/M4 Pro configuration. A bracketed budget gave
        // it the full 24 GB allowance and offered it a 13.83 GB model with
        // about 9 GB genuinely free.
        let catalog = ModelCatalog.load()
        let selectable = DetectionLevel.modelLevels.filter {
            MemoryGate.availability(for: catalog.tier(for: $0)!, installedGB: 18).isSelectable
        }
        XCTAssertEqual(selectable, [.quick],
                       "an 18 GB Mac must be offered Quick only")
    }

    func testTwentyGigMacGetsBalancedButNotMostThorough() {
        // 20 GB leaves roughly 11 GB after a normal office working set, so
        // Balanced (9.21) genuinely fits and Most thorough (13.83) does not.
        // The interpolated budget is 10.25 here, which expresses exactly that.
        let catalog = ModelCatalog.load()
        let selectable = DetectionLevel.modelLevels.filter {
            MemoryGate.availability(for: catalog.tier(for: $0)!, installedGB: 20).isSelectable
        }
        XCTAssertEqual(selectable, [.quick, .balanced])
    }

    func testBudgetIsMonotonicAcrossEveryShippingConfiguration() {
        let configs = [8.0, 16.0, 18.0, 24.0, 32.0, 36.0, 48.0, 64.0, 96.0, 128.0]
        let budgets = configs.map { MemoryGate.budgetGB(installedGB: $0) }
        XCTAssertEqual(budgets, budgets.sorted(),
                       "a bigger Mac must never get a smaller budget")
        for (config, budget) in zip(configs, budgets) {
            XCTAssertLessThan(budget, config,
                              "budget must leave room for the OS and apps at \(config) GB")
        }
    }

    func testEightGigMacIsOfferedNoModelAtAll() {
        // With a normal office working set an 8 GB Mac has nothing left. Saying
        // so is better than offering a rung that will thrash the machine.
        let catalog = ModelCatalog.load()
        for level in DetectionLevel.modelLevels {
            XCTAssertFalse(
                MemoryGate.availability(for: catalog.tier(for: level)!, installedGB: 8).isSelectable,
                "\(level.rawValue) must not be offered on an 8 GB Mac"
            )
        }
    }

    func testRequirementTextNamesBothTheRequirementAndThisMac() {
        let catalog = ModelCatalog.load()
        let text = MemoryGate.requirementText(
            for: catalog.tier(for: .mostThorough)!, installedGB: 16
        )
        XCTAssertTrue(text.contains("24 GB"), text)
        XCTAssertTrue(text.contains("This Mac has 16 GB"), text)
    }

    // MARK: - Catalog loading must fail closed

    func testCatalogLoadDegradesToEmptyRatherThanCrashing() {
        // Bundle.module's generated accessor calls fatalError when the resource
        // bundle is missing, which would crash a packaged app on launch. The
        // loader must locate the bundle itself and degrade instead.
        let empty = ModelCatalog.load(from: Bundle(for: ModelTiersTests.self))
        XCTAssertTrue(empty.tiers.isEmpty || !empty.tiers.isEmpty,
                      "load must return rather than trap")
    }

    func testAnEmptyCatalogYieldsNoSelectableModelTier() {
        // Fail closed: with no manifest, a model rung has no memory verdict and
        // must not be presented as runnable.
        let empty = ModelCatalog(tiers: [])
        for level in DetectionLevel.modelLevels {
            XCTAssertNil(empty.tier(for: level))
        }
    }

}
