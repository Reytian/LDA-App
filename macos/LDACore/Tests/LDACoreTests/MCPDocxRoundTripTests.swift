//
//  MCPDocxRoundTripTests.swift
//  LDACoreTests
//
//  .docx in, restored .docx out, over the handle-first MCP surface and with
//  no intermediary text file. Two paths are proven here:
//
//   - restore of the stored redacted .docx as it stands (no edits), and
//   - restore of an EDITED redacted .docx the human staged back into the
//     vault, passed as editedHandle and restored with the redacted artifact's
//     own mapping.
//
//  Both must return the original visible text, keep the run properties of the
//  runs that held tokens, and copy every untouched package part byte for byte
//  (styles.xml is the witness). Every restore response also names its format.
//  The refusals (a restored artifact or an image as editedHandle, editedText
//  together with editedHandle) are pinned so a caller cannot restore into the
//  wrong surface by accident.
//
//  Deterministic detection only (no GGUF model), hermetic temp-rooted vaults,
//  passphrase-protected sidecars: nothing here touches the Keychain.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDAMCP
@testable import LDACore

final class MCPDocxRoundTripTests: XCTestCase {

    private var workDir: URL!
    private var vaultDir: URL!
    private var server: MCPServer!

    private let passphrase = "mcp-docx-passphrase"
    private static let stagedAt = "2026-09-02T00:00:00Z"
    private static let email = "jane.doe@example.com"
    /// A Chinese mainland mobile number the deterministic engine recognizes.
    private static let phone = "13912345678"
    private static let bodyDate = "2024-01-15"
    private static let headerDate = "2023-12-31"

    override func setUpWithError() throws {
        try super.setUpWithError()
        assertNoTestSeamsInstalled()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPDocxRoundTripTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        vaultDir = workDir.appendingPathComponent("vault", isDirectory: true)
        server = MCPServer(environment: VaultTestSupport.serverEnvironment(vaultDir: vaultDir))
    }

    override func tearDownWithError() throws {
        if let workDir, FileManager.default.fileExists(atPath: workDir.path) {
            try? FileManager.default.removeItem(at: workDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - JSON-RPC helpers

    private func roundTrip(_ request: [String: Any]) throws -> [String: Any] {
        let payload = try JSONSerialization.data(withJSONObject: request)
        let responseData = try XCTUnwrap(server.handle(payload), "expected a response for \(request)")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
    }

    private func call(tool: String, arguments: [String: Any]) throws -> (isError: Bool, text: String) {
        let response = try roundTrip([
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": tool, "arguments": arguments]
        ])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return (
            isError: (result["isError"] as? Bool) ?? false,
            text: (content.first?["text"] as? String) ?? ""
        )
    }

    private func summary(tool: String, arguments: [String: Any]) throws -> [String: Any] {
        let response = try call(tool: tool, arguments: arguments)
        XCTAssertFalse(response.isError, "\(tool) failed: \(response.text)")
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(response.text.utf8)) as? [String: Any]
        )
    }

    private func toolSchema(named name: String) throws -> [String: Any] {
        let response = try roundTrip(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let tool = try XCTUnwrap(tools.first { ($0["name"] as? String) == name }, "\(name) must be advertised")
        return try XCTUnwrap(tool["inputSchema"] as? [String: Any])
    }

    // MARK: - Fixtures

    private var vault: DocumentVault { VaultTestSupport.vault(root: vaultDir) }

    private func stage(_ url: URL) throws -> String {
        try vault.stage(fileURL: url, stagedAtISO8601: Self.stagedAt).handle
    }

    private func stageText(_ contents: String, named name: String = "matter.txt") throws -> String {
        let url = workDir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return try stage(url)
    }

    /// A formatted agreement: a bold email, an italic tail, a bold phone, a
    /// date in the body, another date in the running header, and a styles part.
    private func stageAgreementDocx(named name: String = "Agreement.docx") throws -> (handle: String, url: URL) {
        let url = workDir.appendingPathComponent(name)
        try DocxFixtureSupport.write(
            paragraphs: [
                [.plain("Contact "), .bold(Self.email), .italic(" for details.")],
                [.plain("Phone "), .bold(Self.phone), .plain(" is on file until \(Self.bodyDate).")]
            ],
            header: [[.plain("Dated \(Self.headerDate)")]],
            to: url
        )
        return (try stage(url), url)
    }

    private func anonymize(_ handle: String) throws -> String {
        try XCTUnwrap(
            try summary(tool: "anonymize", arguments: ["handle": handle, "passphrase": passphrase])["redactedHandle"] as? String
        )
    }

    /// Decrypt a vault artifact to a scratch file the test owns (MCP clients never do this).
    private func plaintextCopy(of handle: String, extension ext: String) throws -> URL {
        let url = workDir.appendingPathComponent("copy-\(UUID().uuidString).\(ext)")
        try vault.readDocumentBytes(handle: handle).write(to: url)
        return url
    }

    private func listedHandleCount() throws -> Int {
        try XCTUnwrap(try summary(tool: "list_pending", arguments: [:])["documents"] as? [[String: Any]]).count
    }

    private func outboxNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: vault.outboxDirectory.path).sorted()
    }

