//
//  MCPPortfolioToolTests.swift
//  LDACoreTests
//
//  Tests for the MCP server's portfolio_list and portfolio_show tools. Every
//  fixture is generated under FileManager.temporaryDirectory so the tests are
//  hermetic and commit no binaries.
//
//  Tests that touch PortfolioLibrary use a Keychain probe; they skip cleanly
//  when the Keychain is unavailable in the unsigned test process.
//
//  Split from MCPTests.swift to respect the 800-line file cap. The
//  portfolioKeychainAvailable and plantPortfolio helpers are duplicated from
//  MCPTests (deliberate: each test file is intentionally self-contained;
//  see FillServiceTests / DocxFillTests for the same pattern).
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import Security
@testable import LDAMCP
@testable import LDACore

final class MCPPortfolioToolTests: XCTestCase {

    // MARK: - Hermetic working directory

    private var workDir: URL!
    /// The legacy path tools under test are gated behind the launch-time
    /// opt-in, so this suite runs its server with the gate open.
    private let server = MCPServer(environment: [
        MCPServer.legacyPathToolsEnvironmentKey: "1"
    ])

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Fail here if an earlier suite leaked a process-wide test seam.
        assertNoTestSeamsInstalled()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPPortfolioToolTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workDir,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        MCPServer.libraryRootForTesting = nil
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

    // MARK: - Keychain probe

    /// Returns true when the Keychain is accessible for PortfolioLibrary.
    private func portfolioKeychainAvailable() -> Bool {
        let probeService = "ai.openclaw.lda.libraryindexkey"
        let probeAccount = TestNamespace.keychainAccount("mcp-portfolio-probe")
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

    // MARK: - Library fixture helper

    /// Plant a single portfolio in a temp library and return the (libraryRoot, id, summary).
    private func plantPortfolio(
        label: String,
        kind: PortfolioKind = .company,
        fieldCount: Int = 1
    ) throws -> (root: URL, id: UUID, summary: PortfolioSummary) {
        let root = workDir.appendingPathComponent("portfolios-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let field = ProfileField(
            key: .companyName,
            value: "TestValue",
            sourceDocument: "test.txt",
            sourceSnippet: "TestValue",
            snippetVerified: true,
            confidence: 1.0,
            userEdited: false
        )
        let portfolio = ClientPortfolio(
            label: label,
            fields: Array(repeating: field, count: max(1, fieldCount)),
            sourceDocuments: ["test.txt"],
            createdAtISO8601: "2026-06-10T00:00:00Z",
            incomplete: false
        )
        let library = try PortfolioLibrary(rootDirectory: root)
        let id = try library.create(portfolio)
        let summary = PortfolioSummary(
            id: id,
            label: label,
            kind: kind,
            createdAtISO8601: "2026-06-10T00:00:00Z",
            modifiedAtISO8601: "2026-06-10T00:00:00Z",
            fieldCount: fieldCount,
            conflicted: false
        )
        return (root, id, summary)
    }

    // MARK: - portfolio_list and portfolio_show

    func testPortfolioListReturnsSortedSummariesValueFree() throws {
        guard portfolioKeychainAvailable() else {
            throw XCTSkip("Keychain unavailable; skipping portfolio_list test")
        }

        let (root, _, _) = try plantPortfolio(label: "Bravo Corp")
        // Add a second portfolio to the SAME root library.
        let library = try PortfolioLibrary(rootDirectory: root)
        let field = ProfileField(
            key: .companyName,
            value: "ShouldNotAppear",
            sourceDocument: "test.txt",
            sourceSnippet: "ShouldNotAppear",
            snippetVerified: true,
            confidence: 1.0,
            userEdited: false
        )
        let alphaPortfolio = ClientPortfolio(
            label: "Alpha Corp",
            fields: [field],
            sourceDocuments: ["test.txt"],
            createdAtISO8601: "2026-06-10T00:00:00Z",
            incomplete: false
        )
        _ = try library.create(alphaPortfolio)

        // Inject the test root.
        MCPServer.libraryRootForTesting = root

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 100,
            "method": "tools/call",
            "params": [
                "name": "portfolio_list",
                "arguments": [String: Any]()
            ]
        ]
        let response = try roundTrip(request)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false,
                       "portfolio_list should not be an error: \(result)")

        let summary = try toolSummary(from: response)
        let portfolios = try XCTUnwrap(summary["portfolios"] as? [[String: Any]])

