//
//  MCPSupplementaryCoverageTests.swift
//  LDACoreTests
//
//  The handle-first surface's half of the supplementary coverage fix.
//
//  A DOCX is redacted in its headers, footers, notes, and comments as well as
//  its body, but detect_entities and anonymize used to report the body count
//  alone. An agent auditing coverage there saw no header entities at all and
//  could conclude those values had leaked.
//
//  The boundary rule this pins is narrow on purpose: supplementary
//  information crosses the wire as TYPE NAMES AND INTEGER COUNTS ONLY. No
//  surface text, no offsets, no part names, no filenames, no paths, and no
//  ids, because a supplementary entity is not excludable and an id that
//  cannot be used is only a disclosure.
//
//  Deterministic detection only, hermetic temp-rooted vault, passphrase
//  sidecars: nothing here touches the Keychain or a GGUF model.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDAMCP
@testable import LDACore

final class MCPSupplementaryCoverageTests: XCTestCase {

    private var workDir: URL!
    private var vaultDir: URL!
    private var server: MCPServer!

    private let passphrase = "mcp-coverage-passphrase"
    private static let stagedAt = "2026-09-03T00:00:00Z"

    private static let bodyEmail = "alice@example.com"
    private static let bodyDate = "2024-01-15"
    private static let headerPhone = "13800138000"
    private static let footerEmail = "bob@example.com"
    /// Body: email, date. Header: phone. Footer: a second email.
    private static let bodySiteCount = 2
    private static let supplementarySiteCount = 2

