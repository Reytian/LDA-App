//
//  CLIPortfolioTests.swift
//  LDACoreTests
//
//  Tests for the LDACLI portfolio helpers: runPortfolioList, runPortfolioShow,
//  and fill --portfolio argument validation and happy path. Every fixture is
//  generated under FileManager.temporaryDirectory; no binaries are committed.
//
//  Tests that touch PortfolioLibrary probe the Keychain before executing and
//  throw XCTSkip when the Keychain is unavailable in the unsigned test process.
//  ArgumentParser validation tests do not require Keychain access.
//
//  Duplicated from CLITests (deliberate: each test file is intentionally
//  self-contained following the DocxFillTests / DocxIOTests pattern).
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import Security
@testable import LDACLI
@testable import LDACore

final class CLIPortfolioTests: XCTestCase {
    private var tempDir: URL!
    private let fixedTimestamp = "2026-06-06T00:00:00Z"

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIPortfolioTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Keychain probe helper

    /// Returns false when the Keychain is accessible for the library service.
    /// Returns true when the test should be skipped (Keychain unavailable).
    private func keychainUnavailable() -> Bool {
        let probeService = "ai.openclaw.lda.libraryindexkey"
        let probeAccount = TestNamespace.keychainAccount("cli-portfolio-probe")
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: probeService,
            kSecAttrAccount as String: probeAccount,
            kSecValueData as String: Data("probe".utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        let tolerated: Set<OSStatus> = [
            errSecMissingEntitlement,
            errSecNotAvailable,
            errSecInteractionNotAllowed,
            errSecAuthFailed
        ]
        if status == errSecSuccess {
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: probeService,
                kSecAttrAccount as String: probeAccount
            ]
            SecItemDelete(deleteQuery as CFDictionary)
        }
        return tolerated.contains(status)
    }

    // MARK: - Library fixture helpers

    /// Build a minimal ClientPortfolio with the given label, kind, and one field
    /// containing the given value. Saves it into the library and returns the UUID.
    private func plantPortfolio(
        in library: PortfolioLibrary,
        label: String,
        kind: PortfolioKind = .company,
        fieldValue: String = "Planted Value"
    ) throws -> UUID {
        let field = ProfileField(
            key: .companyName,
            value: fieldValue,
            sourceDocument: "test.txt",
            sourceSnippet: fieldValue,
            snippetVerified: true,
            confidence: 0.9,
            userEdited: false
        )
        let portfolio = ClientPortfolio(
            label: label,
            fields: [field],
            sourceDocuments: ["test.txt"],
            createdAtISO8601: fixedTimestamp,
            incomplete: false,
            kind: kind,
            modifiedAtISO8601: fixedTimestamp
        )
        return try library.create(portfolio)
    }

    // MARK: - DOCX fixture helper (for fill --portfolio happy path)

    // Duplicated from CLITests (deliberate: each test file is intentionally
    // self-contained following the DocxFillTests / DocxIOTests pattern).

    private static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="xml" ContentType="application/xml"/>
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    </Types>
    """

    private static let relsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    </Relationships>
    """

