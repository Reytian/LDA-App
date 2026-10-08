import XCTest
@testable import LDACore
@testable import LDAMCP

/// Opt-in smoke coverage for local user-provided demo packages. Inputs and text never enter test output.
final class LocalDemoWordSmokeTests: XCTestCase {
    func testLocalDemoPackages() throws {
        guard let inputPath = ProcessInfo.processInfo.environment["LDA_DEMO_SMOKE_INPUT_DIR"],
              let outputPath = ProcessInfo.processInfo.environment["LDA_DEMO_SMOKE_OUTPUT_DIR"] else {
            throw XCTSkip("Set local demo input and output directories to run this smoke test")
        }
        let inputs = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: inputPath), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "docx" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(inputs.isEmpty)
        let output = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let vault = VaultTestSupport.vault(root: output.appendingPathComponent("vault"))
        var server = MCPServer(environment: VaultTestSupport.serverEnvironment(vaultDir: vault.rootDirectory))
        server.selectDocumentsForTesting = { .init(urls: inputs, review: true) }
        server.chooseWorkspaceForTesting = { _ in nil }
        // Supply one deterministic local-review selection so even a patterns-only
        // document without dates or email addresses exercises placeholder restoration.
        server.localReviewDetectionForTesting = { _ in [] }
        server.reviewDocumentForTesting = { text, _ in
            guard let range = text.range(of: "[A-Za-z]{4,}", options: .regularExpression) else { return [] }
            return [CustomPattern(text: String(text[range]), type: .person)]
        }
        server.prepareMappingPassphraseForTesting = "local-smoke-only"
        server.runEditedImportForTesting = { work in try work { _ in } }
        var receipt: ExportReceipt?
        server.presentExportForTesting = { value, saved in XCTAssertTrue(saved); receipt = value; return "shown" }
        var responses: [String] = []
        func call(_ name: String, _ args: [String: Any]) throws -> [String: Any] {
            let request: [String: Any] = ["jsonrpc": "2.0", "id": responses.count, "method": "tools/call", "params": ["name": name, "arguments": args]]
            let data = try XCTUnwrap(server.handle(JSONSerialization.data(withJSONObject: request)))
            responses.append(String(decoding: data, as: UTF8.self))
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let result = try XCTUnwrap(envelope["result"] as? [String: Any])
            XCTAssertNotEqual(result["isError"] as? Bool, true, "Tool failed: \(name)")
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            if result["isError"] as? Bool == true { throw NSError(domain: "MCP demo smoke: " + name + ": " + (content.first?["text"] as? String ?? "unknown failure"), code: 1) }
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(content.first?["text"] as? String).utf8)) as? [String: Any])
        }
        let preparation = try call("prepare_documents", [:])
        let documents = try XCTUnwrap(preparation["documents"] as? [[String: Any]])
        XCTAssertEqual(documents.count, inputs.count)
        var summaries: [[String: Any]] = []
        for (index, document) in documents.enumerated() {
            XCTAssertEqual(document["format"] as? String, "docx")
            let handle = try XCTUnwrap(document["redactedHandle"] as? String)
            _ = try call("export", ["handle": handle])
            let redacted = try XCTUnwrap(receipt?.fileURL)
            let firstID = receipt?.id
            _ = try call("export", ["handle": handle])
            XCTAssertNotEqual(receipt?.id, firstID)
            XCTAssertNotEqual(receipt?.fileURL, redacted)
            server.selectEditedDocumentForTesting = { _ in redacted }
            let imported = try call("import_edited_document", ["redactedHandle": handle])
            XCTAssertEqual(imported["trackedChanges"] as? String, "none_detected")
            let edited = try XCTUnwrap(imported["editedHandle"] as? String)
            let restored = try call("restore", ["redactedHandle": handle, "editedHandle": edited, "passphrase": "local-smoke-only"])
            XCTAssertEqual(restored["orphanTokens"] as? [String], [])
            XCTAssertEqual(restored["suspectPlaceholderCount"] as? Int, 0)
            XCTAssertEqual(restored["ambiguousReplacements"] as? [String], [])
            _ = try call("export", ["handle": try XCTUnwrap(restored["restoredHandle"] as? String)])
            let result = try XCTUnwrap(receipt?.fileURL)
            XCTAssertTrue(try DocxFixtureSupport.part("word/document.xml", in: result) == DocxFixtureSupport.part("word/document.xml", in: inputs[index]), "Restored main XML differs from the demo input")
            XCTAssertTrue(try DocxFixtureSupport.partData("word/styles.xml", in: result) == DocxFixtureSupport.partData("word/styles.xml", in: inputs[index]), "Word styles changed")
            let copy = output.appendingPathComponent(String(format: "%02d-restored.docx", index + 1))
            try FileManager.default.copyItem(at: result, to: copy)
            summaries.append(["document": index + 1, "format": "docx", "restoredCount": restored["restoredCount"] ?? 0, "structureExact": true, "orphanTokens": 0, "suspectPlaceholders": 0])
        }
        let wire = responses.joined(separator: "\n")
        for input in inputs { XCTAssertFalse(wire.contains(input.lastPathComponent)); XCTAssertFalse(wire.contains(input.path)) }
        XCTAssertFalse(wire.contains("local-smoke-only"))
        try JSONSerialization.data(withJSONObject: summaries, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("summary.json"))
    }
}