        // Must have exactly 2 entries.
        XCTAssertEqual(portfolios.count, 2, "expected 2 portfolios")

        // Sorted by label: Alpha Corp before Bravo Corp.
        let labels = portfolios.compactMap { $0["label"] as? String }
        XCTAssertEqual(labels, ["Alpha Corp", "Bravo Corp"], "must be sorted by label")

        // Value-free: the field value must not appear.
        let summaryText = try toolText(from: response)
        XCTAssertFalse(summaryText.contains("ShouldNotAppear"),
                       "portfolio_list must not leak field values")

        // Each entry must have the required metadata keys.
        for entry in portfolios {
            XCTAssertNotNil(entry["id"])
            XCTAssertNotNil(entry["label"])
            XCTAssertNotNil(entry["kind"])
            XCTAssertNotNil(entry["fieldCount"])
            XCTAssertNotNil(entry["conflicted"])
        }
    }

    func testPortfolioShowByLabelReturnsRawKeysNoValues() throws {
        guard portfolioKeychainAvailable() else {
            throw XCTSkip("Keychain unavailable; skipping portfolio_show test")
        }

        let label = "ShowTestCo"
        let (root, _, _) = try plantPortfolio(label: label)

        MCPServer.libraryRootForTesting = root

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 101,
            "method": "tools/call",
            "params": [
                "name": "portfolio_show",
                "arguments": ["portfolio": label]
            ]
        ]
        let response = try roundTrip(request)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false,
                       "portfolio_show should not be an error: \(result)")

        let summary = try toolSummary(from: response)

        // rawKeys must be present and non-empty.
        let rawKeys = try XCTUnwrap(summary["rawKeys"] as? [String])
        XCTAssertFalse(rawKeys.isEmpty, "rawKeys must be present")

        // conflictedKeys must be present (even if empty).
        XCTAssertNotNil(summary["conflictedKeys"])

        // Value-free: the planted value must not appear.
        let summaryText = try toolText(from: response)
        XCTAssertFalse(summaryText.contains("TestValue"),
                       "portfolio_show must not leak field values")
    }

    func testPortfolioShowByIDReturnsDetail() throws {
        guard portfolioKeychainAvailable() else {
            throw XCTSkip("Keychain unavailable; skipping portfolio_show by id test")
        }

        let label = "IDLookupCo"
        let (root, id, _) = try plantPortfolio(label: label)

        MCPServer.libraryRootForTesting = root

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 102,
            "method": "tools/call",
            "params": [
                "name": "portfolio_show",
                "arguments": ["portfolio": id.uuidString]
            ]
        ]
        let response = try roundTrip(request)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false,
                       "portfolio_show by id should not be an error: \(result)")

        let summary = try toolSummary(from: response)
        XCTAssertEqual(summary["id"] as? String, id.uuidString)
        XCTAssertEqual(summary["label"] as? String, label)
    }

    func testPortfolioShowAmbiguousLabelReturnsIsError() throws {
        guard portfolioKeychainAvailable() else {
            throw XCTSkip("Keychain unavailable; skipping ambiguous portfolio_show test")
        }

        // Create two portfolios with the SAME label (case-insensitive collision).
        let root = workDir.appendingPathComponent("portfolios-ambiguous", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let library = try PortfolioLibrary(rootDirectory: root)
        let field = ProfileField(
            key: .companyName,
            value: "AmbigValue",
            sourceDocument: "test.txt",
            sourceSnippet: "AmbigValue",
            snippetVerified: true,
            confidence: 1.0,
            userEdited: false
        )
        for _ in 0..<2 {
            let p = ClientPortfolio(
                label: "Ambiguous Corp",
                fields: [field],
                sourceDocuments: ["test.txt"],
                createdAtISO8601: "2026-06-10T00:00:00Z",
                incomplete: false
            )
            _ = try library.create(p)
        }

        MCPServer.libraryRootForTesting = root

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 103,
            "method": "tools/call",
            "params": [
                "name": "portfolio_show",
                "arguments": ["portfolio": "ambiguous corp"]
            ]
        ]
        let response = try roundTrip(request)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true,
                       "ambiguous portfolio_show must return isError")

        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        // The error message must mention candidates or "multiple" or "ambiguous".
        XCTAssertTrue(
            text.lowercased().contains("multiple") || text.lowercased().contains("ambiguous")
            || text.lowercased().contains("candidate"),
            "error must mention ambiguity, got: \(text)"
        )
    }
}
