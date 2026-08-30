//
//  ImageEntryPointTests.swift
//  LDACoreTests
//
//  Wiring tests for standalone image input at the product edges: the zip
//  expansion allow-list, the CLI anonymize summary, the CLI vault stage
//  intake, and the MCP handle flow over a staged image. Core behavior is
//  covered by LDAServiceImageTests; these tests prove the entry points reach
//  that behavior.
//
//  Tests whose names start with testOCRRoundTrip_ run live Vision and are the
//  slow ones, so a future CI split can shard on the name.
//
//  House rules: all comments and strings in English (fixture content contains
//  Chinese by design). No em-dash and no en-dash-as-separator anywhere.
//

import XCTest
import ZIPFoundation
@testable import LDACore
@testable import LDACLI
@testable import LDAMCP

final class ImageEntryPointTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageEntryPointTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        ZipImporter.cleanUpAllExpansions()
        if let workDir, FileManager.default.fileExists(atPath: workDir.path) {
            try? FileManager.default.removeItem(at: workDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Zip expansion allow-list

    /// A zip of evidence images expands them alongside the documents: image
    /// extensions are part of the session allow-list.
    func testZipExpansionIncludesImageEntries() throws {
        let zipURL = workDir.appendingPathComponent("evidence.zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        let entries: [(String, Data)] = [
            ("contract.txt", Data("Acme Corp agrees.".utf8)),
            ("chat.png", Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])),
            ("receipt.jpg", Data([0xFF, 0xD8, 0xFF, 0xE0])),
            ("scan.jpeg", Data([0xFF, 0xD8, 0xFF, 0xE1]))
        ]
        for (path, data) in entries {
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                provider: { position, size in
                    data.subdata(in: Int(position)..<Int(position) + size)
                }
            )
        }

        let documents = try ZipImporter.expand(zipURL).documents
        let names = Set(documents.map { $0.lastPathComponent })

        XCTAssertEqual(names, ["contract.txt", "chat.png", "receipt.jpg", "scan.jpeg"])
    }

    // MARK: - CLI anonymize summary

    /// The CLI JSON summary carries the redacted image path for image input,
    /// and null for document input, so scripts can pick up both artifacts.
    func testAnonymizeSummaryJSONCarriesRedactedImageURL() throws {
        let base = AnonymizeResult(
            redactedFileURL: URL(fileURLWithPath: "/out/receipt_redacted.txt"),
            mappingFileURL: URL(fileURLWithPath: "/out/receipt_redacted.ldamap"),
            visualPdfURL: nil,
            entityCount: 3,
            entities: [],
            imageRedactionCount: 3,
            redactedImageURL: URL(fileURLWithPath: "/out/receipt_redacted.png")
        )

        let summary = AnonymizeSummaryJSON(result: base)
        XCTAssertEqual(summary.redactedImageURL, "/out/receipt_redacted.png")

        let document = AnonymizeResult(
            redactedFileURL: URL(fileURLWithPath: "/out/a_redacted.txt"),
            mappingFileURL: URL(fileURLWithPath: "/out/a_redacted.ldamap"),
            visualPdfURL: nil,
            entityCount: 0,
            entities: []
        )
        XCTAssertNil(AnonymizeSummaryJSON(result: document).redactedImageURL)
    }

    /// The single-input CLI anonymize path routes an image end to end: both
    /// artifacts land in the output directory and the summary names them.
    func testOCRRoundTrip_runAnonymizeOverAnImageProducesBothArtifacts() throws {
        let input = try ImageFixtureRenderer.writePNG(lines: [
            "原告：张伟，电话\(ImageTextExtractorTests.plantedPhone)"
        ])
        defer { try? FileManager.default.removeItem(at: input) }
        let outputDir = workDir.appendingPathComponent("out", isDirectory: true)

        let result = try LDACLI.runAnonymize(
            input: input,
            outputDir: outputDir,
            passphrase: "test-passphrase",
            timestamp: { "2026-08-30T12:00:00Z" }
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.redactedFileURL.path))
        let imageURL = try XCTUnwrap(result.redactedImageURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path))
        XCTAssertEqual(imageURL.deletingLastPathComponent().path, outputDir.path)

        let redactedText = try String(contentsOf: result.redactedFileURL, encoding: .utf8)
        XCTAssertFalse(
            ImageFixtureRenderer.digitsOnly(redactedText).contains(ImageTextExtractorTests.plantedPhone),
            "phone leaked into the CLI redacted text"
        )
        XCTAssertTrue(redactedText.contains("{PHONE_"))
    }

    // MARK: - Vault stage intake plus the MCP handle flow

    /// The whole agent-facing path over an image: the human stages a PNG with
    /// the CLI (the vault stores it under its normalized format, which is txt
    /// today), the agent anonymizes by handle, and read_redacted returns
    /// placeholder text with none of the planted values. Magic-byte dispatch
    /// inside the service is what makes the stored-as-txt image OCR instead
    /// of decoding as mojibake; this test pins that end to end.
    func testOCRRoundTrip_vaultStagedImageAnonymizesThroughMCPHandles() throws {
        let vaultDir = workDir.appendingPathComponent("vault", isDirectory: true)
        let png = try ImageFixtureRenderer.writePNG(lines: [
            "原告：张伟，电话\(ImageTextExtractorTests.plantedPhone)",
            "邮箱 \(ImageTextExtractorTests.plantedEmail)"
        ])
        defer { try? FileManager.default.removeItem(at: png) }

        // Human intake: CLI staging.
        let staged = try LDACLI.runVaultStage(
            inputs: [png],
            vaultRoot: vaultDir,
            timestamp: { "2026-08-30T12:00:00Z" }
        )
        XCTAssertEqual(staged.count, 1)
        let handle = try XCTUnwrap(staged.first?.handle)

        // Agent flow: anonymize by handle, then read the redacted text.
        let server = MCPServer(environment: [DocumentVault.environmentKey: vaultDir.path])

        let anonymized = try callSummary(server, tool: "anonymize", arguments: [
            "handle": handle,
            "passphrase": "test-passphrase"
        ])
        let redactedHandle = try XCTUnwrap(anonymized["redactedHandle"] as? String)
        XCTAssertGreaterThanOrEqual(anonymized["entityCount"] as? Int ?? 0, 2)

        let read = try callSummary(server, tool: "read_redacted", arguments: [
            "handle": redactedHandle
        ])
        let text = try XCTUnwrap(read["text"] as? String)
        XCTAssertTrue(text.contains("{PHONE_"), "redacted text must carry placeholders: \(text)")
        XCTAssertFalse(
            ImageFixtureRenderer.digitsOnly(text).contains(ImageTextExtractorTests.plantedPhone),
            "phone leaked through the MCP surface"
        )
        XCTAssertFalse(text.lowercased().contains("zhangwei"), "email leaked through the MCP surface")
    }

    // MARK: - MCP helpers (local to this suite)

    private func callSummary(
        _ server: MCPServer,
        tool: String,
        arguments: [String: Any]
    ) throws -> [String: Any] {
        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": tool, "arguments": arguments]
        ]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        let responseData = try XCTUnwrap(server.handle(requestData))
        let response = try XCTUnwrap(
            JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = (content.first?["text"] as? String) ?? ""
        XCTAssertNotEqual(result["isError"] as? Bool, true, "\(tool) failed: \(text)")
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }
}
