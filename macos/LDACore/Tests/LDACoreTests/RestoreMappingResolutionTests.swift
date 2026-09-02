//
//  RestoreMappingResolutionTests.swift
//  LDACoreTests
//
//  Restore resolves its own mapping instead of asking: the .ldamap saved next
//  to the file wins (it was written for exactly that file), then the session
//  mapping (resumed from the parked round trip just in time), then the matter's
//  stored mapping, and only then does the app ask. A sidecar opens through the
//  Keychain account named after its base name; a passphrase is asked for only
//  once that fails.
//
//  Deterministic-only (no GGUF model). Hermetic: every store lives under the
//  temporary directory with passphrase protection; the one Keychain test mints
//  a process-unique base name and deletes its key in tearDown.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

@MainActor
final class RestoreMappingResolutionTests: XCTestCase {

    private static let createdAt = "2026-09-02T00:00:00Z"
    private var workDir: URL!
    private var usedKeychainAccounts: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestoreMappingResolutionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for account in usedKeychainAccounts {
            try? MappingStore.deleteKeychainKey(account: account)
        }
        usedKeychainAccounts = []
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func makeSession() -> SessionModel {
        let clientRoot = workDir.appendingPathComponent("clients")
        let session = SessionModel(
            makeModel: {
                let model = ReviewModel(modelPath: nil)
                model.useLLM = false
                return model
            },
            clientStore: { try ClientMappingStore(rootDirectory: clientRoot) }
        )
        session.clientProtection = { _ in .passphrase("pw") }
        let recordRoot = workDir.appendingPathComponent("records")
        session.recordStore = { try SessionRecordStore(rootDirectory: recordRoot) }
        session.recordProtection = { .passphrase("pw") }
        let matterRoot = workDir.appendingPathComponent("matters")
        session.matterStore = { try MatterMetadataStore(rootDirectory: matterRoot) }
        session.matterProtection = { .passphrase("pw") }
        let parkedURL = workDir.appendingPathComponent("parked").appendingPathComponent("parked-test.ldamap")
        try? FileManager.default.createDirectory(
            at: parkedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        session.parkedMappingURL = { parkedURL }
        session.parkedProtection = { .passphrase("parked-pw") }
        session.exportSidecarProtection = { _ in .passphrase("sidecar-pw") }
        return session
    }

    private func write(_ name: String, _ content: String) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    /// A session with one scanned document and a finished handoff, so a
    /// session mapping exists and the round trip is parked.
    private func handedOffSession(client: String? = nil) async throws -> (SessionModel, SessionModel.HandToAIResult) {
        let session = makeSession()
        if let client { session.selectClient(client) }
        let doc = try write("a.txt", "Mail john@acme.com please.")
        await session.addDocuments([doc])
        await session.anonymizeAll()
        let handoff = try XCTUnwrap(session.buildHandToAI(createdAtISO8601: Self.createdAt))
        return (session, handoff)
    }

    private func mapping(source: String) -> Mapping {
        Mapping(entries: [:], createdAtISO8601: Self.createdAt, sourceFile: source)
    }

    // MARK: - The order table (pure)

    func testResolutionOrderIsSidecarThenSessionThenClientThenNothing() {
        let sidecar = URL(fileURLWithPath: "/tmp/reply.ldamap")
        let session = mapping(source: "session")
        let client = mapping(source: "client")
        let rows: [(sidecar: URL?, session: Mapping?, client: Mapping?, expected: SessionModel.RestoreMappingSource)] = [
            (sidecar, session, client, .sidecar(sidecar)),
            (sidecar, session, nil, .sidecar(sidecar)),
            (sidecar, nil, client, .sidecar(sidecar)),
            (sidecar, nil, nil, .sidecar(sidecar)),
            (nil, session, client, .session(session)),
            (nil, session, nil, .session(session)),
            (nil, nil, client, .clientProfile(client)),
            (nil, nil, nil, .none)
        ]

        for row in rows {
            XCTAssertEqual(
                SessionModel.resolveRestoreMappingSource(
                    sidecar: row.sidecar,
                    sessionMapping: row.session,
                    clientMapping: row.client
                ),
                row.expected,
                "sidecar=\(row.sidecar != nil) session=\(row.session != nil) client=\(row.client != nil)"
            )
        }
    }

    // MARK: - Resolution for a file

    func testASiblingSidecarWinsWithoutTouchingTheParkedSession() async throws {
        let (_, handoff) = try await handedOffSession()
        let edited = try write("reply.md", handoff.combined)
        let sidecar = try write("reply.ldamap", "existence is all the resolver checks")

        let relaunched = makeSession()
        let source = try relaunched.restoreMappingSource(for: edited)

        XCTAssertEqual(source, .sidecar(sidecar))
        XCTAssertNil(
            relaunched.sessionMapping,
            "a file that brought its own key must not cost a Keychain touch for the parked round trip"
        )
    }

    func testTheSessionMappingIsUsedWhenNoSidecarSitsNextToTheFile() async throws {
        let (session, handoff) = try await handedOffSession()
        let edited = try write("reply.md", handoff.combined)

        let source = try session.restoreMappingSource(for: edited)

        XCTAssertEqual(source, .session(try XCTUnwrap(session.sessionMapping)))
    }

    func testAParkedSessionIsResumedJustInTime() async throws {
        let (first, handoff) = try await handedOffSession()
        let edited = try write("reply.md", handoff.combined)

        let relaunched = makeSession()
        XCTAssertNil(relaunched.sessionMapping, "fixture: nothing in memory before the resolve")
        let source = try relaunched.restoreMappingSource(for: edited)

        guard case .session(let mapping) = source else {
            return XCTFail("expected the parked session mapping, got \(source)")
        }
        XCTAssertEqual(
            Set(mapping.entries.values.map(\.token)),
            Set(try XCTUnwrap(first.sessionMapping).entries.values.map(\.token))
        )
        XCTAssertNotNil(relaunched.sessionMapping, "the resume is kept for the restore that follows")
    }

    func testTheMatterMappingIsTheLastFallback() async throws {
        let (first, handoff) = try await handedOffSession(client: "Acme Matter")
        // Nothing parked any more, so only the matter's stored mapping is left.
        try FileManager.default.removeItem(at: try first.parkedMappingURL())
        let edited = try write("reply.md", handoff.combined)

        let relaunched = makeSession()
        relaunched.selectClient("Acme Matter")
        let source = try relaunched.restoreMappingSource(for: edited)

        guard case .clientProfile(let mapping) = source else {
            return XCTFail("expected the matter mapping, got \(source)")
        }
        XCTAssertEqual(mapping.entries.count, 1)
        XCTAssertNil(relaunched.sessionMapping, "a matter lookup does not become the session mapping")
    }

    func testNothingFoundAsksForAMapping() throws {
        let session = makeSession()
        let edited = try write("reply.md", "Nothing {EMAIL_1} here.")

        XCTAssertEqual(try session.restoreMappingSource(for: edited), .none)
    }

    // MARK: - Opening a sidecar

    func testAKeychainSidecarOpensWithoutAPassphrase() throws {
        let base = TestNamespace.fileBaseName("export")
        usedKeychainAccounts.append(base)
        let sidecar = workDir.appendingPathComponent("\(base).ldamap")
        let expected = mapping(source: "keychain")
        try MappingStore.save(expected, to: sidecar, protection: .keychain(account: base))

        XCTAssertEqual(SessionModel.sidecarKeychainAccount(for: sidecar), base)
        XCTAssertEqual(try SessionModel.loadSidecarMapping(at: sidecar), expected)
    }

    func testAPassphraseSidecarIsRecognizedAndOpensWithThePassphrase() throws {
        let base = TestNamespace.fileBaseName("locked")
        usedKeychainAccounts.append(base)
        let sidecar = workDir.appendingPathComponent("\(base).ldamap")
        let expected = mapping(source: "passphrase")
        try MappingStore.save(expected, to: sidecar, protection: .passphrase("pw"))

        XCTAssertThrowsError(try SessionModel.loadSidecarMapping(at: sidecar)) { error in
            XCTAssertTrue(
                SessionModel.sidecarLoadNeedsPassphrase(error),
                "a Keychain miss on a passphrase sidecar is the one case that asks: \(error)"
            )
        }
        XCTAssertEqual(try SessionModel.loadSidecarMapping(at: sidecar, passphrase: "pw"), expected)
    }

    func testOnlyKeyFailuresTurnIntoAPassphrasePrompt() {
        XCTAssertTrue(SessionModel.sidecarLoadNeedsPassphrase(DocumentIOError.decryptionFailed))
        XCTAssertTrue(SessionModel.sidecarLoadNeedsPassphrase(DocumentIOError.keychainError(-25300)))
        XCTAssertFalse(SessionModel.sidecarLoadNeedsPassphrase(DocumentIOError.unreadable("gone")))
        XCTAssertFalse(SessionModel.sidecarLoadNeedsPassphrase(DocumentIOError.corrupt("bytes")))
        XCTAssertFalse(SessionModel.sidecarLoadNeedsPassphrase(LDAServiceError.outputEqualsInput))
    }

    // MARK: - Restoring the file

    func testRestoringMarkdownWritesTheRestoredText() async throws {
        let (session, handoff) = try await handedOffSession()
        let edited = try write("Redacted for AI.md", "AI draft follows. " + handoff.combined)
        let output = workDir.appendingPathComponent("Redacted for AI_restored.md")

        let report = try session.restoreFile(
            edited,
            mapping: try XCTUnwrap(session.sessionMapping),
            output: output
        )

        XCTAssertEqual(
            try String(contentsOf: output, encoding: .utf8),
            "AI draft follows. Mail john@acme.com please."
        )
        XCTAssertEqual(report.restoredCount, 1)
        XCTAssertTrue(report.orphanTokens.isEmpty)
        XCTAssertEqual(report.outputURL, output)
    }

    func testRestoringMarkdownIntoWordProducesAPlainDocumentWithTheRestoredText() async throws {
        let (session, handoff) = try await handedOffSession()
        let edited = try write("Redacted for AI.md", "AI draft follows. " + handoff.combined)
        let output = workDir.appendingPathComponent("Redacted for AI_restored.docx")

        let report = try session.restoreFile(
            edited,
            mapping: try XCTUnwrap(session.sessionMapping),
            output: output
        )

        XCTAssertEqual(report.restoredCount, 1)
        XCTAssertEqual(
            try DocxImporter().importDocument(output).text,
            "AI draft follows. Mail john@acme.com please."
        )
    }

    func testRestoringAWordDocumentKeepsItsRunFormatting() throws {
        let original = try writeBoldDocx(
            name: "contract.docx",
            runs: ["Contact ", "jane.doe@example.com", " for details."]
        )
        let outputDir = workDir.appendingPathComponent("saved", isDirectory: true)
        let saved = try LDAService.anonymize(
            input: original,
            outputDir: outputDir,
            protection: .passphrase("pw"),
            createdAtISO8601: Self.createdAt
        )
        let mapping = try MappingStore.load(from: saved.mappingFileURL, protection: .passphrase("pw"))
        let output = workDir.appendingPathComponent("contract_restored.docx")

        let report = try makeSession().restoreFile(saved.redactedFileURL, mapping: mapping, output: output)

        XCTAssertEqual(report.restoredCount, 1)
        XCTAssertEqual(
            try DocxImporter().importDocument(output).text,
            try DocxImporter().importDocument(original).text
        )
        let xml = String(data: try DocxZip.readEntry("word/document.xml", from: output), encoding: .utf8) ?? ""
        XCTAssertTrue(xml.contains("<w:b/>"), "the bold run property must survive the restore")
    }

    /// A minimal .docx whose every run is bold, so a formatting round trip has
    /// something to lose.
    private func writeBoldDocx(name: String, runs: [String]) throws -> URL {
        let body = runs.map { text in
            "<w:r><w:rPr><w:b/></w:rPr><w:t xml:space=\"preserve\">\(text)</w:t></w:r>"
        }.joined()
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        </Types>
        """
        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p>\(body)</w:p></w:body></w:document>
        """
        let url = workDir.appendingPathComponent(name)
        try DocxZip.writeArchive(
            parts: [
                ("[Content_Types].xml", Data(contentTypes.utf8)),
                ("_rels/.rels", Data(rels.utf8)),
                ("word/document.xml", Data(document.utf8))
            ],
            to: url
        )
        return url
    }
}
