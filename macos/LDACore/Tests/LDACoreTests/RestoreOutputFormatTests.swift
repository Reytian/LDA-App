//
//  RestoreOutputFormatTests.swift
//  LDACoreTests
//
//  A restored file must be openable by the application its extension names.
//  When the chosen output is .docx, the restore has to write a real Word
//  package (a ZIP, so the first two bytes are the "PK" local file header
//  magic), never UTF-8 text bytes under a .docx name: Word refuses to open
//  those, and the failure surfaces to the user as a corrupt document long
//  after the restore reported success.
//
//  The decision lives in LDAService.restore, the one chokepoint every restore
//  caller funnels through, so no caller can miss it. These tests cover the
//  restore call paths in Sources:
//
//    Sources/LDACLI/CLI.swift:280 and :298      LDACLI.runRestore
//    Sources/LDAMCP/MCPRestoreTools.swift:166 and :265
//    Sources/LDAUI/ReviewModel.swift:628         ReviewModel.restore
//    Sources/LDAUI/SessionModel+RestoreFile.swift:133  SessionModel.restoreFile
//
//  The two CLI sites and the two MCP sites all reach the same
//  restore(editedRedacted:mapping:protection:output:) overload, which is
//  covered directly here; the CLI's second site is its legacy Keychain
//  account retry, which needs a real Keychain miss to reach and cannot be
//  driven hermetically. The MCP sites derive the output extension from the
//  stored artifact's format, so they cannot pair text input with a .docx
//  output today; the test at the end pins that so the pairing stays
//  unreachable there by construction rather than by accident.
//
//  Deterministic-only (no GGUF model) and hermetic: every fixture lives under
//  the temporary directory with passphrase protection, so nothing touches the
//  macOS Keychain.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACLI
@testable import LDACore
@testable import LDAMCP
@testable import LDAUI

@MainActor
final class RestoreOutputFormatTests: XCTestCase {

    private static let email = "jane.doe@example.com"
    private static let body = "Please reach the client at \(email) before Friday."
    private static let createdAt = "2026-09-04T00:00:00Z"
    private static let passphrase = "restore-output-format-passphrase"

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestoreOutputFormatTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir, FileManager.default.fileExists(atPath: workDir.path) {
            try? FileManager.default.removeItem(at: workDir)
        }
        workDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixture

    /// One anonymized round trip whose redacted text has been placed in a .md
    /// file, which is what an external AI hands back. Returns the edited
    /// Markdown, its mapping sidecar, and the loaded mapping.
    private func markdownRoundTrip() throws -> (edited: URL, sidecar: URL, mapping: Mapping) {
        let input = workDir.appendingPathComponent("letter.txt")
        try Data(Self.body.utf8).write(to: input)
        let outputDir = workDir.appendingPathComponent("out", isDirectory: true)
        let saved = try LDAService.anonymize(
            input: input,
            outputDir: outputDir,
            protection: .passphrase(Self.passphrase),
            createdAtISO8601: Self.createdAt
        )
        let redacted = try String(contentsOf: saved.redactedFileURL, encoding: .utf8)
        XCTAssertFalse(redacted.contains(Self.email), "the edit surface must not hold the real value")

        let edited = workDir.appendingPathComponent("Redacted for AI.md")
        try Data(redacted.utf8).write(to: edited)
        let mapping = try MappingStore.load(
            from: saved.mappingFileURL,
            protection: .passphrase(Self.passphrase)
        )
        return (edited, saved.mappingFileURL, mapping)
    }

    private func output(_ name: String) -> URL {
        workDir.appendingPathComponent(name)
    }

    // MARK: - Assertions

    /// A real Word package is a ZIP, so it opens with the "PK" local file
    /// header magic. Text bytes never do.
    private func assertIsWordPackage(
        _ url: URL,
        restoring expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThanOrEqual(data.count, 2, "\(url.lastPathComponent) is too short to be a docx", file: file, line: line)
        XCTAssertEqual(
            Array(data.prefix(2)),
            [0x50, 0x4B],
            "\(url.lastPathComponent) must start with the ZIP magic PK, not text bytes",
            file: file,
            line: line
        )
        XCTAssertEqual(
            try DocxImporter().importDocument(url).text,
            expected,
            "the regenerated Word file must carry the restored text",
            file: file,
            line: line
        )
    }

    /// The reverse floor: a text output stays decodable UTF-8 text and is not
    /// quietly promoted to a Word package.
    private func assertIsPlainText(
        _ url: URL,
        equals expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let data = try Data(contentsOf: url)
        XCTAssertNotEqual(
            Array(data.prefix(2)),
            [0x50, 0x4B],
            "\(url.lastPathComponent) must stay text, not become a ZIP",
            file: file,
            line: line
        )
        XCTAssertEqual(
            String(data: data, encoding: .utf8),
            expected,
            file: file,
            line: line
        )
    }

    // MARK: - LDAService, the shared chokepoint

    func testServiceRestoresMarkdownIntoARealWordPackageWithAnInMemoryMapping() throws {
        let fixture = try markdownRoundTrip()
        let out = output("restored.docx")

        let report = try LDAService.restore(
            editedRedacted: fixture.edited,
            mapping: fixture.mapping,
            output: out
        )

        XCTAssertGreaterThan(report.restoredCount, 0)
        try assertIsWordPackage(out, restoring: Self.body)
    }