    /// Write a minimal DOCX containing the given raw text in a single paragraph.
    private func writeDocxWithText(_ text: String, named name: String? = nil) throws -> URL {
        let fileName = name ?? "cliportfolio-\(UUID().uuidString).docx"
        let url = tempDir.appendingPathComponent(fileName)
        let escapedText = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let documentXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body><w:p><w:r><w:t xml:space="preserve">\(escapedText)</w:t></w:r></w:p></w:body>
        </w:document>
        """
        let parts: [(String, Data)] = [
            ("[Content_Types].xml", Data(Self.contentTypesXML.utf8)),
            ("_rels/.rels", Data(Self.relsXML.utf8)),
            ("word/document.xml", Data(documentXML.utf8))
        ]
        try DocxZip.writeArchive(parts: parts, to: url)
        return url
    }

    // MARK: - runPortfolioList: value-free, sorted

    func testPortfolioListIsValueFreeAndSorted() throws {
        if keychainUnavailable() {
            throw XCTSkip("Keychain unavailable; skipping portfolio list test")
        }
        let libRoot = tempDir.appendingPathComponent("lib-list", isDirectory: true)
        try FileManager.default.createDirectory(at: libRoot, withIntermediateDirectories: true)
        let library = try PortfolioLibrary(rootDirectory: libRoot)

        let plantedValue = "PLANTED_SECRET_VALUE_MUST_NOT_APPEAR"
        _ = try plantPortfolio(in: library, label: "Bravo Corp", fieldValue: plantedValue)
        _ = try plantPortfolio(in: library, label: "Alpha Ltd")

        let summaries = try LDACLI.runPortfolioList(libraryRoot: libRoot)
        let json = try CLIJSON.encode(summaries)

        // The planted value must not appear in the JSON output.
        XCTAssertFalse(
            json.contains(plantedValue),
            "portfolio list JSON must not contain field values"
        )
        // Both labels present.
        XCTAssertTrue(json.contains("Alpha Ltd"), "Expected Alpha Ltd in list output")
        XCTAssertTrue(json.contains("Bravo Corp"), "Expected Bravo Corp in list output")
        // Sorted ascending by label: Alpha before Bravo.
        let alphaIdx = json.range(of: "Alpha Ltd")!.lowerBound
        let bravoIdx = json.range(of: "Bravo Corp")!.lowerBound
        XCTAssertLessThan(alphaIdx, bravoIdx, "Summaries must be sorted alphabetically")
        // All required summary keys present.
        XCTAssertTrue(json.contains("\"id\""), "Summary must carry id")
        XCTAssertTrue(json.contains("\"label\""), "Summary must carry label")
        XCTAssertTrue(json.contains("\"kind\""), "Summary must carry kind")
        XCTAssertTrue(json.contains("\"fieldCount\""), "Summary must carry fieldCount")
        XCTAssertTrue(json.contains("\"conflicted\""), "Summary must carry conflicted")
    }

    // MARK: - runPortfolioShow: by id and by label, value-free

    func testPortfolioShowByIdIsValueFree() throws {
        if keychainUnavailable() {
            throw XCTSkip("Keychain unavailable; skipping portfolio show test")
        }
        let libRoot = tempDir.appendingPathComponent("lib-show-id", isDirectory: true)
        try FileManager.default.createDirectory(at: libRoot, withIntermediateDirectories: true)
        let library = try PortfolioLibrary(rootDirectory: libRoot)

        let plantedValue = "SECRET_FIELD_VALUE_ID"
        let id = try plantPortfolio(in: library, label: "ShowByID", fieldValue: plantedValue)

        let detail = try LDACLI.runPortfolioShow(nameOrID: id.uuidString, libraryRoot: libRoot)
        let json = try CLIJSON.encode(detail)

        XCTAssertFalse(json.contains(plantedValue), "show output must not contain field values")
        XCTAssertTrue(json.contains("companyName"), "show output must list rawKeys")
        XCTAssertTrue(json.contains("\"label\""), "show output must carry label")
        XCTAssertTrue(json.contains("ShowByID"), "show output must carry the portfolio label")
    }

    func testPortfolioShowByLabelIsValueFree() throws {
        if keychainUnavailable() {
            throw XCTSkip("Keychain unavailable; skipping portfolio show-by-label test")
        }
        let libRoot = tempDir.appendingPathComponent("lib-show-label", isDirectory: true)
        try FileManager.default.createDirectory(at: libRoot, withIntermediateDirectories: true)
        let library = try PortfolioLibrary(rootDirectory: libRoot)

        let plantedValue = "SECRET_FIELD_VALUE_LABEL"
        _ = try plantPortfolio(in: library, label: "ShowByLabel", fieldValue: plantedValue)

        let detail = try LDACLI.runPortfolioShow(nameOrID: "showbylabel", libraryRoot: libRoot)
        let json = try CLIJSON.encode(detail)

        XCTAssertFalse(json.contains(plantedValue), "show output must not contain field values")
        XCTAssertTrue(json.contains("companyName"), "show output must list rawKeys")
    }

    func testPortfolioShowAmbiguousLabelListsCandidates() throws {
        if keychainUnavailable() {
            throw XCTSkip("Keychain unavailable; skipping portfolio show ambiguous test")
        }
        let libRoot = tempDir.appendingPathComponent("lib-show-ambig", isDirectory: true)
        try FileManager.default.createDirectory(at: libRoot, withIntermediateDirectories: true)
        let library = try PortfolioLibrary(rootDirectory: libRoot)

        // Plant two portfolios with the same label (same case-insensitive label,
        // different capitalisation) so that a lookup by "Duplicate Client" hits
        // both and triggers the ambiguous-label error.
        _ = try plantPortfolio(in: library, label: "Duplicate Client")
        _ = try plantPortfolio(in: library, label: "DUPLICATE CLIENT")

        XCTAssertThrowsError(
            try LDACLI.runPortfolioShow(nameOrID: "duplicate client", libraryRoot: libRoot)
        ) { error in
            let desc = String(describing: error)
            XCTAssertTrue(
                desc.lowercased().contains("ambiguous") || desc.lowercased().contains("multiple"),
                "Expected ambiguous/multiple error, got: \(desc)"
            )
            // Both candidate labels must appear in the error message.
            XCTAssertTrue(
                desc.contains("Duplicate Client") && desc.contains("DUPLICATE CLIENT"),
                "Error must list both candidate labels, got: \(desc)"
            )
        }
    }

    func testPortfolioShowMissingNameClearError() throws {
        if keychainUnavailable() {
            throw XCTSkip("Keychain unavailable; skipping portfolio show missing test")
        }
        let libRoot = tempDir.appendingPathComponent("lib-show-miss", isDirectory: true)
        try FileManager.default.createDirectory(at: libRoot, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try LDACLI.runPortfolioShow(nameOrID: "DoesNotExist", libraryRoot: libRoot)
        ) { error in
            let desc = String(describing: error)
            XCTAssertTrue(
                desc.lowercased().contains("not found") || desc.lowercased().contains("no portfolio"),
                "Expected not-found error, got: \(desc)"
            )
        }
    }

    // MARK: - Fill --portfolio validation

    func testFillPortfolioAndProfileTogetherThrows() throws {
        XCTAssertThrowsError(
            try Fill.parse([
                "--profile", "x.ldaprofile",
                "--portfolio", "MyClient",
                "--input", "doc.docx",
                "--plan"
            ])
        ) { error in
            let desc = String(describing: error)
            XCTAssertFalse(desc.isEmpty, "Expected validation error for --profile + --portfolio together")
        }
    }

    func testFillNeitherProfileNorPortfolioThrows() throws {
        XCTAssertThrowsError(
            try Fill.parse(["--input", "doc.docx", "--plan"])
        ) { error in
            let desc = String(describing: error)
            XCTAssertFalse(desc.isEmpty, "Expected validation error when neither --profile nor --portfolio given")
        }
    }

    func testFillPortfolioWithPassphraseThrows() throws {
        XCTAssertThrowsError(
            try Fill.parse([
                "--portfolio", "MyClient",
                "--passphrase", "secret",
                "--input", "doc.docx",
                "--plan"
            ])
        ) { error in
            let desc = String(describing: error)
            XCTAssertFalse(desc.isEmpty, "Expected validation error for --portfolio + --passphrase together")
        }
    }

    // MARK: - Fill --portfolio happy path (plan mode)

    func testFillFromPortfolioPlanMode() throws {
        if keychainUnavailable() {
            throw XCTSkip("Keychain unavailable; skipping fill --portfolio test")
        }
        let libRoot = tempDir.appendingPathComponent("lib-fill", isDirectory: true)
        try FileManager.default.createDirectory(at: libRoot, withIntermediateDirectories: true)
        let library = try PortfolioLibrary(rootDirectory: libRoot)

        let companyName = "FillPortfolio Holdings Ltd"
        _ = try plantPortfolio(in: library, label: "FillClient", fieldValue: companyName)

        let docxURL = try writeDocxWithText("Company: [Company Name].")

        let entries = try LDACLI.runFillPlanFromPortfolio(
            nameOrID: "fillclient",
            libraryRoot: libRoot,
            input: docxURL
        )

        let proposed = entries.filter { $0.status == "proposed" }
        XCTAssertFalse(proposed.isEmpty, "Expected at least one proposed blank from portfolio fill")

        let companyEntry = proposed.first { $0.proposedFieldKey == "companyName" }
        XCTAssertNotNil(companyEntry, "Expected a proposed companyName blank")
        XCTAssertEqual(companyEntry?.proposedValue, companyName)
    }

}