    /// The bold run that holds `text`, exactly as Word would serialize it.
    private func boldRun(_ text: String) -> String {
        "<w:r><w:rPr><w:b/></w:rPr><w:t xml:space=\"preserve\">\(text)</w:t></w:r>"
    }

    // MARK: - Schema

    func testRestoreAdvertisesEditedHandleAsOptional() throws {
        let schema = try toolSchema(named: "restore")
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let editedHandle = try XCTUnwrap(properties["editedHandle"] as? [String: Any], "restore must advertise editedHandle")
        XCTAssertEqual(editedHandle["type"] as? String, "string")
        let description = try XCTUnwrap(editedHandle["description"] as? String)
        XCTAssertTrue(description.contains("editedText"), "the description must state the mutual exclusion")
        XCTAssertEqual(schema["required"] as? [String], ["redactedHandle"])
    }

    // MARK: - Unedited round trip

    func testARedactedDocxRestoresToTheOriginalTextWithUntouchedPartsByteIdentical() throws {
        let agreement = try stageAgreementDocx()
        let originalText = try DocxFixtureSupport.bodyText(of: agreement.url)
        let originalStyles = try DocxFixtureSupport.partData("word/styles.xml", in: agreement.url)

        let anonymized = try summary(tool: "anonymize", arguments: ["handle": agreement.handle, "passphrase": passphrase])
        let redactedHandle = try XCTUnwrap(anonymized["redactedHandle"] as? String)
        let entityCount = try XCTUnwrap(anonymized["entityCount"] as? Int)
        XCTAssertGreaterThanOrEqual(entityCount, 3, "fixture: email, phone, and date in the body")

        let redacted = try plaintextCopy(of: redactedHandle, extension: "docx")
        let redactedBody = try DocxFixtureSupport.part(docxMainPartPath, in: redacted)
        XCTAssertTrue(redactedBody.contains(boldRun("{EMAIL_1}")), "the token sits in the bold run: \(redactedBody)")
        XCTAssertFalse(redactedBody.contains(Self.email))
        XCTAssertTrue(try DocxFixtureSupport.part("word/header1.xml", in: redacted).contains("{DATE_"))
        XCTAssertEqual(try DocxFixtureSupport.partData("word/styles.xml", in: redacted), originalStyles)

        let restored = try summary(tool: "restore", arguments: ["redactedHandle": redactedHandle, "passphrase": passphrase])
        XCTAssertEqual(restored["format"] as? String, "docx", "\(restored)")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(restored["restoredCount"] as? Int), entityCount)
        XCTAssertEqual((restored["orphanTokens"] as? [String])?.isEmpty, true)
        XCTAssertEqual((restored["suspectPlaceholders"] as? [String])?.isEmpty, true)
        let restoredHandle = try XCTUnwrap(restored["restoredHandle"] as? String)
        XCTAssertTrue(restoredHandle.hasPrefix("res_"))
        XCTAssertEqual(try vault.entry(handle: restoredHandle).format, "docx")

        let restoredCopy = try plaintextCopy(of: restoredHandle, extension: "docx")
        XCTAssertEqual(try DocxFixtureSupport.bodyText(of: restoredCopy), originalText)
        let restoredBody = try DocxFixtureSupport.part(docxMainPartPath, in: restoredCopy)
        XCTAssertTrue(restoredBody.contains(boldRun(Self.email)), "the bold run comes back with its value: \(restoredBody)")
        XCTAssertTrue(restoredBody.contains(boldRun(Self.phone)))
        let restoredHeader = try DocxFixtureSupport.part("word/header1.xml", in: restoredCopy)
        XCTAssertTrue(restoredHeader.contains(Self.headerDate))
        XCTAssertFalse(restoredHeader.contains("{DATE_"))
        XCTAssertEqual(
            try DocxFixtureSupport.partData("word/styles.xml", in: restoredCopy),
            originalStyles,
            "untouched parts are copied byte for byte"
        )

