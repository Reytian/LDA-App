//
//  WorkspaceSessionTests.swift
//  LDACoreTests
//
//  The portable workspace at the session layer: saving a live matter to one
//  file, and rebuilding it somewhere else.
//
//  The centerpiece is testAWorkspaceRebuildsTheWholeMatterOnAnotherMac, which
//  hands the file to a SECOND session over a different defaults suite and
//  different store roots. That is what "hand it to a colleague" means, and it
//  is the only arrangement that can catch a restore path quietly leaning on
//  state the sending Mac happened to have.
//
//  Hermetic throughout: temp-rooted encrypted stores with passphrase
//  protection, per-test UserDefaults suites, and test-only store base keys, so
//  the developer machine's production vault accounts are never touched.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

@MainActor
final class WorkspaceSessionTests: XCTestCase {

    private static let createdAt = "2026-08-31T09:00:00Z"
    private static let passphrase = "a shared passphrase for the handoff"
    private static let matterLabel = "Nantong Textile v. Zhang"
    private static let suppressedTerm = "Ministry of Commerce"
    private static let overriddenSurface = "Acme Trading Ltd."
    private static let overrideReplacement = "Zenith Holdings"

    private var workDir: URL!
    private var suiteNames: [String] = []
    private var usedStorageKeys: Set<String> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        ImportLimits.archiveBudgetSeam.clear()
        ZipImporter.cleanUpAllExpansions()
        for name in suiteNames {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        suiteNames = []
        for key in usedStorageKeys {
            LocalDataVault.deleteKey(account: "store.\(key)")
        }
        usedStorageKeys = []
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    // MARK: - Fixture

    /// One fully hermetic session plus the layers it was wired with. Two
    /// fixtures never share a defaults suite, a store root, or a base key, so
    /// a second fixture is a different Mac in every way that matters.
    private struct Fixture {
        let session: SessionModel
        let learning: LearningStore
        let patterns: CustomPatternStore
        let suite: UserDefaults
        let learnedBase: String
        let patternBase: String
    }

    private func makeFixture(_ name: String) -> Fixture {
        let suiteName = "WorkspaceSessionTests-\(name)-\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let suite = UserDefaults(suiteName: suiteName)!
        let learnedBase = "workspace-test-\(name).learnedTerms"
        let patternBase = "workspace-test-\(name).customPatterns"
        usedStorageKeys.formUnion([learnedBase, patternBase])

        let root = workDir.appendingPathComponent(name, isDirectory: true)
        let session = SessionModel(
            makeModel: {
                let model = ReviewModel(modelPath: nil)
                model.useLLM = false
                return model
            },
            clientStore: { try ClientMappingStore(rootDirectory: root.appendingPathComponent("clients")) }
        )
        session.clientProtection = { _ in .passphrase("pw") }
        session.recordStore = { try SessionRecordStore(rootDirectory: root.appendingPathComponent("records")) }
        session.recordProtection = { .passphrase("pw") }
        session.matterStore = { try MatterMetadataStore(rootDirectory: root.appendingPathComponent("matters")) }
        session.matterProtection = { .passphrase("pw") }
        let parkedURL = root.appendingPathComponent("parked.ldamap")
        session.parkedMappingURL = { parkedURL }
        session.parkedProtection = { .passphrase("parked-pw") }
        session.outputStyleProvider = { .pseudonym }
        session.appVersionProvider = { "1.0" }
        session.scopeDefaults = { suite }
        session.makeMatterLearningStore = { [weak self] id in
            self?.trackMatterKey(id, base: learnedBase)
            return LearningStore(scope: .matter(id: id), defaults: suite, baseKey: learnedBase)
        }
        session.makeMatterPatternStore = { [weak self] id in
            self?.trackMatterKey(id, base: patternBase)
            return CustomPatternStore(scope: .matter(id: id), defaults: suite, baseKey: patternBase)
        }

        let learning = LearningStore(defaults: suite, storageKey: learnedBase)
        let patterns = CustomPatternStore(defaults: suite, storageKey: patternBase)
        session.attachStores(learning: learning, patterns: patterns)
        return Fixture(
            session: session,
            learning: learning,
            patterns: patterns,
            suite: suite,
            learnedBase: learnedBase,
            patternBase: patternBase
        )
    }

    private func trackMatterKey(_ id: UUID, base: String) {
        usedStorageKeys.insert(StoreScope.matter(id: id).storageKey(base: base))
    }

    private func write(_ name: String, _ content: String) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    /// A session holding two documents under a matter, fully reviewed: one
    /// manual entity, one pseudonym override, one matter-layer suppression,
    /// and a built session mapping.
    private func makeReviewedSession() async throws -> (
        fixture: Fixture,
        sources: [URL],
        handoff: String
    ) {
        let fixture = makeFixture("origin")
        let session = fixture.session
        let first = try write(
            "ZhangWeiming-notice.txt",
            "Mail john@acme.com about \(Self.overriddenSurface) before Friday."
        )
        let second = try write("exhibit-b.txt", "Also reachable at mary@beta.io.")

        _ = try session.selectMatter(Self.matterLabel)
        try session.setScopeLearnedRulesToMatter(true)
        session.scopedLearningStore?.record(
            accepted: [],
            rejected: [(value: Self.suppressedTerm, type: .company)],
            to: .matter
        )

        await session.addDocuments([first, second])
        await session.anonymizeAll()
        XCTAssertEqual(
            session.entries[0].model.addManualEntity(text: Self.overriddenSurface, type: .company),
            1
        )
        // Reject one detection so the restore has a false to carry, not only trues.
        let secondModel = session.entries[1].model
        if let id = secondModel.entities.first?.id {
            secondModel.setAccepted(id, false)
        }
        try session.setPseudonymOverride(
            surface: Self.overriddenSurface,
            replacement: Self.overrideReplacement
        )
        let handoff = try XCTUnwrap(session.buildHandToAI(createdAtISO8601: Self.createdAt))
        return (fixture, [first, second], handoff.combined)
    }

    // MARK: - The handoff

    func testAWorkspaceRebuildsTheWholeMatterOnAnotherMac() async throws {
        let (origin, sources, handoff) = try await makeReviewedSession()
        let expected = origin.session.entries.map { entry in
            (
                name: entry.name,
                entities: entry.model.entities.map { ($0.span, $0.accepted) }
            )
        }
        let fileURL = workDir.appendingPathComponent("matter.ldawork")
        try origin.session.saveWorkspace(
            to: fileURL,
            passphrase: Self.passphrase,
            createdAtISO8601: Self.createdAt
        )

        // A different Mac: its own defaults suite, its own store roots, its own
        // store base keys. It has never heard of this matter.
        let colleague = makeFixture("colleague")
        let summary = try await colleague.session.openWorkspace(
            at: fileURL,
            passphrase: Self.passphrase
        )

        XCTAssertEqual(summary.warnings, [], "a clean handoff warned about something")
        XCTAssertEqual(summary.documentCount, 2)
        XCTAssertEqual(summary.matterLabel, Self.matterLabel)
        XCTAssertEqual(colleague.session.clientLabel, Self.matterLabel)

        // Originals come back byte identical, under their own names.
        XCTAssertEqual(colleague.session.entries.map(\.name), expected.map(\.name))
        for (index, source) in sources.enumerated() {
            let restored = colleague.session.entries[index].url
            XCTAssertEqual(try Data(contentsOf: restored), try Data(contentsOf: source))
        }

        // Every decision, without a detection pass: the colleague has no model.
        for (index, document) in expected.enumerated() {
            let model = colleague.session.entries[index].model
            XCTAssertTrue(model.canExport, "\(document.name) did not restore to the reviewed state")
            XCTAssertEqual(model.entities.count, document.entities.count)
            for (offset, entity) in model.entities.enumerated() {
                XCTAssertEqual(entity.span, document.entities[offset].0)
                XCTAssertEqual(entity.accepted, document.entities[offset].1)
            }
        }
        XCTAssertTrue(
            colleague.session.entries[0].model.entities.contains {
                $0.span.text == Self.overriddenSurface && $0.span.source == .manual
            },
            "the manual entity did not travel"
        )

        // The override is present and still in force on a fresh build.
        XCTAssertEqual(
            colleague.session.pseudonymOverrides[Self.overriddenSurface],
            Self.overrideReplacement
        )
        let rebuilt = try XCTUnwrap(
            colleague.session.buildHandToAI(createdAtISO8601: Self.createdAt)
        )
        XCTAssertTrue(rebuilt.combined.contains(Self.overrideReplacement))
        XCTAssertFalse(rebuilt.combined.contains(Self.overriddenSurface))

        // The matter's learned rules apply on the receiving Mac, scoped to the
        // matter layer that was minted from the archived id.
        XCTAssertNotNil(colleague.session.matterScopeID)
        XCTAssertTrue(colleague.session.scopeLearnedRulesToMatter)
        XCTAssertTrue(
            colleague.session.scopedLearningStore?.suppressKeys.contains(
                LearningStore.key(value: Self.suppressedTerm, type: .company)
            ) == true,
            "the matter-layer suppression did not travel"
        )
        XCTAssertTrue(
            colleague.learning.terms.isEmpty,
            "matter rules leaked into the receiving Mac's global layer"
        )
    }

    func testTheRestoredMappingRestoresThePastedOutput() async throws {
        let (origin, _, handoff) = try await makeReviewedSession()
        let fileURL = workDir.appendingPathComponent("matter.ldawork")
        try origin.session.saveWorkspace(
            to: fileURL,
            passphrase: Self.passphrase,
            createdAtISO8601: Self.createdAt
        )

        let colleague = makeFixture("colleague")
        _ = try await colleague.session.openWorkspace(at: fileURL, passphrase: Self.passphrase)

        // The AI's reply, pasted on the receiving Mac, restores immediately:
        // the session mapping travelled with the workspace.
        let restored = try XCTUnwrap(colleague.session.restorePasted(handoff))
        XCTAssertGreaterThan(restored.restoredCount, 0)
        XCTAssertTrue(restored.text.contains("john@acme.com"))
        XCTAssertTrue(restored.text.contains(Self.overriddenSurface))
    }

    // MARK: - What must not travel

    func testTheGlobalRuleLayersNeverEnterTheArchive() async throws {
        let (origin, _, _) = try await makeReviewedSession()
        origin.learning.record(
            accepted: [(value: "Global Client Co.", type: .company)],
            rejected: []
        )
        origin.patterns.patterns = [CustomPattern(text: "Global Vocabulary", type: .company)]

        let payload = origin.session.buildWorkspacePayload(createdAtISO8601: Self.createdAt)

        let terms = try XCTUnwrap(payload.matterLearnedTermsJSON)
        let patterns = try XCTUnwrap(payload.matterCustomPatternsJSON)
        // The global layers are the user's habits across every client they have
        // ever worked on. Shipping them in a file handed to a colleague would
        // be a de facto client list.
        XCTAssertNil(terms.range(of: Data("Global Client Co.".utf8)))
        XCTAssertNil(patterns.range(of: Data("Global Vocabulary".utf8)))
        XCTAssertNotNil(terms.range(of: Data(Self.suppressedTerm.utf8)))
    }

    func testAWorkspaceWithoutAMatterCarriesNoRuleLayers() async throws {
        let fixture = makeFixture("origin")
        let doc = try write("plain.txt", "Mail john@acme.com.")
        await fixture.session.addDocuments([doc])
        fixture.learning.record(accepted: [(value: "Global Co.", type: .company)], rejected: [])

        let payload = fixture.session.buildWorkspacePayload(createdAtISO8601: Self.createdAt)

        XCTAssertNil(payload.manifest.matterLabel)
        XCTAssertNil(payload.matterLearnedTermsJSON)
        XCTAssertNil(payload.matterCustomPatternsJSON)
    }

    func testAnUnscannedDocumentCarriesNoReviewSnapshot() async throws {
        let fixture = makeFixture("origin")
        let scanned = try write("scanned.txt", "Mail john@acme.com.")
        let untouched = try write("untouched.txt", "Nothing has been done here.")
        await fixture.session.addDocuments([scanned])
        await fixture.session.anonymizeAll()
        await fixture.session.addDocuments([untouched])

        let payload = fixture.session.buildWorkspacePayload(createdAtISO8601: Self.createdAt)
        XCTAssertEqual(payload.snapshots.count, 1)
        XCTAssertEqual(payload.snapshots[0].documentID, fixture.session.entries[0].id)

        let fileURL = workDir.appendingPathComponent("partial.ldawork")
        try fixture.session.saveWorkspace(
            to: fileURL,
            passphrase: Self.passphrase,
            createdAtISO8601: Self.createdAt
        )
        let colleague = makeFixture("colleague")
        _ = try await colleague.session.openWorkspace(at: fileURL, passphrase: Self.passphrase)

        // The unreviewed document comes back unreviewed, not falsely ready.
        XCTAssertTrue(colleague.session.entries[0].model.canExport)
        XCTAssertEqual(colleague.session.entries[1].model.status, .imported)
    }

    // MARK: - Failure paths leave the live session alone

    func testAWrongPassphraseDoesNotDisturbTheOpenSession() async throws {
        let (origin, _, _) = try await makeReviewedSession()
        let fileURL = workDir.appendingPathComponent("matter.ldawork")
        try origin.session.saveWorkspace(
            to: fileURL,
            passphrase: Self.passphrase,
            createdAtISO8601: Self.createdAt
        )

        let colleague = makeFixture("colleague")
        let doc = try write("colleague-own.txt", "Their own work in progress.")
        await colleague.session.addDocuments([doc])

        do {
            _ = try await colleague.session.openWorkspace(at: fileURL, passphrase: "wrong")
            XCTFail("a wrong passphrase opened the workspace")
        } catch {
            XCTAssertEqual(error as? WorkspaceArchiveError, .wrongPassphrase)
        }

        // Validate before destroying: their in-progress work is untouched.
        XCTAssertEqual(colleague.session.entries.count, 1)
        XCTAssertEqual(colleague.session.entries[0].name, "colleague-own.txt")
    }

    func testAFileFromANewerLDADoesNotDisturbTheOpenSession() async throws {
        let fixture = makeFixture("origin")
        let doc = try write("own.txt", "In progress.")
        await fixture.session.addDocuments([doc])

        // A workspace whose manifest claims a format this build cannot read.
        let futureURL = workDir.appendingPathComponent("future.ldawork")
        let bytes = try WorkspaceArchiveFixtures.rawArchive(
            members: [
                WorkspaceArchive.manifestEntryPath:
                    Data(#"{"formatVersion":99,"documents":[]}"#.utf8)
            ]
        )
        try WorkspaceArchive.container.save(
            bytes,
            to: futureURL,
            protection: .passphrase(Self.passphrase)
        )

        do {
            _ = try await fixture.session.openWorkspace(at: futureURL, passphrase: Self.passphrase)
            XCTFail("a future-format workspace opened")
        } catch {
            XCTAssertEqual(
                error as? WorkspaceArchiveError,
                .createdByNewerVersion(found: 99, supported: WorkspaceArchive.currentFormatVersion)
            )
        }
        XCTAssertEqual(fixture.session.entries.count, 1)
    }

    // MARK: - Save gating and cleanup

    func testAnUnpackFailureDoesNotDisturbTheOpenSession() async throws {
        // prepare() proves the passphrase and the format version, but the
        // inflated-size budget can only be enforced while unpacking. Emptying
        // the tray before that failure would destroy work the user cannot get
        // back, so the unpack has to finish before anything live is discarded.
        let (origin, _, _) = try await makeReviewedSession()
        let fileURL = workDir.appendingPathComponent("matter.ldawork")
        try origin.session.saveWorkspace(
            to: fileURL,
            passphrase: Self.passphrase,
            createdAtISO8601: Self.createdAt
        )

        let colleague = makeFixture("colleague")
        let doc = try write("colleague-own.txt", "Their own work in progress.")
        await colleague.session.addDocuments([doc])
        let expansionsBefore = ZipImporter.liveExpansionCount

        // The budget meters ACTUAL inflated bytes, so this fails inside
        // unpack(), after prepare() has already succeeded.
        ImportLimits.archiveBudgetSeam.value = 1_024

        do {
            _ = try await colleague.session.openWorkspace(
                at: fileURL,
                passphrase: Self.passphrase
            )
            XCTFail("an over-budget workspace opened")
        } catch {
            guard case WorkspaceArchiveError.tooLarge = error else {
                return XCTFail("expected tooLarge, got \(error)")
            }
        }

        XCTAssertEqual(colleague.session.entries.count, 1)
        XCTAssertEqual(colleague.session.entries[0].name, "colleague-own.txt")
        XCTAssertEqual(
            ZipImporter.liveExpansionCount,
            expansionsBefore,
            "a failed unpack must leave no expansion behind"
        )
    }

    func testSaveWorkspaceNeedsAtLeastOneDocument() async throws {
        let fixture = makeFixture("origin")
        XCTAssertFalse(fixture.session.canSaveWorkspace)

        await fixture.session.addDocuments([try write("a.txt", "Text.")])
        XCTAssertTrue(fixture.session.canSaveWorkspace)
    }

    func testEmptyingTheTrayRemovesTheUnpackedOriginals() async throws {
        let (origin, _, _) = try await makeReviewedSession()
        let fileURL = workDir.appendingPathComponent("matter.ldawork")
        try origin.session.saveWorkspace(
            to: fileURL,
            passphrase: Self.passphrase,
            createdAtISO8601: Self.createdAt
        )

        let colleague = makeFixture("colleague")
        _ = try await colleague.session.openWorkspace(at: fileURL, passphrase: Self.passphrase)
        let unpacked = colleague.session.entries[0].url.deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: unpacked.path))

        for entry in colleague.session.entries {
            colleague.session.removeDocument(id: entry.id)
        }

        // Same boundary a dropped .zip gets: an emptied tray leaves no
        // un-redacted originals behind in the temp directory.
        XCTAssertFalse(FileManager.default.fileExists(atPath: unpacked.path))
    }

    func testOpeningASecondWorkspaceDiscardsTheFirstsUnpackedOriginals() async throws {
        let (origin, _, _) = try await makeReviewedSession()
        let fileURL = workDir.appendingPathComponent("matter.ldawork")
        try origin.session.saveWorkspace(
            to: fileURL,
            passphrase: Self.passphrase,
            createdAtISO8601: Self.createdAt
        )

        let colleague = makeFixture("colleague")
        _ = try await colleague.session.openWorkspace(at: fileURL, passphrase: Self.passphrase)
        let first = colleague.session.entries[0].url.deletingLastPathComponent()

        _ = try await colleague.session.openWorkspace(at: fileURL, passphrase: Self.passphrase)
        let second = colleague.session.entries[0].url.deletingLastPathComponent()

        XCTAssertNotEqual(first, second)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: first.path),
            "the replaced workspace's originals stayed on disk"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(colleague.session.entries.count, 2, "the tray merged instead of replacing")
    }
}
