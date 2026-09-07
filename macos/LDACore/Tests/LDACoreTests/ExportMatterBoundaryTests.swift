//
//  ExportMatterBoundaryTests.swift
//  LDACoreTests
//
//  R7: an export that finishes AFTER the user switched matters must not put
//  the starting matter's mapping into the session now on screen.
//
//  The race is real because Save Redacted on a DOCX runs the AI pass over the
//  headers, footers, notes and comments, which takes seconds to minutes, and
//  the window stays live throughout. The verification review drove it with a
//  synthetic DOCX export paused at its header completion:
//
//    MAPPING RACE: currentMatter=Synthetic Matter B, currentDocument=matterB.txt,
//                  sessionMappingContainsMatterA=true
//    SAVED WORKSPACE: filename=matterA~d6bbb8597ff336d2.ldawork,
//                     matterLabel=Synthetic Matter B, documents=0
//
//  Matter A's values became available to matter B's restoration, and A's own
//  workspace was written with B's label and no documents, so A's export lost
//  its key home at the same time.
//
//  Everything here is synthetic: two invalid-TLD email addresses and two
//  matter labels that name nobody. The default workspaces are passphrase
//  sealed rather than Keychain sealed so the suite touches no Keychain.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

/// Holds the export inside its detached worker until the test releases it, so
/// the matter switch provably lands after the export's main-actor prefix and
/// before its completion.
private final class ExportGate: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var released = false

    var hasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    func markStarted() {
        lock.lock()
        started = true
        lock.unlock()
    }

    func release() {
        lock.lock()
        released = true
        lock.unlock()
    }

    var isReleased: Bool {
        lock.lock()
        defer { lock.unlock() }
        return released
    }
}

/// A fake model whose completion blocks on the gate and then reports nothing,
/// so the header pass adds no entity of its own.
private struct GatedCompleter: TextCompleter {
    let gate: ExportGate

    func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
        gate.markStarted()
        for _ in 0..<800 {
            if gate.isReleased { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return #"{"entities":[]}"#
    }
}

@MainActor
final class ExportMatterBoundaryTests: XCTestCase {

    private static let createdAt = "2026-09-07T00:00:00Z"
    private static let matterA = "Synthetic Matter A"
    private static let matterB = "Synthetic Matter B"
    private static let emailA = "synthetic-matter-a@example.invalid"
    private static let emailB = "synthetic-matter-b@example.invalid"
    private static let workspacePassphrase = "SyntheticWorkspacePassphrase"

