//
//  MCPPathPolicyTests.swift
//  LDACoreTests
//
//  The MCP path allow-list. Every path in a request is a plain string from
//  stdin, often assembled from a model's output, so the tools must refuse paths
//  outside the places a user's own documents live.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAMCP

final class MCPPathPolicyTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPPathPolicyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir, FileManager.default.fileExists(atPath: workDir.path) {
            try FileManager.default.removeItem(at: workDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Allowed locations

    func testTheTemporaryDirectoryIsAllowed() {
        // Tests, the app's own .zip expansions, and MCP host scratch space all
        // live here, so the policy is useless if it excludes it.
        XCTAssertTrue(MCPPathPolicy.isAllowed(workDir))
        XCTAssertTrue(MCPPathPolicy.isAllowed(workDir.appendingPathComponent("doc.docx")))
    }

    func testTheHomeDirectoryIsAllowed() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertTrue(MCPPathPolicy.isAllowed(home.appendingPathComponent("Documents/matter.docx")))
    }

    func testAPathThatDoesNotExistYetIsJudgedByItsParent() {
        // An output file has not been written when the policy runs, so an
        // unwritten path inside an allowed directory must be accepted.
        let output = workDir.appendingPathComponent("nested/deeper/out.docx")
        XCTAssertTrue(MCPPathPolicy.isAllowed(output))
    }

    // MARK: - Refused locations

    func testASystemPathIsRefused() {
        XCTAssertFalse(MCPPathPolicy.isAllowed(URL(fileURLWithPath: "/etc/ssh/ssh_host_rsa_key")))
        XCTAssertFalse(MCPPathPolicy.isAllowed(URL(fileURLWithPath: "/Library/Keychains")))
    }

    func testAnotherUsersHomeIsRefused() {
        XCTAssertFalse(MCPPathPolicy.isAllowed(URL(fileURLWithPath: "/Users/someone-else/Documents/x.docx")))
    }

    func testTraversalOutOfAnAllowedRootIsRefused() {
        // Normalization has to happen before the prefix comparison, or "..\" gets
        // you anywhere.
        let escape = workDir.appendingPathComponent("../../../../etc/passwd")
        XCTAssertFalse(MCPPathPolicy.isAllowed(escape))
    }

    func testASymlinkOutOfAnAllowedRootIsRefused() throws {
        // A link inside an allowed directory must not become a way to read
        // outside one.
        let link = workDir.appendingPathComponent("link-to-etc")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: URL(fileURLWithPath: "/etc")
        )
        XCTAssertFalse(
            MCPPathPolicy.isAllowed(link.appendingPathComponent("passwd")),
            "a symlink inside an allowed root must not widen the root"
        )
    }

    // MARK: - Extension by environment

    func testExtraRootsFromTheEnvironmentAreHonored() {
        let environment = [MCPPathPolicy.extraRootsEnvironmentKey: "/Volumes/CaseFiles"]
        XCTAssertTrue(
            MCPPathPolicy.isAllowed(
                URL(fileURLWithPath: "/Volumes/CaseFiles/matter/brief.docx"),
                environment: environment
            )
        )
        XCTAssertFalse(
            MCPPathPolicy.isAllowed(
                URL(fileURLWithPath: "/Volumes/Other/brief.docx"),
                environment: environment
            )
        )
    }

    func testAnEmptyEnvironmentEntryIsIgnored() {
        let environment = [MCPPathPolicy.extraRootsEnvironmentKey: "::  ::"]
        XCTAssertFalse(MCPPathPolicy.isAllowed(URL(fileURLWithPath: "/etc/passwd"), environment: environment))
    }

    // MARK: - Enforcement surfaces in the tools

    /// Send one tools/call and return the decoded result object.
    private func call(tool: String, arguments: [String: Any]) throws -> [String: Any] {
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": ["name": tool, "arguments": arguments]
        ]
        let payload = try JSONSerialization.data(withJSONObject: request)
        let responseData = try XCTUnwrap(MCPServer().handle(payload))
        let response = try XCTUnwrap(
            JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
        return try XCTUnwrap(response["result"] as? [String: Any])
    }

    func testAnonymizeRefusesAnInputOutsideTheAllowedRoots() throws {
        let result = try call(tool: "anonymize_document", arguments: [
            "input": "/etc/hosts",
            "outputDir": workDir.path
        ])

        XCTAssertEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = (content.first?["text"] as? String) ?? ""
        XCTAssertTrue(
            text.contains("outside the allowed directories"),
            "the refusal should say why, got: \(text)"
        )
    }

    func testAnonymizeRefusesAnOutputDirectoryOutsideTheAllowedRoots() throws {
        let source = workDir.appendingPathComponent("brief.txt")
        try Data("Acme Corp".utf8).write(to: source)

        let result = try call(tool: "anonymize_document", arguments: [
            "input": source.path,
            "outputDir": "/Library/LDAOutput"
        ])

        XCTAssertEqual(result["isError"] as? Bool, true)
    }

    func testDetectRefusesAPathOutsideTheAllowedRoots() throws {
        let result = try call(tool: "detect_entities", arguments: ["input": "/etc/hosts"])
        XCTAssertEqual(result["isError"] as? Bool, true)
    }

    func testAnAllowedPathStillWorks() throws {
        // The policy must not break the normal case.
        let source = workDir.appendingPathComponent("brief.txt")
        try Data("Contact jane@example.test about the matter.".utf8).write(to: source)

        let result = try call(tool: "detect_entities", arguments: ["input": source.path])

        XCTAssertNotEqual(result["isError"] as? Bool, true)
    }
}