    /// The overload every CLI and MCP site reaches. Before the conversion
    /// moved into LDAService, this wrote UTF-8 text bytes into a .docx name.
    func testServiceRestoresMarkdownIntoARealWordPackageThroughASidecar() throws {
        let fixture = try markdownRoundTrip()
        let out = output("restored-via-sidecar.docx")

        let report = try LDAService.restore(
            editedRedacted: fixture.edited,
            mapping: fixture.sidecar,
            protection: .passphrase(Self.passphrase),
            output: out
        )

        XCTAssertGreaterThan(report.restoredCount, 0)
        try assertIsWordPackage(out, restoring: Self.body)
    }

    func testServiceKeepsAMarkdownOutputAsText() throws {
        let fixture = try markdownRoundTrip()
        let out = output("restored.md")

        _ = try LDAService.restore(
            editedRedacted: fixture.edited,
            mapping: fixture.mapping,
            output: out
        )

        try assertIsPlainText(out, equals: Self.body)
    }

    // MARK: - CLI (CLI.swift:280, and :298 through the same overload)

    func testCLIRestoreWritesARealWordPackageForADocxOutput() throws {
        let fixture = try markdownRoundTrip()
        let out = output("cli-restored.docx")

        let report = try LDACLI.runRestore(
            input: fixture.edited,
            mapping: fixture.sidecar,
            output: out,
            passphrase: Self.passphrase
        )

        XCTAssertGreaterThan(report.restoredCount, 0)
        try assertIsWordPackage(out, restoring: Self.body)
    }

    func testCLIRestoreKeepsAMarkdownOutputAsText() throws {
        let fixture = try markdownRoundTrip()
        let out = output("cli-restored.md")

        _ = try LDACLI.runRestore(
            input: fixture.edited,
            mapping: fixture.sidecar,
            output: out,
            passphrase: Self.passphrase
        )

        try assertIsPlainText(out, equals: Self.body)
    }

    // MARK: - GUI route 2 (ReviewModel.swift:628)

    func testReviewModelRestoreWritesARealWordPackageForADocxOutput() throws {
        let fixture = try markdownRoundTrip()
        let out = output("review-restored.docx")
        let model = ReviewModel(modelPath: nil)

        let report = try model.restore(
            editedRedacted: fixture.edited,
            mapping: fixture.sidecar,
            passphrase: Self.passphrase,
            output: out
        )

        XCTAssertGreaterThan(report.restoredCount, 0)
        try assertIsWordPackage(out, restoring: Self.body)
    }

    // MARK: - GUI route 1 (SessionModel+RestoreFile.swift:133)

    /// The one path that already converted. It must keep working after the
    /// decision moved down into LDAService and the duplicate branch went away.
    func testSessionRestoreFileStillWritesARealWordPackage() throws {
        let fixture = try markdownRoundTrip()
        let out = output("session-restored.docx")
        let session = SessionModel(makeModel: {
            let model = ReviewModel(modelPath: nil)
            model.useLLM = false
            return model
        })

        let report = try session.restoreFile(fixture.edited, mapping: fixture.mapping, output: out)

        XCTAssertGreaterThan(report.restoredCount, 0)
        try assertIsWordPackage(out, restoring: Self.body)
    }

    func testSessionRestoreFileKeepsAMarkdownOutputAsText() throws {
        let fixture = try markdownRoundTrip()
        let out = output("session-restored.md")
        let session = SessionModel(makeModel: {
            let model = ReviewModel(modelPath: nil)
            model.useLLM = false
            return model
        })

        _ = try session.restoreFile(fixture.edited, mapping: fixture.mapping, output: out)

        try assertIsPlainText(out, equals: Self.body)
    }

    // MARK: - MCP (MCPRestoreTools.swift:166 and :265)

    /// Both MCP sites name their output after the stored artifact's format
    /// rather than letting a caller choose, so a text redacted artifact can
    /// never ask for a .docx restore there. Pinning the mapping keeps that a
    /// property of the code rather than a coincidence: if a future format is
    /// allowed to promote text into .docx, this fails and points at the
    /// LDAService branch that has to cover it.
    func testMCPNeverPairsATextArtifactWithAWordOutput() {
        XCTAssertEqual(MCPServer.restoredFormat(forRedactedFormat: "docx"), "docx")
        XCTAssertEqual(MCPServer.restoredFormat(forRedactedFormat: "md"), "md")
        for textFormat in ["txt", "text", "pdf", "rtf", ""] {
            XCTAssertEqual(
                MCPServer.restoredFormat(forRedactedFormat: textFormat),
                "txt",
                "a \(textFormat) artifact must not restore into a Word output"
            )
        }
    }

    // MARK: - The branch must not be duplicated back

    /// The regression this fix closes was a second copy of the conversion
    /// decision living in one caller while five others went without it. One
    /// writer call in Sources is the invariant that keeps every caller
    /// inheriting the same behavior.
    func testSimpleDocxWriterIsCalledFromExactlyOnePlaceInSources() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
        guard FileManager.default.fileExists(atPath: sources.path) else {
            return XCTFail("Sources not found at \(sources.path); this check must not be skipped")
        }
        guard let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            return XCTFail("could not walk \(sources.path)")
        }

        var callSites: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.components(separatedBy: "\n") where line.contains("SimpleDocxWriter.write") {
                callSites.append("\(url.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }

        XCTAssertEqual(
            callSites.count,
            1,
            "the plain Word conversion must live in one place so every restore caller inherits it, found: \(callSites)"
        )
        XCTAssertTrue(
            callSites.first?.hasPrefix("LDAService.swift:") ?? false,
            "that one place must be LDAService.restore, found: \(callSites)"
        )
    }
}