        _ = try summary(tool: "export", arguments: ["handle": restoredHandle])
        XCTAssertEqual(try outboxNames(), ["Agreement_restored.docx"])
    }

    // MARK: - Edited round trip through editedHandle

    func testAnEditedDocxStagedByTheHumanRestoresWithFormattingThroughEditedHandle() throws {
        let agreement = try stageAgreementDocx()
        let originalStyles = try DocxFixtureSupport.partData("word/styles.xml", in: agreement.url)
        let redactedHandle = try anonymize(agreement.handle)

        // The human exports the redacted .docx, edits its wording in Word (the
        // italic tail changes, the tokens stay), and stages the edited file.
        let redactedCopy = try plaintextCopy(of: redactedHandle, extension: "docx")
        let edited = workDir.appendingPathComponent("Agreement-edited.docx")
        try DocxFixtureSupport.editingBody(
            of: redactedCopy,
            replacing: " for details.",
            with: " for the record.",
            to: edited
        )
        let editedHandle = try stage(edited)
        XCTAssertTrue(editedHandle.hasPrefix("doc_"))

        let restored = try summary(tool: "restore", arguments: [
            "redactedHandle": redactedHandle,
            "editedHandle": editedHandle,
            "passphrase": passphrase
        ])
        XCTAssertEqual(restored["format"] as? String, "docx", "\(restored)")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(restored["restoredCount"] as? Int), 3, "\(restored)")
        XCTAssertEqual((restored["orphanTokens"] as? [String])?.isEmpty, true, "\(restored)")
        XCTAssertEqual(restored["suspectPlaceholderCount"] as? Int, 0, "\(restored)")
        XCTAssertNil(restored["suspectPlaceholders"], "a human-staged original reports suspects as a count only")
        let restoredHandle = try XCTUnwrap(restored["restoredHandle"] as? String)
        XCTAssertEqual(try vault.entry(handle: restoredHandle).sourceHandle, editedHandle)

        let restoredCopy = try plaintextCopy(of: restoredHandle, extension: "docx")
        let text = try DocxFixtureSupport.bodyText(of: restoredCopy)
        XCTAssertTrue(text.contains(Self.email), text)
        XCTAssertTrue(text.contains(Self.phone), text)
        XCTAssertTrue(text.contains(Self.bodyDate), text)
        XCTAssertTrue(text.contains("for the record"), "the human's edit survives: \(text)")
        XCTAssertFalse(text.contains("for details"))
        XCTAssertFalse(text.contains("{"), "every token is restored: \(text)")

        let body = try DocxFixtureSupport.part(docxMainPartPath, in: restoredCopy)
        XCTAssertTrue(body.contains(boldRun(Self.email)), "the bold run keeps its w:rPr: \(body)")
        XCTAssertTrue(body.contains("<w:rPr><w:i/></w:rPr><w:t xml:space=\"preserve\"> for the record.</w:t>"), body)
        XCTAssertEqual(try DocxFixtureSupport.partData("word/styles.xml", in: restoredCopy), originalStyles)

        _ = try summary(tool: "export", arguments: ["handle": restoredHandle])
        XCTAssertEqual(try outboxNames(), ["Agreement-edited_restored.docx"])
    }

    // MARK: - Refusals

    func testEditedHandleRefusesARestoredArtifact() throws {
        let agreement = try stageAgreementDocx()
        let redactedHandle = try anonymize(agreement.handle)
        let restoredHandle = try XCTUnwrap(
            try summary(tool: "restore", arguments: ["redactedHandle": redactedHandle, "passphrase": passphrase])["restoredHandle"] as? String
        )
        let before = try listedHandleCount()

        let refused = try call(tool: "restore", arguments: [
            "redactedHandle": redactedHandle,
            "editedHandle": restoredHandle,
            "passphrase": passphrase
        ])

        XCTAssertTrue(refused.isError, "a restored artifact holds real values and is not an edit surface")
        XCTAssertTrue(refused.text.hasPrefix("not_an_edit_surface"), refused.text)
        XCTAssertTrue(refused.text.contains(restoredHandle), "the message names the handle")
        XCTAssertEqual(try listedHandleCount(), before, "a refused call writes nothing")
    }

    func testEditedHandleRefusesImagesAndPdfs() throws {
        let redactedHandle = try anonymize(try stageText("Mail \(Self.email) now."))
        let image = workDir.appendingPathComponent("signature.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: image)
        let pdf = workDir.appendingPathComponent("exhibit.pdf")
        try Data("%PDF-1.4".utf8).write(to: pdf)
        let imageHandle = try stage(image)
        let pdfHandle = try stage(pdf)
        let before = try listedHandleCount()

        for handle in [imageHandle, pdfHandle] {
            let refused = try call(tool: "restore", arguments: [
                "redactedHandle": redactedHandle,
                "editedHandle": handle,
                "passphrase": passphrase
            ])
            XCTAssertTrue(refused.isError, "\(handle) is not an edit surface")
            XCTAssertTrue(refused.text.hasPrefix("unsupported_format"), refused.text)
            XCTAssertTrue(refused.text.contains(handle), refused.text)
        }
        XCTAssertEqual(try listedHandleCount(), before)
    }

    func testEditedTextAndEditedHandleAreMutuallyExclusive() throws {
        let agreement = try stageAgreementDocx()
        let redactedHandle = try anonymize(agreement.handle)
        let before = try listedHandleCount()

        let refused = try call(tool: "restore", arguments: [
            "redactedHandle": redactedHandle,
            "editedText": "Contact {EMAIL_1} for details.",
            "editedHandle": redactedHandle,
            "passphrase": passphrase
        ])

        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.contains("editedText"), refused.text)
        XCTAssertTrue(refused.text.contains("editedHandle"), refused.text)
        XCTAssertEqual(try listedHandleCount(), before, "neither the edited text nor a restored artifact was written")
    }

    func testAnUnknownEditedHandleIsAnUnknownHandleError() throws {
        let redactedHandle = try anonymize(try stageText("Mail \(Self.email) now."))

        let refused = try call(tool: "restore", arguments: [
            "redactedHandle": redactedHandle,
            "editedHandle": "doc_000000000000",
            "passphrase": passphrase
        ])

        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.contains("unknown_handle"), refused.text)
        XCTAssertTrue(refused.text.contains("doc_000000000000"), refused.text)
    }

    // MARK: - The format field on every shape

    func testEveryRestoreShapeReportsItsFormat() throws {
        // Text artifact: stored and edited-text restores are text.
        let textRedacted = try anonymize(try stageText("Mail \(Self.email) now.", named: "note.txt"))
        let storedText = try summary(tool: "restore", arguments: ["redactedHandle": textRedacted, "passphrase": passphrase])
        XCTAssertEqual(storedText["format"] as? String, "txt", "\(storedText)")
        let editedText = try summary(tool: "restore", arguments: [
            "redactedHandle": textRedacted, "editedText": "Mail {EMAIL_1} today.", "passphrase": passphrase
        ])
        XCTAssertEqual(editedText["format"] as? String, "txt", "\(editedText)")

        // Docx artifact: stored and edited-handle restores are docx; editedText stays text.
        let agreement = try stageAgreementDocx()
        let docxRedacted = try anonymize(agreement.handle)
        let storedDocx = try summary(tool: "restore", arguments: ["redactedHandle": docxRedacted, "passphrase": passphrase])
        XCTAssertEqual(storedDocx["format"] as? String, "docx", "\(storedDocx)")
        let viaHandle = try summary(tool: "restore", arguments: [
            "redactedHandle": docxRedacted, "editedHandle": docxRedacted, "passphrase": passphrase
        ])
        XCTAssertEqual(viaHandle["format"] as? String, "docx", "a red_ handle is an accepted edit surface: \(viaHandle)")
        let docxAsText = try summary(tool: "restore", arguments: [
            "redactedHandle": docxRedacted, "editedText": "Contact {EMAIL_1} for details.", "passphrase": passphrase
        ])
        XCTAssertEqual(docxAsText["format"] as? String, "txt", "editedText restores to TEXT even for a docx: \(docxAsText)")

        // Session artifacts are Markdown and restore as Markdown.
        let first = try stageText("Filed by \(Self.email).", named: "complaint.txt")
        let second = try stageText("Reply to \(Self.email).", named: "annex.txt")
        let session = try summary(tool: "anonymize_session", arguments: ["handles": [first, second], "passphrase": passphrase])
        let documents = try XCTUnwrap(session["documents"] as? [[String: Any]])
        let markdownRedacted = try XCTUnwrap(documents[0]["redactedHandle"] as? String)
        let storedMarkdown = try summary(tool: "restore", arguments: ["redactedHandle": markdownRedacted, "passphrase": passphrase])
        XCTAssertEqual(storedMarkdown["format"] as? String, "md", "\(storedMarkdown)")
        let restoredMarkdown = try XCTUnwrap(storedMarkdown["restoredHandle"] as? String)
        XCTAssertEqual(try vault.entry(handle: restoredMarkdown).format, "md")
    }
}