    private var workDir: URL!
    private var workspaceDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        assertNoTestSeamsInstalled()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ExportMatterBoundaryTests-\(UUID().uuidString)",
                isDirectory: true
            )
        workspaceDir = workDir.appendingPathComponent("workspaces", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaceDir,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        ReviewModel.llmExtractorFactoryForTesting = nil
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// A session whose every store lives under this test's own directory, and
    /// whose default workspaces are passphrase sealed.
    private func makeSession() -> SessionModel {
        let session = SessionModel(
            makeModel: {
                let model = ReviewModel(modelPath: nil)
                model.useLLM = false
                return model
            },
            clientStore: {
                try ClientMappingStore(
                    rootDirectory: self.workDir.appendingPathComponent("clients")
                )
            }
        )
        session.clientProtection = { _ in .passphrase("client-pw") }
        session.recordStore = {
            try SessionRecordStore(rootDirectory: self.workDir.appendingPathComponent("records"))
        }
        session.recordProtection = { .passphrase("record-pw") }
        session.matterStore = {
            try MatterMetadataStore(rootDirectory: self.workDir.appendingPathComponent("matters"))
        }
        session.matterProtection = { .passphrase("matter-pw") }
        let parkedURL = workDir
            .appendingPathComponent("parked", isDirectory: true)
            .appendingPathComponent("parked.ldamap")
        try? FileManager.default.createDirectory(
            at: parkedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        session.parkedMappingURL = { parkedURL }
        session.parkedProtection = { .passphrase("parked-pw") }
        session.exportSidecarProtection = { _ in .passphrase("sidecar-pw") }
        session.defaultWorkspaceDirectory = { self.workspaceDir }
        session.defaultWorkspaceProtection = { _ in
            .passphrase(Self.workspacePassphrase)
        }
        session.outputStyleProvider = { .token }
        return session
    }

    /// Matter A's document: one email in the body, plus a header part so the
    /// export runs its non-body AI pass and can be held there.
    private func writeMatterADocument() throws -> URL {
        let url = workDir.appendingPathComponent("matterA.docx")
        try DocxTestPackage.write(
            body: DocxTestPackage.paragraph(
                DocxTestPackage.run("Contact " + Self.emailA + " about the matter.")
            ),
            extraParts: [
                (
                    "word/header1.xml",
                    DocxTestPackage.wordPart(
                        rootTag: "hdr",
                        body: DocxTestPackage.paragraph(
                            DocxTestPackage.run("A safe running header")
                        )
                    )
                )
            ],
            to: url
        )
        return url
    }

    private func writeMatterBDocument() throws -> URL {
        let url = workDir.appendingPathComponent("matterB.txt")
        try Data(("Contact " + Self.emailB + " about the other matter.").utf8).write(to: url)
        return url
    }

    /// A file that merely has to exist: the detection pass checks the model
    /// path before it builds an extractor, and the test seam replaces it.
    private func writePlaceholderModel() throws -> URL {
        let url = workDir.appendingPathComponent("placeholder.gguf")
        try Data("placeholder".utf8).write(to: url)
        return url
    }

    /// A session holding matter A's scanned DOCX, with the export's AI pass
    /// staged to block on `gate`.
    private func sessionReadyToExportMatterA(
        gate: ExportGate
    ) async throws -> (session: SessionModel, source: URL) {
        let session = makeSession()
        XCTAssertTrue(session.selectClient(Self.matterA, discardingDocuments: true))
        let source = try writeMatterADocument()
        await session.addDocuments([source])
        let model = session.activeModel
        model.useLLM = false
        model.outputStyleProvider = { .token }
        await model.anonymize()
        XCTAssertTrue(
            model.entities.contains { $0.span.text == Self.emailA && $0.accepted },
            "fixture: the deterministic scan must accept matter A's email"
        )
        ReviewModel.llmExtractorFactoryForTesting = { _, cancel in
            LLMExtractor(completer: GatedCompleter(gate: gate), cancelToken: cancel)
        }
        model.useLLM = true
        model.modelPath = try writePlaceholderModel().path
        return (session, source)
    }

    private func waitUntilExportStarted(_ gate: ExportGate) async throws {
        for _ in 0..<1000 where !gate.hasStarted {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(gate.hasStarted, "the export never reached its AI pass")
    }

    private func openedWorkspace(at url: URL) throws -> WorkspaceArchive.PreparedWorkspace {
        try WorkspaceArchive.prepare(
            from: url,
            protection: .passphrase(Self.workspacePassphrase)
        )
    }

    // MARK: - The review's ordering

    /// Start A's export, switch to matter B, open B's document, then let A
    /// finish. A's mapping must not enter B's session, and A's own workspace
    /// must carry A's label and A's document so A's export keeps a key home.
    func testAnExportFinishingAfterAMatterSwitchKeepsItsKeyInTheStartingMatter() async throws {
        let gate = ExportGate()
        let (session, _) = try await sessionReadyToExportMatterA(gate: gate)

        let exportTask = Task {
            try await session.exportRedacted(
                to: workDir.appendingPathComponent("out", isDirectory: true),
                passphrase: nil,
                createdAtISO8601: Self.createdAt
            )
        }
        try await waitUntilExportStarted(gate)

        XCTAssertTrue(session.selectClient(Self.matterB, discardingDocuments: true))
        await session.addDocuments([try writeMatterBDocument()])
        XCTAssertEqual(session.activeEntry?.name, "matterB.txt", "fixture: B is on screen")

        gate.release()
        let outcome = try await exportTask.value

        XCTAssertFalse(
            session.sessionMapping?.entries.values.contains { $0.value == Self.emailA } ?? false,
            "matter A's value reached matter B's session mapping"
        )
        let workspaceURL = try XCTUnwrap(
            outcome.workspaceURL,
            "the export must still report where it kept its key"
        )
        let workspace = try openedWorkspace(at: workspaceURL)
        XCTAssertEqual(
            workspace.manifest.matterLabel, Self.matterA,
            "A's workspace was written with the matter that was selected at completion"
        )
        XCTAssertEqual(
            workspace.manifest.documents.map { $0.name }, ["matterA.docx"],
            "A's workspace must carry A's document, not whatever the tray held at completion"
        )
        let keptMapping = try WorkspaceArchive.readMapping(
            from: workspaceURL,
            protection: .passphrase(Self.workspacePassphrase)
        )
        XCTAssertTrue(
            keptMapping?.entries.values.contains { $0.value == Self.emailA } ?? false,
            "A's key must be readable from A's workspace"
        )
    }

    /// The same completion must tell the user where the key went, because
    /// nothing else on screen would: the session it belongs to is gone.
    func testAnExportThatCouldNotBeAdoptedSaysWhereItsKeyWent() async throws {
        let gate = ExportGate()
        let (session, _) = try await sessionReadyToExportMatterA(gate: gate)

        let exportTask = Task {
            try await session.exportRedacted(
                to: workDir.appendingPathComponent("out", isDirectory: true),
                passphrase: nil,
                createdAtISO8601: Self.createdAt
            )
        }
        try await waitUntilExportStarted(gate)
        XCTAssertTrue(session.selectClient(Self.matterB, discardingDocuments: true))
        await session.addDocuments([try writeMatterBDocument()])
        gate.release()
        let outcome = try await exportTask.value

        let advisory = try XCTUnwrap(
            session.mappingHomeAdvisory,
            "a mapping that could not be adopted must be reported, not dropped silently"
        )
        XCTAssertTrue(
            advisory.contains(try XCTUnwrap(outcome.workspaceURL).lastPathComponent),
            "the advisory must name the file the key was kept in, got: \(advisory)"
        )
    }

    // MARK: - The unswitched case still works

    /// No switch, no change: the export adopts its mapping into the live
    /// session exactly as before, and says nothing extra.
    func testAnExportThatFinishesInItsOwnMatterStillAdoptsItsMapping() async throws {
        let gate = ExportGate()
        let (session, _) = try await sessionReadyToExportMatterA(gate: gate)
        gate.release()

        let outcome = try await session.exportRedacted(
            to: workDir.appendingPathComponent("out", isDirectory: true),
            passphrase: nil,
            createdAtISO8601: Self.createdAt
        )

        XCTAssertTrue(
            session.sessionMapping?.entries.values.contains { $0.value == Self.emailA } ?? false,
            "an export finishing in its own matter must still seed the session mapping"
        )
        XCTAssertNil(
            session.mappingHomeAdvisory,
            "an adopted mapping needs no advisory"
        )
        let workspace = try openedWorkspace(at: try XCTUnwrap(outcome.workspaceURL))
        XCTAssertEqual(workspace.manifest.matterLabel, Self.matterA)
        XCTAssertEqual(workspace.manifest.documents.map { $0.name }, ["matterA.docx"])
    }
}
