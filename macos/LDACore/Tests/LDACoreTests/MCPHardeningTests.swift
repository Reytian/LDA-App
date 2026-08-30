//
//  MCPHardeningTests.swift
//  LDACoreTests
//
//  Two edges of the MCP server that are not about a tool's output:
//
//   - stdio framing, including the request-line size cap that stops a client
//     from growing the accumulation buffer without bound;
//   - the GGUF model-path policy, which every model-taking tool (handle-first
//     and legacy alike) must enforce BEFORE the engine touches the file.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import Security
@testable import LDACore
@testable import LDAMCP

final class MCPHardeningTests: XCTestCase {

    private var workDir: URL!
    private var vaultDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPHardeningTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        vaultDir = workDir.appendingPathComponent("vault", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let workDir, FileManager.default.fileExists(atPath: workDir.path) {
            try FileManager.default.removeItem(at: workDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Stdio framing

    func testCompleteLinesAreSplitOut() {
        let step = MCPServer.consume(
            buffer: Data(),
            appending: Data("{\"a\":1}\n{\"b\":2}\n".utf8)
        )

        XCTAssertEqual(step.lines.count, 2)
        XCTAssertEqual(String(decoding: step.lines[0], as: UTF8.self), "{\"a\":1}")
        XCTAssertEqual(String(decoding: step.lines[1], as: UTF8.self), "{\"b\":2}")
        XCTAssertTrue(step.buffer.isEmpty)
        XCTAssertFalse(step.oversizeDiscarded)
    }

    func testAPartialLineStaysBuffered() {
        // A request may arrive across several reads; the tail must be kept.
        let first = MCPServer.consume(buffer: Data(), appending: Data("{\"a\":".utf8))
        XCTAssertTrue(first.lines.isEmpty)
        XCTAssertFalse(first.oversizeDiscarded)

        let second = MCPServer.consume(buffer: first.buffer, appending: Data("1}\n".utf8))
        XCTAssertEqual(second.lines.count, 1)
        XCTAssertEqual(String(decoding: second.lines[0], as: UTF8.self), "{\"a\":1}")
    }

    func testAnOversizePartialLineIsDiscarded() {
        // No newline and past the cap: the bytes are dropped and the caller is
        // told to report a parse error, rather than the buffer growing until the
        // process dies.
        let oversize = Data(repeating: UInt8(ascii: "x"), count: MCPServer.maxRequestLineBytes + 1)

        let step = MCPServer.consume(buffer: Data(), appending: oversize)

        XCTAssertTrue(step.oversizeDiscarded)
        XCTAssertTrue(step.lines.isEmpty)
        XCTAssertTrue(step.buffer.isEmpty, "the accumulated bytes must not be retained")
    }

    func testAnOversizeBufferThatDoesContainANewlineIsStillFramed() {
        // The cap is about unbounded accumulation, not about refusing a large
        // chunk that happens to hold complete lines.
        var chunk = Data(repeating: UInt8(ascii: "x"), count: MCPServer.maxRequestLineBytes + 1)
        chunk.append(UInt8(ascii: "\n"))

        let step = MCPServer.consume(buffer: Data(), appending: chunk)

        XCTAssertFalse(step.oversizeDiscarded)
        XCTAssertEqual(step.lines.count, 1)
    }

    func testBufferGrowthIsBoundedAcrossManyChunks() {
        // The realistic attack is a stream of chunks with no newline. Whatever
        // the pattern, the retained buffer must stay bounded.
        var buffer = Data()
        let chunk = Data(repeating: UInt8(ascii: "x"), count: 1024 * 1024)
        for _ in 0 ..< 20 {
            let step = MCPServer.consume(buffer: buffer, appending: chunk)
            buffer = step.buffer
        }
        XCTAssertLessThanOrEqual(buffer.count, MCPServer.maxRequestLineBytes)
    }

    func testTheCapIsWellAboveARealRequest() {
        // Requests carry paths and options, never document bytes.
        XCTAssertGreaterThanOrEqual(MCPServer.maxRequestLineBytes, 1024 * 1024)
    }

    // MARK: - Call helper

    /// Send one tools/call through the given server (default: a vault-scoped
    /// server with the legacy gate closed) and return its content text.
    private func callText(
        tool: String,
        arguments: [String: Any],
        via server: MCPServer? = nil
    ) throws -> (isError: Bool, text: String) {
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": ["name": tool, "arguments": arguments]
        ]
        let payload = try JSONSerialization.data(withJSONObject: request)
        let effectiveServer = server
            ?? MCPServer(environment: VaultTestSupport.serverEnvironment(vaultDir: vaultDir))
        let responseData = try XCTUnwrap(effectiveServer.handle(payload))
        let response = try XCTUnwrap(
            JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return (
            isError: (result["isError"] as? Bool) ?? false,
            text: (content.first?["text"] as? String) ?? ""
        )
    }

    /// Stage one text document into this test's vault and return its handle.
    private func stageFixture() throws -> String {
        let input = workDir.appendingPathComponent("doc.txt")
        try Data("Mail someone@example.com now.".utf8).write(to: input)
        return try VaultTestSupport.vault(root: vaultDir)
            .stage(fileURL: input, stagedAtISO8601: "2026-08-30T00:00:00Z")
            .handle
    }

    // MARK: - Model path policy

    /// Every tool that takes a GGUF model path must reject one outside the
    /// allowed roots BEFORE the engine touches the file. /Library/Caches is
    /// writable by other software yet inside no allowed root, which is exactly
    /// the staged-malicious-model case the policy exists for. The handle-first
    /// tools and the gated legacy tools are both covered.
    func testEveryModelTakingToolRejectsAModelOutsideTheAllowedRoots() throws {
        let handle = try stageFixture()
        let input = workDir.appendingPathComponent("doc.txt")
        let planted = "/Library/Caches/planted.gguf"

        let vaultServer = MCPServer(
            environment: VaultTestSupport.serverEnvironment(vaultDir: vaultDir)
        )
        let legacyServer = MCPServer(environment: VaultTestSupport.serverEnvironment(
            vaultDir: vaultDir,
            extra: [MCPServer.legacyPathToolsEnvironmentKey: "1"]
        ))

        let calls: [(tool: String, key: String, arguments: [String: Any], server: MCPServer)] = [
            ("detect_entities", "modelPath",
             ["handle": handle, "modelPath": planted], vaultServer),
            ("anonymize", "modelPath",
             ["handle": handle, "modelPath": planted], vaultServer),
            ("anonymize_session", "modelPath",
             ["handles": [handle], "modelPath": planted], vaultServer),
            ("extract_profile", "model",
             ["sources": [input.path], "label": "L",
              "out": workDir.appendingPathComponent("p.ldaprofile").path,
              "model": planted], legacyServer),
            ("fill", "model",
             ["input": input.path, "mode": "plan",
              "profile": workDir.appendingPathComponent("missing.ldaprofile").path,
              "model": planted], legacyServer)
        ]

        for call in calls {
            let response = try callText(
                tool: call.tool,
                arguments: call.arguments,
                via: call.server
            )
            XCTAssertTrue(
                response.isError,
                "\(call.tool) must reject the planted model, got: \(response.text)"
            )
            XCTAssertTrue(
                response.text.contains(call.key),
                "\(call.tool): the message must name the offending argument, got: \(response.text)"
            )
            XCTAssertTrue(
                response.text.contains("allowed directories for GGUF models"),
                "\(call.tool): the rejection must come from the model path policy, "
                    + "not from the engine failing to read the file, got: \(response.text)"
            )
            // The handle-first surface additionally never echoes the path.
            if MCPServer.vaultToolNames.contains(call.tool) {
                XCTAssertFalse(
                    response.text.contains(planted),
                    "\(call.tool): the boundary-safe message must not echo the path, "
                        + "got: \(response.text)"
                )
            }
        }
    }

    /// A model path inside the roots is NOT rejected by the policy: detection
    /// proceeds (deterministic-only when the file is absent, per makeDetector's
    /// documented fallback), which proves the gate lets legitimate paths
    /// through rather than being an accidental blanket.
    func testAModelPathInsideTheRootsPassesThePolicy() throws {
        let handle = try stageFixture()
        let missingButAllowed = workDir.appendingPathComponent("missing.gguf").path

        let response = try callText(tool: "detect_entities", arguments: [
            "handle": handle,
            "modelPath": missingButAllowed
        ])

        XCTAssertFalse(response.isError, "an in-root model path must pass, got: \(response.text)")
        XCTAssertFalse(
            response.text.contains("allowed directories for GGUF models"),
            "an in-root model path must not trip the policy, got: \(response.text)"
        )
    }
}
