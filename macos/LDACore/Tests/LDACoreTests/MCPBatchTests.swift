//
//  MCPBatchTests.swift
//  LDACoreTests
//
//  The batch_anonymize MCP tool and its local handoff: the request URL is a
//  fixed route that carries nothing but an id and a time, the tool takes no
//  arguments, the result holds an outcome and counts only, and the app side
//  answers each request once with what its next batch did.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAMCP
@testable import LDAUI

final class MCPBatchTests: XCTestCase {
    private var vaultDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        vaultDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPBatchTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let vaultDir {
            try? FileManager.default.removeItem(at: vaultDir)
        }
        vaultDir = nil
        try super.tearDownWithError()
    }

    // MARK: - The request URL

    func testTheRequestURLCarriesOnlyAnIdAndATime() throws {
        let request = MCPBatchRequest()
        let decoded = try XCTUnwrap(MCPBatchRequest(url: request.url))

        XCTAssertEqual(request.url.scheme, "lda-mcp")
        XCTAssertEqual(request.url.host, "batch-anonymize")
        XCTAssertEqual(decoded.id, request.id)
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.map(\.name), ["created"])
    }

    func testOtherRoutesExtraFieldsAndOldRequestsAreRefused() throws {
        let request = MCPBatchRequest()
        for extra in ["path=/Users/a", "created=1", "folder=x"] {
            XCTAssertNil(MCPBatchRequest(url: try XCTUnwrap(URL(string: request.url.absoluteString + "&" + extra))))
        }
        var components = try XCTUnwrap(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        components.scheme = "https"
        XCTAssertNil(MCPBatchRequest(url: try XCTUnwrap(components.url)))
        components.scheme = "lda-mcp"
        components.host = "choose-workspace"
        XCTAssertNil(MCPBatchRequest(url: try XCTUnwrap(components.url)))
        components.host = "batch-anonymize"
        components.path = "/extra" + components.path
        XCTAssertNil(MCPBatchRequest(url: try XCTUnwrap(components.url)))

        let later = request.createdAt.addingTimeInterval(MCPBatchRequest.lifetime + 1)
        XCTAssertNil(MCPBatchRequest(url: request.url, now: later))
        XCTAssertNil(MCPBatchRequest(url: request.url, now: request.createdAt.addingTimeInterval(-10)))
        XCTAssertTrue(request.canBeAnswered(at: later))
        XCTAssertFalse(request.canBeAnswered(at: request.createdAt.addingTimeInterval(MCPBatchRequest.answerWindow)))
    }

    // MARK: - The tool

    private func server(reply: MCPBatchReply?) -> (MCPServer, () -> MCPBatchRequest?) {
        var server = MCPServer(environment: VaultTestSupport.serverEnvironment(vaultDir: vaultDir))
        var seen: MCPBatchRequest?
        server.batchAnonymizeForTesting = { request in
            seen = request
            return reply.map {
                MCPBatchReply(requestID: request.id, outcome: $0.outcome, report: nil)
            }
        }
        return (server, { seen })
    }

    private func call(_ server: MCPServer, arguments: [String: Any]) throws -> (text: String, isError: Bool) {
        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "batch_anonymize", "arguments": arguments]
        ]
        let data = try XCTUnwrap(server.handle(try JSONSerialization.data(withJSONObject: request)))
        let envelope = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return (try XCTUnwrap(content.first?["text"] as? String), result["isError"] as? Bool == true)
    }

    func testTheToolIsAdvertisedWithNoArguments() throws {
        let descriptor = try XCTUnwrap(MCPServer.vaultToolDescriptors.first { $0["name"] as? String == "batch_anonymize" })
        let schema = try XCTUnwrap(descriptor["inputSchema"] as? [String: Any])
        XCTAssertEqual((schema["properties"] as? [String: Any])?.count, 0)
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertTrue(MCPServer.vaultToolNames.contains("batch_anonymize"))
    }

    func testAnyArgumentIsRefusedWithoutEchoingIt() throws {
        let (server, seen) = server(reply: nil)

        let response = try call(server, arguments: ["folder": "/Users/someone/Clients"])

        XCTAssertTrue(response.isError)
        XCTAssertTrue(response.text.contains("invalid_arguments"), response.text)
        XCTAssertFalse(response.text.contains("/Users/someone"), response.text)
        XCTAssertNil(seen(), "the window must not open for a refused call")
    }

    private func item(
        _ source: String,
        _ status: BatchItem.Status,
        autoProtected: Int = 0,
        reason: String? = nil
    ) -> BatchItem {
        BatchItem(
            source: source, status: status, replacedCount: 0, autoProtectedValueCount: autoProtected,
            unboxedTokenCount: 0, embeddedMediaCount: 0, trackedChangeCount: 0, seconds: 0,
            reason: reason, sourceSize: 0, sourceModified: 0
        )
    }

    func testAFinishedBatchReturnsTheOutcomeAndCountsOnly() throws {
        let report = BatchReport(
            format: BatchReport.currentFormat,
            startedAt: "2026-10-28T00:00:00Z",
            sourceFolderName: "Clients",
            detection: "LDA V4",
            style: "token",
            mappingProtection: "keychain",
            unlocatedPolicy: "protect",
            cancelled: false,
            items: [
                item("a/Jordan Lee.docx", .done, autoProtected: 2),
                item("b.txt", .skipped),
                item("c.pdf", .failed, reason: "Jordan Lee could not be located"),
            ]
        )
        var server = MCPServer(environment: VaultTestSupport.serverEnvironment(vaultDir: vaultDir))
        server.batchAnonymizeForTesting = { request in
            MCPBatchReply(requestID: request.id, outcome: .finished, report: report)
        }

        let response = try call(server, arguments: [:])

        XCTAssertFalse(response.isError, response.text)
        let summary = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(response.text.utf8)) as? [String: Any])
        XCTAssertEqual(
            Set(summary.keys),
            ["outcome", "documentCount", "writtenCount", "skippedCount", "failedCount", "autoProtectedValueCount", "note"]
        )
        XCTAssertEqual(summary["outcome"] as? String, "finished")
        XCTAssertEqual(summary["documentCount"] as? Int, 3)
        XCTAssertEqual(summary["writtenCount"] as? Int, 1)
        XCTAssertEqual(summary["skippedCount"] as? Int, 1)
        XCTAssertEqual(summary["failedCount"] as? Int, 1)
        XCTAssertEqual(summary["autoProtectedValueCount"] as? Int, 2)
        for leak in ["Jordan", "Clients", "a/", "b.txt", "c.pdf"] {
            XCTAssertFalse(response.text.contains(leak), "\(leak) reached the AI: \(response.text)")
        }
    }

    func testAWindowStillOpenReportsStillOpen() throws {
        let (server, seen) = server(reply: nil)

        let response = try call(server, arguments: [:])

        XCTAssertFalse(response.isError, response.text)
        let summary = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(response.text.utf8)) as? [String: Any])
        XCTAssertEqual(summary["outcome"] as? String, "still_open")
        XCTAssertEqual(seen()?.url.host, "batch-anonymize")
    }

    // MARK: - The app side

    @MainActor
    func testTheNextBatchAnswersTheRequestOnce() {
        var sent: [MCPBatchReply] = []
        let handoff = MCPBatchHandoff(send: { sent.append($0) })
        let request = MCPBatchRequest()

        handoff.receive(request)
        XCTAssertEqual(sent.map(\.outcome), [.opened])
        XCTAssertEqual(handoff.pending, request)

        let claimed = handoff.claim()
        XCTAssertEqual(claimed, request)
        XCTAssertNil(handoff.pending)
        handoff.answer(request, .finished)
        handoff.windowClosed()

        XCTAssertEqual(sent.map(\.outcome), [.opened, .finished], "a claimed request is not answered again")
        XCTAssertTrue(sent.allSatisfy { $0.requestID == request.id })
    }

    @MainActor
    func testAClosedWindowANewerRequestAndARunningBatchEachAnswer() {
        var sent: [MCPBatchReply] = []
        let handoff = MCPBatchHandoff(send: { sent.append($0) })
        let first = MCPBatchRequest()
        let second = MCPBatchRequest()

        handoff.receive(first)
        handoff.receive(second)
        XCTAssertEqual(sent.map(\.outcome), [.opened, .closed, .opened])
        XCTAssertEqual(sent[1].requestID, first.id)

        handoff.windowClosed()
        XCTAssertEqual(sent.last?.outcome, .closed)
        XCTAssertEqual(sent.last?.requestID, second.id)

        handoff.isBatchRunning = true
        let third = MCPBatchRequest()
        handoff.receive(third)
        XCTAssertEqual(sent.last?.outcome, .busy)
        XCTAssertNil(handoff.pending)
    }

    @MainActor
    func testARequestTheHelperGaveUpOnIsNotClaimed() {
        let handoff = MCPBatchHandoff(send: { _ in })
        let request = MCPBatchRequest()
        handoff.receive(request)

        let late = request.createdAt.addingTimeInterval(MCPBatchRequest.answerWindow + 1)
        XCTAssertNil(handoff.claim(at: late))
        XCTAssertNil(handoff.pending)
    }
}
