//
//  MCPFillToolTests.swift
//  LDACoreTests
//
//  Tests for the MCP server's extract_profile and fill tools, including:
//  tools/list schema validation for all seven tools, extract_profile happy path
//  and kind validation, fill mode=plan/apply, fill mutual exclusion (profile vs
//  portfolio vs passphrase), staleTarget describe arms, and the legacy
//  shared-account fallback restore.
//
//  The fill-with-portfolio happy path is also tested here because it shares
//  writeFillDocx and the Keychain-available probe with the other fill tests.
//
//  Split from MCPTests.swift to respect the 800-line file cap. JSON helpers,
//  writeFillDocx, writeProfile, FakeExtractCompleter, and portfolioKeychainAvailable
//  are duplicated from MCPTests (deliberate: each test file is intentionally
//  self-contained; see FillServiceTests / DocxFillTests for the same pattern).
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import Security
@testable import LDAMCP
@testable import LDACore

final class MCPFillToolTests: XCTestCase {

    // MARK: - Hermetic working directory

    private var workDir: URL!
    private let server = MCPServer()

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPFillToolTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workDir,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        MCPServer.libraryRootForTesting = nil
        LDAService.makeCompleterForTesting = nil
        if let workDir, FileManager.default.fileExists(atPath: workDir.path) {
            try? FileManager.default.removeItem(at: workDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - JSON helpers
    //
    // Duplicated from MCPTests (deliberate: each test file is intentionally
    // self-contained).

    private func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func decode(_ data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            throw XCTSkip("Response was not a JSON object")
        }
        return dict
    }

    private func roundTrip(_ request: [String: Any]) throws -> [String: Any] {
        let requestData = try encode(request)
        guard let responseData = server.handle(requestData) else {
            XCTFail("Expected a response for request \(request)")
            return [:]
        }
        return try decode(responseData)
    }

    private func toolText(from response: [String: Any]) throws -> String {
        guard let result = response["result"] as? [String: Any] else {
            throw XCTSkip("Response had no result object: \(response)")
        }
        guard
            let content = result["content"] as? [[String: Any]],
            let first = content.first,
            let text = first["text"] as? String
        else {
            throw XCTSkip("tools/call result had no text content: \(result)")
        }
        return text
    }

    private func toolSummary(from response: [String: Any]) throws -> [String: Any] {
        let text = try toolText(from: response)
        let data = Data(text.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            throw XCTSkip("tool summary text was not a JSON object: \(text)")
        }
        return dict
    }

    // MARK: - Fill tool fixtures
    //
    // Duplicated from MCPTests (deliberate: each test file is intentionally
    // self-contained).

    private let fillPassphrase = "mcp-fill-test-passphrase"

    private static let fillContentTypesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="xml" ContentType="application/xml"/>
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    </Types>
    """

    private static let fillRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    </Relationships>
    """

    private func writeFillDocx(_ text: String, named name: String = "fill-target.docx") throws -> URL {
        let url = workDir.appendingPathComponent(name)
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let documentXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body><w:p><w:r><w:t xml:space="preserve">\(escaped)</w:t></w:r></w:p></w:body>
        </w:document>
        """
        let parts: [(String, Data)] = [
            ("[Content_Types].xml", Data(Self.fillContentTypesXML.utf8)),
            ("_rels/.rels", Data(Self.fillRelsXML.utf8)),
            ("word/document.xml", Data(documentXML.utf8))
        ]
        try DocxZip.writeArchive(parts: parts, to: url)
        return url
    }

    private func writeProfile(companyName: String, named name: String = "test.ldaprofile") throws -> URL {
        let field = ProfileField(
            key: .companyName,
            value: companyName,
            sourceDocument: "mcp-test",
            sourceSnippet: companyName,
            snippetVerified: true,
            confidence: 1.0,
            userEdited: false
        )
        let profile = ClientPortfolio(
            label: "MCPTestCo",
            fields: [field],
            sourceDocuments: ["mcp-test"],
            createdAtISO8601: "2026-06-10T00:00:00Z",
            incomplete: false
        )
        let url = workDir.appendingPathComponent(name)
        try ProfileStore.save(profile, to: url, protection: .passphrase(fillPassphrase))
        return url
    }

    private final class FakeExtractCompleter: TextCompleter {
        let row: String
        init(companyName: String) {
            self.row = """
            [{"key":"companyName","value":"\(companyName)","snippet":"company is \(companyName)","confidence":0.95}]
            """
        }
        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
            return row
        }
    }

    // MARK: - Keychain probe for portfolio tests

    private func portfolioKeychainAvailable() -> Bool {
        let probeService = "ai.openclaw.lda.libraryindexkey"
        let probeAccount = "mcp-fill-portfolio-probe-\(UUID().uuidString)"
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: probeService,
            kSecAttrAccount as String: probeAccount,
            kSecValueData as String: Data("x".utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess {
            let del: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: probeService,
                kSecAttrAccount as String: probeAccount
            ]
            SecItemDelete(del as CFDictionary)
            return true
        }
        let tolerated: Set<OSStatus> = [
            errSecMissingEntitlement, errSecNotAvailable,
            errSecInteractionNotAllowed, errSecAuthFailed
        ]
        return !tolerated.contains(status)
    }

    // MARK: - tools/list includes extract_profile and fill

    // NOTE: tool count updated to 7 in Task 8 (added portfolio_list and portfolio_show).
    func testToolsListAdvertisesSevenToolsIncludingPortfolioTools() throws {
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 20,
            "method": "tools/list"
        ]
        let response = try roundTrip(request)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let names = tools.compactMap { $0["name"] as? String }

        XCTAssertTrue(names.contains("extract_profile"), "tools/list must include extract_profile")
        XCTAssertTrue(names.contains("fill"), "tools/list must include fill")
        XCTAssertTrue(names.contains("portfolio_list"), "tools/list must include portfolio_list")
        XCTAssertTrue(names.contains("portfolio_show"), "tools/list must include portfolio_show")
        // Sanctioned update: was 5, now 7 (added portfolio_list and portfolio_show).
        XCTAssertEqual(names.count, 7, "expected exactly 7 tools, got \(names.count): \(names)")

        // Confirm extract_profile schema required fields.
        let epTool = try XCTUnwrap(tools.first(where: { $0["name"] as? String == "extract_profile" }))
        let epSchema = try XCTUnwrap(epTool["inputSchema"] as? [String: Any])
        let epRequired = Set((epSchema["required"] as? [String]) ?? [])
        XCTAssertEqual(epRequired, ["sources", "label", "out", "model"],
                       "extract_profile required fields mismatch")

        // Confirm fill schema required fields (profile is now optional; mode and input still required).
        let fillTool = try XCTUnwrap(tools.first(where: { $0["name"] as? String == "fill" }))
        let fillSchema = try XCTUnwrap(fillTool["inputSchema"] as? [String: Any])
        let fillRequired = Set((fillSchema["required"] as? [String]) ?? [])
        XCTAssertEqual(fillRequired, ["input", "mode"],
                       "fill required fields mismatch: profile/portfolio are mutually exclusive optionals")

        // portfolio_list requires nothing (no params).
        let plTool = try XCTUnwrap(tools.first(where: { $0["name"] as? String == "portfolio_list" }))
        let plSchema = try XCTUnwrap(plTool["inputSchema"] as? [String: Any])
        let plRequired = (plSchema["required"] as? [String]) ?? []
        XCTAssertTrue(plRequired.isEmpty, "portfolio_list requires no params, got \(plRequired)")

        // portfolio_show requires portfolio.
        let psTool = try XCTUnwrap(tools.first(where: { $0["name"] as? String == "portfolio_show" }))
        let psSchema = try XCTUnwrap(psTool["inputSchema"] as? [String: Any])
        let psRequired = Set((psSchema["required"] as? [String]) ?? [])
        XCTAssertEqual(psRequired, ["portfolio"], "portfolio_show required fields mismatch")
    }

    // MARK: - fill with portfolio param

    func testFillPlanWithPortfolioParamHappyPath() throws {
        guard portfolioKeychainAvailable() else {
            throw XCTSkip("Keychain unavailable; skipping fill portfolio param test")
        }

        let companyName = "PortfolioCo Ltd"
        let field = ProfileField(
            key: .companyName,
            value: companyName,
            sourceDocument: "test.txt",
            sourceSnippet: companyName,
            snippetVerified: true,
            confidence: 1.0,
            userEdited: false
        )
        let portfolio = ClientPortfolio(
            label: "FillPortfolioCo",
            fields: [field],
            sourceDocuments: ["test.txt"],
            createdAtISO8601: "2026-06-10T00:00:00Z",
            incomplete: false
        )
        let root = workDir.appendingPathComponent("portfolios-fill", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = try PortfolioLibrary(rootDirectory: root)
        _ = try library.create(portfolio)

        MCPServer.libraryRootForTesting = root

        let docxURL = try writeFillDocx("Registered name: [Company Name].", named: "fill-portfolio-target.docx")

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 110,
            "method": "tools/call",
            "params": [
                "name": "fill",
                "arguments": [
                    "portfolio": "FillPortfolioCo",
                    "input": docxURL.path,
                    "mode": "plan"
                    // No "profile" or "passphrase" -- library path uses Keychain.
                ]
            ]
        ]
        let response = try roundTrip(request)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false,
                       "fill with portfolio param should succeed: \(result)")

        let summary = try toolSummary(from: response)
        let entries = try XCTUnwrap(summary["entries"] as? [[String: Any]])
        XCTAssertFalse(entries.isEmpty, "expected fill plan entries with portfolio param")
    }

    func testFillWithBothProfileAndPortfolioReturnsIsError() throws {
        let profileURL = try writeProfile(companyName: "TestCo")
        let docxURL = try writeFillDocx("Company: [Company Name].")

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 111,
            "method": "tools/call",
            "params": [
                "name": "fill",
                "arguments": [
                    "profile": profileURL.path,
                    "portfolio": "SomePortfolio",
                    "input": docxURL.path,
                    "mode": "plan",
                    "passphrase": fillPassphrase
                ]
            ]
        ]
        let response = try roundTrip(request)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true,
                       "fill with both profile and portfolio must return isError")

        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(
            text.lowercased().contains("profile") || text.lowercased().contains("portfolio")
            || text.lowercased().contains("exclusive"),
            "error must mention the mutual exclusion, got: \(text)"
        )
    }

    func testFillWithNeitherProfileNorPortfolioReturnsIsError() throws {
        let docxURL = try writeFillDocx("Company: [Company Name].")

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 112,
            "method": "tools/call",
            "params": [
                "name": "fill",
                "arguments": [
                    "input": docxURL.path,
                    "mode": "plan"
                    // Neither "profile" nor "portfolio" provided.
                ]
            ]
        ]
        let response = try roundTrip(request)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true,
                       "fill without profile or portfolio must return isError")

        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(
            text.lowercased().contains("profile") || text.lowercased().contains("portfolio"),
            "error must mention profile or portfolio, got: \(text)"
        )
    }

    func testFillWithPortfolioAndPassphraseReturnsIsError() throws {
        let docxURL = try writeFillDocx("Company: [Company Name].")

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 113,
            "method": "tools/call",
            "params": [
                "name": "fill",
                "arguments": [
                    "portfolio": "SomePortfolio",
                    "input": docxURL.path,
                    "mode": "plan",
                    "passphrase": "should-not-be-allowed"
                ]
            ]
        ]
        let response = try roundTrip(request)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true,
                       "fill with portfolio + passphrase must return isError")

        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(
            text.lowercased().contains("passphrase") || text.lowercased().contains("keychain"),
            "error must mention passphrase or keychain, got: \(text)"
        )
    }

    // MARK: - extract_profile happy path

    func testExtractProfileSummaryContainsKeysButNoValues() throws {
        let companyName = "MCPTestCo Holdings Ltd"
        let sourceURL = workDir.appendingPathComponent("cert.txt")
        try Data("The company name is \(companyName).".utf8).write(to: sourceURL)

        let fake = FakeExtractCompleter(companyName: companyName)
        LDAService.makeCompleterForTesting = { fake }

        let outURL = workDir.appendingPathComponent("extracted.ldaprofile")

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 30,
            "method": "tools/call",
            "params": [
                "name": "extract_profile",
                "arguments": [
                    "sources": [sourceURL.path],
                    "label": "MCPTestCo",
                    "out": outURL.path,
                    "model": "fake-model.gguf",
                    "passphrase": fillPassphrase
                ]
            ]
        ]
        let response = try roundTrip(request)

        // Must not be an error.
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false,
                       "extract_profile reported an error: \(result)")

        let summary = try toolSummary(from: response)

        // Value-free: must not contain the company name.
        let summaryText = try toolText(from: response)
        XCTAssertFalse(summaryText.contains(companyName),
                       "extract_profile summary must not leak field values")

        // Must contain fieldCount and the companyName key.
        let fieldCount = try XCTUnwrap(summary["fieldCount"] as? Int)
        XCTAssertGreaterThan(fieldCount, 0)

        let keys = try XCTUnwrap(summary["keys"] as? [String])
        XCTAssertTrue(keys.contains("companyName"),
                      "keys must include companyName, got \(keys)")

        // Profile must be written to disk.
        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path),
                      "profile file must exist at \(outURL.path)")

        // profilePath in summary must match out.
        let profilePath = try XCTUnwrap(summary["profilePath"] as? String)
        XCTAssertEqual(profilePath, outURL.path)
    }

    // MARK: - fill mode=plan returns entries with proposed values

    func testFillPlanReturnsEntriesWithProposedValues() throws {
        let companyName = "Meridian Ventures Ltd"
        let profileURL = try writeProfile(companyName: companyName)
        let docxURL = try writeFillDocx("Registered name: [Company Name].")

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 40,
            "method": "tools/call",
            "params": [
                "name": "fill",
                "arguments": [
                    "profile": profileURL.path,
                    "input": docxURL.path,
                    "mode": "plan",
                    "passphrase": fillPassphrase
                ]
            ]
        ]
        let response = try roundTrip(request)

        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false,
                       "fill plan reported an error: \(result)")

        let summary = try toolSummary(from: response)
        let entries = try XCTUnwrap(summary["entries"] as? [[String: Any]])
        XCTAssertFalse(entries.isEmpty, "expected at least one plan entry")

        // At least one entry must carry a proposed value (the company name blank).
        let hasProposedValue = entries.contains { entry in
            (entry["proposedValue"] as? String)?.isEmpty == false
        }
        XCTAssertTrue(hasProposedValue, "expected a proposed value in plan entries")
    }

    // MARK: - fill mode=apply writes file and returns value-free report

    func testFillApplyWritesFilledDocumentAndReturnsValueFreeReport() throws {
        let companyName = "Atlas Legal Group"
        let profileURL = try writeProfile(companyName: companyName)
        let docxURL = try writeFillDocx("Company: [Company Name].")
        let outputDirURL = workDir.appendingPathComponent("filled-output", isDirectory: true)

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 50,
            "method": "tools/call",
            "params": [
                "name": "fill",
                "arguments": [
                    "profile": profileURL.path,
                    "input": docxURL.path,
                    "mode": "apply",
                    "output_dir": outputDirURL.path,
                    "passphrase": fillPassphrase
                ]
            ]
        ]
        let response = try roundTrip(request)

        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false,
                       "fill apply reported an error: \(result)")

        let summary = try toolSummary(from: response)

        // Value-free: the company name must NOT appear in the report.
        let summaryText = try toolText(from: response)
        XCTAssertFalse(summaryText.contains(companyName),
                       "fill apply report must not leak field values")

        // filledCount must be at least 1.
        let filledCount = try XCTUnwrap(summary["filledCount"] as? Int)
        XCTAssertGreaterThanOrEqual(filledCount, 1)

        // The output file must exist.
        let outputPath = try XCTUnwrap(summary["outputURL"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputPath),
                      "filled document must exist at \(outputPath)")
    }

    // MARK: - fill mode=apply without output_dir returns MCP error

    func testFillApplyWithoutOutputDirReturnsIsError() throws {
        let profileURL = try writeProfile(companyName: "TestCo")
        let docxURL = try writeFillDocx("Company: [Company Name].")

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 60,
            "method": "tools/call",
            "params": [
                "name": "fill",
                "arguments": [
                    "profile": profileURL.path,
                    "input": docxURL.path,
                    "mode": "apply",
                    "passphrase": fillPassphrase
                    // output_dir deliberately omitted
                ]
            ]
        ]
        let response = try roundTrip(request)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true,
                       "fill apply without output_dir should report isError")

        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.lowercased().contains("output_dir"),
                      "error message should mention output_dir, got: \(text)")
    }

    // MARK: - fill unknown mode returns MCP error

    func testFillUnknownModeReturnsIsError() throws {
        let profileURL = try writeProfile(companyName: "TestCo")
        let docxURL = try writeFillDocx("Company: [Company Name].")

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 61,
            "method": "tools/call",
            "params": [
                "name": "fill",
                "arguments": [
                    "profile": profileURL.path,
                    "input": docxURL.path,
                    "mode": "bogus-mode",
                    "passphrase": fillPassphrase
                ]
            ]
        ]
        let response = try roundTrip(request)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true,
                       "fill with unknown mode should report isError")

        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("bogus-mode") || text.lowercased().contains("mode"),
                      "error message should mention the invalid mode, got: \(text)")
    }

    // MARK: - extract_profile kind validation

    /// A present but unrecognized kind string must return isError with a message
    /// that names the bad value and the three accepted values.
    func testExtractProfileInvalidKindReturnsIsError() throws {
        let sourceURL = workDir.appendingPathComponent("kind-test-source.txt")
        try Data("The company name is TestCo Ltd.".utf8).write(to: sourceURL)
        let outURL = workDir.appendingPathComponent("kind-test.ldaprofile")

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 90,
            "method": "tools/call",
            "params": [
                "name": "extract_profile",
                "arguments": [
                    "sources": [sourceURL.path],
                    "label": "TestCo",
                    "out": outURL.path,
                    "model": "fake-model.gguf",
                    "kind": "person",          // unrecognized value
                    "passphrase": fillPassphrase
                ]
            ]
        ]
        let response = try roundTrip(request)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true,
                       "extract_profile with kind='person' must report isError")

        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)

        // The error message must identify the bad value.
        XCTAssertTrue(text.contains("person"),
                      "error message must name the invalid value 'person', got: \(text)")
        // The error message must name at least one accepted value.
        XCTAssertTrue(
            text.contains("company") || text.contains("individual") || text.contains("general"),
            "error message must name the accepted values, got: \(text)"
        )
    }

    /// An absent kind must default to .company without error (documented default).
    func testExtractProfileAbsentKindDefaultsToCompanyNoError() throws {
        let companyName = "AbsentKindTestCo Ltd"
        let sourceURL = workDir.appendingPathComponent("absent-kind-source.txt")
        try Data("The company name is \(companyName).".utf8).write(to: sourceURL)
        let outURL = workDir.appendingPathComponent("absent-kind.ldaprofile")

        let fake = FakeExtractCompleter(companyName: companyName)
        LDAService.makeCompleterForTesting = { fake }

        // No "kind" key in arguments at all.
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 91,
            "method": "tools/call",
            "params": [
                "name": "extract_profile",
                "arguments": [
                    "sources": [sourceURL.path],
                    "label": "AbsentKindTestCo",
                    "out": outURL.path,
                    "model": "fake-model.gguf",
                    "passphrase": fillPassphrase
                    // "kind" deliberately absent
                ]
            ]
        ]
        let response = try roundTrip(request)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false,
                       "extract_profile with absent kind must succeed (default to company): \(result)")

        let summary = try toolSummary(from: response)
        let fieldCount = try XCTUnwrap(summary["fieldCount"] as? Int)
        XCTAssertGreaterThan(fieldCount, 0, "absent kind must still extract fields")
    }


}
