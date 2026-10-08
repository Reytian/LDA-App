import XCTest
import Security
@testable import LDACore
@testable import LDAMCP

final class MCPExportHandoffTests: XCTestCase {
    private var root: URL!
    private var vault: DocumentVault!
    private var server: MCPServer!
    private let mappingPassphrase = "fictional-handoff-key"
    private let matter = UUID()
    private var wire: [String] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vault = VaultTestSupport.vault(root: root.appendingPathComponent("vault"))
        server = MCPServer(environment: VaultTestSupport.serverEnvironment(vaultDir: vault.rootDirectory))
        server.runEditedImportForTesting = { operation in try operation { _ in } }
        server.presentExportForTesting = { _, _ in "shown" }
        wire = []
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func call(_ tool: String, _ arguments: [String: Any], fails: Bool = false) throws -> [String: Any] {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": wire.count + 1, "method": "tools/call",
                                      "params": ["name": tool, "arguments": arguments]]
        let data = try XCTUnwrap(server.handle(JSONSerialization.data(withJSONObject: request)))
        wire.append(String(decoding: data, as: UTF8.self))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool == true, fails, wire.last!)
        let blocks = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(blocks.first?["text"] as? String)
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    private func prepareWord() throws -> (source: URL, redacted: String) {
        let url = root.appendingPathComponent("Private agreement.docx")
        let table = "<w:tbl><w:tr><w:tc>" + DocxTestPackage.paragraph(DocxTestPackage.run("Pay within 14 days.")) + "</w:tc></w:tr></w:tbl>"
        try DocxTestPackage.write(
            body: DocxTestPackage.paragraph(DocxTestPackage.run("local@example.com", rPr: "<w:b/>")) + table,
            extraParts: [
                ("word/header1.xml", DocxTestPackage.wordPart(rootTag: "hdr", body: DocxTestPackage.paragraph(DocxTestPackage.run("header@example.com")))),
                ("word/styles.xml", "<w:styles xmlns:w=\"\(DocxTestPackage.wordNamespace)\"><w:style w:type=\"paragraph\" w:styleId=\"Normal\"/></w:styles>")
            ], to: url)
        server.selectDocumentsForTesting = { .init(urls: [url], review: false) }
        server.chooseWorkspaceForTesting = { _ in self.matter }
        server.prepareMappingPassphraseForTesting = mappingPassphrase
        let response = try call("prepare_documents", [:])
        let docs = try XCTUnwrap(response["documents"] as? [[String: Any]])
        XCTAssertEqual(docs.first?["sourceFormat"] as? String, "docx")
        XCTAssertEqual(docs.first?["format"] as? String, "docx")
        return (url, try XCTUnwrap(docs.first?["redactedHandle"] as? String))
    }

    func testWordPickerRoundTripKeepsStructureAndPrivateResponses() throws {
        let prepared = try prepareWord()
        var receipt: ExportReceipt?
        server.presentExportForTesting = { exported, saved in receipt = exported; XCTAssertTrue(saved); return "shown" }
        let export = try call("export", ["handle": prepared.redacted])
        let exported = try XCTUnwrap(receipt)
        XCTAssertEqual(export["exportID"] as? String, exported.exportID)
        XCTAssertEqual(export["format"] as? String, "docx")
        let editedURL = root.appendingPathComponent("Private edited copy.docx")
        try DocxFixtureSupport.editingBody(of: exported.fileURL, replacing: "14 days", with: "30 days", to: editedURL)
        server.selectEditedDocumentForTesting = { source in
            XCTAssertEqual(source.handle, prepared.redacted)
            XCTAssertEqual(source.workspaceID, self.matter)
            return editedURL
        }
        let imported = try call("import_edited_document", ["redactedHandle": prepared.redacted])
        let edited = try XCTUnwrap(imported["editedHandle"] as? String)
        XCTAssertEqual(imported["status"] as? String, "completed")
        XCTAssertEqual(imported["trackedChanges"] as? String, "none_detected")
        XCTAssertEqual(try vault.entry(handle: edited).editingSourceHandle, prepared.redacted)
        XCTAssertEqual(try vault.entry(handle: edited).workspaceID, matter)
        XCTAssertEqual(try vault.readDocumentBytes(handle: edited), try Data(contentsOf: editedURL), "Import must not rewrite Word")
        _ = try call("read_redacted", ["handle": edited], fails: true)
        let restored = try call("restore", ["redactedHandle": prepared.redacted, "editedHandle": edited, "passphrase": mappingPassphrase])
        XCTAssertGreaterThanOrEqual(restored["restoredCount"] as? Int ?? 0, 2)
        XCTAssertEqual(restored["orphanTokens"] as? [String], [])
        XCTAssertEqual(restored["suspectPlaceholderCount"] as? Int, 0)
        XCTAssertEqual(restored["ambiguousReplacements"] as? [String], [])
        XCTAssertNil(restored["suspectPlaceholders"])
        let restoredHandle = try XCTUnwrap(restored["restoredHandle"] as? String)
        _ = try call("export", ["handle": restoredHandle])
        let restoredURL = try XCTUnwrap(receipt?.fileURL)
        let body = try DocxFixtureSupport.part(docxMainPartPath, in: restoredURL)
        XCTAssertTrue(body.contains("<w:tbl>"))
        XCTAssertTrue(body.contains("<w:b/>"))
        XCTAssertTrue(body.contains("30 days"))
        XCTAssertTrue(body.contains("local@example.com"))
        XCTAssertTrue(try DocxFixtureSupport.part("word/header1.xml", in: restoredURL).contains("header@example.com"))
        XCTAssertEqual(try DocxFixtureSupport.partData("word/styles.xml", in: restoredURL),
                       try DocxFixtureSupport.partData("word/styles.xml", in: prepared.source))
        for privateValue in ["Private agreement", "Private edited", "local@example.com", "header@example.com", root.path, mappingPassphrase] {
            XCTAssertFalse(wire.joined().contains(privateValue), privateValue)
        }
        XCTAssertTrue(try MCPAuditJournal(vault: vault).verify().records.contains { $0.event.operation == "import_edited_document" })
    }

    func testCancelledPickerAndInjectedPathsPublishNothing() throws {
        let prepared = try prepareWord()
        let before = try vault.list()
        server.selectEditedDocumentForTesting = { _ in nil }
        let cancelled = try call("import_edited_document", ["redactedHandle": prepared.redacted])
        XCTAssertEqual(cancelled["status"] as? String, "cancelled")
        _ = try call("import_edited_document", ["redactedHandle": prepared.redacted, "path": "private-path", "approved": true], fails: true)
        XCTAssertEqual(try vault.list(), before)
        XCTAssertFalse(wire.joined().contains("private-path"))
    }

    func testTrackedRevisionsInHeaderRefuseImportBeforeRegistration() throws {
        let prepared = try prepareWord()
        let edited = root.appendingPathComponent("edited.docx")
        try DocxTestPackage.write(body: DocxTestPackage.paragraph(DocxTestPackage.run("{EMAIL_1}")),
            extraParts: [("word/header1.xml", DocxTestPackage.wordPart(rootTag: "hdr", body:
                "<w:ins w:author=\"Private Author\">" + DocxTestPackage.paragraph(DocxTestPackage.run("{EMAIL_2}")) + "</w:ins>"))], to: edited)
        let before = try vault.list()
        server.selectEditedDocumentForTesting = { _ in edited }
        _ = try call("import_edited_document", ["redactedHandle": prepared.redacted], fails: true)
        XCTAssertTrue(wire.last!.contains("tracked_changes_unresolved"))
        XCTAssertFalse(wire.last!.contains("Private Author"))
        XCTAssertEqual(try vault.list(), before)
    }

    func testImportedEditCannotBeRestoredWithAnotherMapping() throws {
        let first = try prepareWord()
        let exported = try vault.exportToOutbox(handle: first.redacted)
        server.selectEditedDocumentForTesting = { _ in exported }
        let imported = try call("import_edited_document", ["redactedHandle": first.redacted])
        let second = try prepareWord()
        _ = try call("restore", ["redactedHandle": second.redacted, "editedHandle": imported["editedHandle"]!, "passphrase": mappingPassphrase], fails: true)
        XCTAssertTrue(wire.last!.contains("mapping_mismatch"))
    }

    func testTrackedTableGridRevisionRefusesImportBeforeRegistration() throws {
        let prepared = try prepareWord()
        let edited = root.appendingPathComponent("edited-table.docx")
        let table = "<w:tbl><w:tblGrid><w:gridCol w:w=\"6000\"/>"
            + "<w:tblGridChange w:id=\"1\" w:author=\"Private Table Author\">"
            + "<w:tblGrid><w:gridCol w:w=\"3000\"/></w:tblGrid>"
            + "</w:tblGridChange></w:tblGrid><w:tr><w:tc>"
            + DocxTestPackage.paragraph(DocxTestPackage.run("{EMAIL_1}"))
            + "</w:tc></w:tr></w:tbl>"
        try DocxTestPackage.write(body: table, to: edited)
        let before = try vault.list()
        server.selectEditedDocumentForTesting = { _ in edited }

        _ = try call("import_edited_document", ["redactedHandle": prepared.redacted], fails: true)

        XCTAssertTrue(wire.last!.contains("tracked_changes_unresolved"))
        XCTAssertFalse(wire.last!.contains("Private Table Author"))
        XCTAssertEqual(try vault.list(), before)
    }

    func testCancellationDuringEncryptionRemovesPartialStaging() throws {
        let url = root.appendingPathComponent("edited.txt")
        try Data("{EMAIL_1}".utf8).write(to: url)
        XCTAssertThrowsError(try vault.stage(fileURL: url, stagedAtISO8601: "now") { phase in
            if phase == .encrypting { throw DocumentVaultError.stagingCancelled }
        }) { XCTAssertEqual($0 as? DocumentVaultError, .stagingCancelled) }
        XCTAssertEqual(try vault.list(), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vault.rootDirectory.appendingPathComponent(DocumentVault.objectsDirectoryName).path), [])
    }

    func testBusyLockHasBoundedTimeoutAndDoesNotClaimAuthentication() throws {
        let url = root.appendingPathComponent("held.lock")
        let descriptor = open(url.path, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try VaultCrossProcessLock(lockFileURL: url, timeout: 0.15).withLock {}) {
            XCTAssertEqual($0 as? DocumentVaultError, .lockTimedOut)
            XCTAssertFalse((LocalOperationFailure.message(for: $0) ?? "").contains("authentication"))
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
        XCTAssertTrue(LocalOperationFailure.message(for: NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError))!.contains("filesystem_permission_denied"))
        XCTAssertTrue(LocalOperationFailure.message(for: DocumentIOError.keychainError(errSecInteractionNotAllowed))!.contains("authentication_required"))
        XCTAssertNil(LocalOperationFailure.message(for: NSError(domain: "unknown-delay", code: 1)))
    }

    func testConcurrentAppHistoryAndMCPExportsKeepEachArtifact() throws {
        let prepared = try prepareWord()
        let history = server.exportHistory()
        let old = root.appendingPathComponent("Older app export.md")
        try Data("Old redacted export".utf8).write(to: old)
        let gui = ExportReceipt(fileURL: old, origin: .app, kind: .redacted, workspaceID: matter,
                                matterLabel: "Private Matter", createdAt: Date(timeIntervalSince1970: 1))
        let lock = NSLock()
        var errors: [Error] = []
        let servers = (0..<4).map { _ -> MCPServer in
            var instance = MCPServer(environment: VaultTestSupport.serverEnvironment(vaultDir: vault.rootDirectory))
            instance.presentExportForTesting = { _, _ in "shown" }
            return instance
        }
        DispatchQueue.concurrentPerform(iterations: 5) { index in
            do {
                if index == 0 { try history.record(gui) }
                else { _ = try servers[index - 1].callExport(["handle": prepared.redacted]) }
            } catch { lock.withLock { errors.append(error) } }
        }
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        let receipts = try history.list()
        XCTAssertEqual(receipts.count, 5)
        XCTAssertEqual(Set(receipts.map(\.exportID)).count, 5)
        XCTAssertEqual(Set(receipts.map(\.fileURL)).count, 5)
        XCTAssertEqual(receipts.last?.id, gui.id)
        for receipt in receipts where receipt.origin == .mcp {
            XCTAssertEqual(receipt.format, "docx")
            XCTAssertEqual(receipt.artifactHandle, prepared.redacted)
            XCTAssertEqual(receipt.workspaceID, matter)
            XCTAssertEqual(try Data(contentsOf: receipt.resolvedURL()), try vault.readDocumentBytes(handle: prepared.redacted))
            XCTAssertEqual(ExportReceipt.requestedID(from: receipt.localActionURL), receipt.id)
        }
        for file in try FileManager.default.contentsOfDirectory(at: history.directory, includingPropertiesForKeys: nil) {
            let bytes = try Data(contentsOf: file)
            for secret in ["Private Matter", "Older app export", root.path] { XCTAssertNil(bytes.range(of: Data(secret.utf8))) }
        }
    }

    func testExportActionRejectsPathsQueriesAndOtherRoutes() {
        for text in ["lda-mcp://show-export/../../private", "lda-mcp://show-export/\(UUID())?path=private",
                     "lda-mcp://show-export/\(UUID())#private", "lda-mcp://choose-workspace/\(UUID())"] {
            XCTAssertNil(ExportReceipt.requestedID(from: URL(string: text)!))
        }
    }

    func testConcurrentProcessesShareAppAndMCPHistory() throws {
        let environment = ProcessInfo.processInfo.environment
        if let role = environment["LDA_HANDOFF_TEST_ROLE"], let shared = environment["LDA_HANDOFF_TEST_ROOT"],
           let handle = environment["LDA_HANDOFF_TEST_HANDLE"] {
            let sharedRoot = URL(fileURLWithPath: shared)
            let sharedVault = VaultTestSupport.vault(root: sharedRoot.appendingPathComponent("vault"))
            server = MCPServer(environment: VaultTestSupport.serverEnvironment(vaultDir: sharedVault.rootDirectory))
            server.presentExportForTesting = { _, _ in "shown" }
            for index in 0..<3 {
                if role == "app" {
                    let file = sharedRoot.appendingPathComponent("App copy \(index).docx")
                    try sharedVault.readDocumentBytes(handle: handle).write(to: file)
                    try server.exportHistory().record(ExportReceipt(fileURL: file, origin: .app, kind: .redacted))
                } else {
                    let result = try call("export", ["handle": handle])
                    XCTAssertEqual(result["status"] as? String, "completed")
                    XCTAssertEqual(result["historyStatus"] as? String, "saved")
                }
            }
            return
        }
        let prepared = try prepareWord()
        let finished = DispatchGroup()
        let processes = ["app", "mcp-a", "mcp-b"].map { role -> Process in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["xctest", "-XCTest", "LDACoreTests.MCPExportHandoffTests/testConcurrentProcessesShareAppAndMCPHistory",
                                 Bundle(for: Self.self).bundleURL.path]
            var childEnvironment = environment
            childEnvironment["LDA_HANDOFF_TEST_ROLE"] = role
            childEnvironment["LDA_HANDOFF_TEST_ROOT"] = root.path
            childEnvironment["LDA_HANDOFF_TEST_HANDLE"] = prepared.redacted
            process.environment = childEnvironment
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            process.terminationHandler = { _ in finished.leave() }
            return process
        }
        defer { for process in processes where process.isRunning { process.terminate() } }
        for process in processes { finished.enter(); try process.run() }
        guard finished.wait(timeout: .now() + 45) == .success else {
            XCTFail("Concurrent App/MCP export processes did not finish within 45 seconds")
            return
        }
        for process in processes {
            let output = (process.standardOutput as! Pipe).fileHandleForReading.readDataToEndOfFile()
            let errors = (process.standardError as! Pipe).fileHandleForReading.readDataToEndOfFile()
            XCTAssertEqual(process.terminationStatus, 0, String(decoding: output + errors, as: UTF8.self))
        }
        let receipts = try server.exportHistory().list()
        XCTAssertEqual(receipts.count, 9)
        XCTAssertEqual(receipts.filter { $0.origin == .app }.count, 3)
        XCTAssertEqual(receipts.filter { $0.origin == .mcp }.count, 6)
        XCTAssertEqual(Set(receipts.map(\.fileURL)).count, 9)
        for receipt in receipts {
            XCTAssertEqual(try Data(contentsOf: receipt.fileURL), try vault.readDocumentBytes(handle: prepared.redacted))
        }
        _ = try MCPAuditJournal(vault: vault).verify()
    }
}
