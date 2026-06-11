//
//  SessionEdgeTests.swift
//  LDACoreTests
//
//  Edge tests for the multi-document session feature: the CLI session path
//  (several --input documents and .zip expansion, one shared sidecar) and the
//  MCP anonymize_session tool. Hermetic: fixtures live under
//  FileManager.temporaryDirectory, and sidecars use passphrase protection so
//  the unsigned test process never needs Keychain access.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import ZIPFoundation
@testable import LDACLI
@testable import LDAMCP
@testable import LDACore

final class SessionEdgeTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionEdgeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    private func write(_ name: String, _ content: String) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    // MARK: - CLI session path

    func testCLISessionWritesIntermediatesAndOneSidecar() throws {
        let doc1 = try write("a.txt", "Mail john@acme.com please.")
        let doc2 = try write("b.txt", "Also john@acme.com and mary@beta.io.")
        let outDir = workDir.appendingPathComponent("out")

        let summary = try LDACLI.runAnonymizeSession(
            inputs: [doc1, doc2],
            outputDir: outDir,
            passphrase: "pw",
            timestamp: { "2026-06-11T00:00:00Z" }
        )

        XCTAssertEqual(summary.documents.count, 2)
        XCTAssertEqual(summary.totalEntityCount, 3)
        XCTAssertTrue(summary.mappingFile.hasSuffix("a_session.ldamap"))

        // The shared address carries ONE token across both intermediates.
        let md1 = try String(
            contentsOf: URL(fileURLWithPath: summary.documents[0].redactedFile),
            encoding: .utf8
        )
        let md2 = try String(
            contentsOf: URL(fileURLWithPath: summary.documents[1].redactedFile),
            encoding: .utf8
        )
        XCTAssertTrue(md1.contains("{EMAIL_1}"))
        XCTAssertTrue(md2.contains("{EMAIL_1}"))
        XCTAssertTrue(md2.contains("{EMAIL_2}"))
        XCTAssertFalse(md1.contains("john@acme.com"))

        // The single sidecar restores both documents.
        let mappingURL = URL(fileURLWithPath: summary.mappingFile)
        let restored1 = try LDAService.restoreText(md1, mapping: mappingURL, protection: .passphrase("pw"))
        XCTAssertEqual(restored1.text, "Mail john@acme.com please.")
        let restored2 = try LDAService.restoreText(md2, mapping: mappingURL, protection: .passphrase("pw"))
        XCTAssertEqual(restored2.text, "Also john@acme.com and mary@beta.io.")
    }

    func testCLIResolveSessionInputsExpandsZip() throws {
        let zipURL = workDir.appendingPathComponent("bundle.zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        let data = Data("Reach mary@beta.io today.".utf8)
        try archive.addEntry(
            with: "inner.txt",
            type: .file,
            uncompressedSize: Int64(data.count),
            provider: { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        )
        let plain = try write("plain.txt", "Nothing here.")

        let resolved = try LDACLI.resolveSessionInputs([plain, zipURL])

        XCTAssertEqual(resolved.count, 2)
        XCTAssertEqual(resolved[0].lastPathComponent, "plain.txt")
        XCTAssertEqual(resolved[1].lastPathComponent, "inner.txt")
    }

    // MARK: - MCP anonymize_session tool

    func testMCPAnonymizeSessionToolSharesOneMapping() throws {
        let doc1 = try write("a.txt", "Mail john@acme.com please.")
        let doc2 = try write("b.txt", "Also john@acme.com again.")
        let outDir = workDir.appendingPathComponent("mcp-out")

        let server = MCPServer()
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 7,
            "method": "tools/call",
            "params": [
                "name": "anonymize_session",
                "arguments": [
                    "inputs": [doc1.path, doc2.path],
                    "outputDir": outDir.path,
                    "passphrase": "pw"
                ]
            ]
        ]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        guard let responseData = server.handle(requestData) else {
            return XCTFail("anonymize_session returned no response")
        }
        let response = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertNotEqual(result["isError"] as? Bool, true, "tool errored: \(result)")
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let summary = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )

        let documents = try XCTUnwrap(summary["documents"] as? [[String: Any]])
        XCTAssertEqual(documents.count, 2)
        let mappingFile = try XCTUnwrap(summary["mappingFile"] as? String)
        XCTAssertTrue(mappingFile.hasSuffix("a_session.ldamap"))

        // Both intermediates share the {EMAIL_1} identity.
        for document in documents {
            let path = try XCTUnwrap(document["redactedFile"] as? String)
            let markdown = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
            XCTAssertTrue(markdown.contains("{EMAIL_1}"))
            XCTAssertFalse(markdown.contains("john@acme.com"))
        }
    }

    func testMCPToolListAdvertisesAnonymizeSession() throws {
        let names = MCPServer.toolDescriptors.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("anonymize_session"))
    }
}