    override func setUpWithError() throws {
        try super.setUpWithError()
        assertNoTestSeamsInstalled()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPSupplementaryCoverage-\(UUID().uuidString)", isDirectory: true)
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

    private func responseText(tool: String, arguments: [String: Any]) throws -> String {
        let response = try roundTrip([
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": tool, "arguments": arguments]
        ])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertNotEqual(result["isError"] as? Bool, true, "\(tool) failed: \(content)")
        return (content.first?["text"] as? String) ?? ""
    }

    private func summary(tool: String, arguments: [String: Any]) throws -> [String: Any] {
        let text = try responseText(tool: tool, arguments: arguments)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func toolDescription(named name: String) throws -> String {
        let response = try roundTrip(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let tool = try XCTUnwrap(tools.first { ($0["name"] as? String) == name })
        return try XCTUnwrap(tool["description"] as? String)
    }

    // MARK: - Fixture

    private func stageAgreement() throws -> String {
        let url = workDir.appendingPathComponent("Agreement.docx")
        try DocxTestPackage.write(
            body: DocxTestPackage.paragraph(
                DocxTestPackage.run("Contact \(Self.bodyEmail) on \(Self.bodyDate).")
            ) + DocxTestPackage.sectionWithHeaderAndFooter,
            extraParts: [
                (
                    "word/header1.xml",
                    DocxTestPackage.wordPart(
                        rootTag: "hdr",
                        body: DocxTestPackage.paragraph(
                            DocxTestPackage.run("Reception \(Self.headerPhone)")
                        )
                    )
                ),
                (
                    "word/footer1.xml",
                    DocxTestPackage.wordPart(
                        rootTag: "ftr",
                        body: DocxTestPackage.paragraph(
                            DocxTestPackage.run("Enquiries \(Self.footerEmail)")
                        )
                    )
                )
            ],
            to: url
        )
        return try VaultTestSupport.vault(root: vaultDir)
            .stage(fileURL: url, stagedAtISO8601: Self.stagedAt).handle
    }

    /// Nothing in a response may name a supplementary value, a part, or a path.
    private func assertNoSupplementaryDisclosure(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        for secret in [Self.headerPhone, Self.footerEmail, Self.bodyEmail, Self.bodyDate] {
            XCTAssertFalse(text.contains(secret), "response discloses \(secret)", file: file, line: line)
        }
        for leak in ["header1", "footer1", "word/", ".xml", ".docx", "Agreement", workDir.path] {
            XCTAssertFalse(text.contains(leak), "response discloses \(leak)", file: file, line: line)
        }
    }

    // MARK: - detect_entities

    func testDetectEntitiesReportsSupplementaryCoverageAsCountsOnly() throws {
        let handle = try stageAgreement()

        let text = try responseText(tool: "detect_entities", arguments: ["handle": handle])
        let response = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )

        let entities = try XCTUnwrap(response["entities"] as? [[String: Any]])
        XCTAssertEqual(entities.count, Self.bodySiteCount, "the entity list stays body only")
        XCTAssertEqual(response["supplementaryEntityCount"] as? Int, Self.supplementarySiteCount)
        XCTAssertEqual(
            response["entityCount"] as? Int,
            Self.bodySiteCount + Self.supplementarySiteCount,
            "the headline number must cover the header and the footer too"
        )
        XCTAssertEqual(
            response["supplementaryPerTypeCounts"] as? [String: Int],
            ["PHONE": 1, "EMAIL": 1]
        )
        // Type names and counts only: a supplementary hit gets no id, because
        // it cannot be excluded and an unusable id is only a disclosure.
        for entity in entities {
            XCTAssertNotNil(entity["id"] as? String)
        }
        assertNoSupplementaryDisclosure(text)
    }

    // MARK: - anonymize

    func testAnonymizeReportsTheHonestTotalAndTheSplit() throws {
        let handle = try stageAgreement()

        let text = try responseText(
            tool: "anonymize",
            arguments: ["handle": handle, "passphrase": passphrase]
        )
        let response = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )

        XCTAssertEqual(response["supplementaryEntityCount"] as? Int, Self.supplementarySiteCount)
        XCTAssertEqual(
            response["entityCount"] as? Int,
            Self.bodySiteCount + Self.supplementarySiteCount
        )
        XCTAssertEqual(
            response["supplementaryPerTypeCounts"] as? [String: Int],
            ["PHONE": 1, "EMAIL": 1]
        )
        let types = try XCTUnwrap(response["entityTypes"] as? [String])
        XCTAssertEqual(Set(types), ["EMAIL", "DATE", "PHONE"], "PHONE exists only in the header")
        assertNoSupplementaryDisclosure(text)
    }

    func testAnonymizeTotalMatchesWhatARestorePutsBack() throws {
        let handle = try stageAgreement()

        let anonymized = try summary(
            tool: "anonymize",
            arguments: ["handle": handle, "passphrase": passphrase]
        )
        let redactedHandle = try XCTUnwrap(anonymized["redactedHandle"] as? String)
        let entityCount = try XCTUnwrap(anonymized["entityCount"] as? Int)

        let restored = try summary(
            tool: "restore",
            arguments: ["redactedHandle": redactedHandle, "passphrase": passphrase]
        )
        XCTAssertEqual(
            restored["restoredCount"] as? Int, entityCount,
            "the coverage a caller is shown and the coverage a restore proves must agree"
        )
    }

    // MARK: - anonymize_session

    func testSessionReportsNoSupplementaryCoverageBecauseItHandsOverMarkdown() throws {
        let handle = try stageAgreement()

        let response = try summary(
            tool: "anonymize_session",
            arguments: ["handles": [handle], "passphrase": passphrase]
        )

        XCTAssertEqual(
            response["supplementaryEntityCount"] as? Int, 0,
            "session mode writes Markdown of the body, so no header is carried over"
        )
        XCTAssertEqual(response["totalEntityCount"] as? Int, Self.bodySiteCount)
    }

    // MARK: - Descriptors

    func testDescriptorsExplainTheAsymmetryToAnAgentReadingOnlyTheSchema() throws {
        let detect = try toolDescription(named: "detect_entities")
        XCTAssertTrue(
            detect.contains("supplementaryEntityCount"),
            "an agent reading only the schema must learn the field exists: \(detect)"
        )
        XCTAssertTrue(
            detect.contains("entityCount"),
            "and that entityCount is larger than the entity list: \(detect)"
        )

        let anonymize = try toolDescription(named: "anonymize")
        XCTAssertTrue(anonymize.contains("supplementaryEntityCount"), anonymize)

        let session = try toolDescription(named: "anonymize_session")
        XCTAssertTrue(session.contains("supplementaryEntityCount"), session)
    }
}
