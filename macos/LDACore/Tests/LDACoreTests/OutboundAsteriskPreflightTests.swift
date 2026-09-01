//
//  OutboundAsteriskPreflightTests.swift
//  LDACoreTests
//
//  Asterisk masks can collide. The exact Restorer verdict must run before a
//  session copy or standalone export releases content, not only when the AI
//  answer later comes back. A refusal must be typed, visible, and actionable.
//
//  House rules: English only. Fixture values may be Chinese. No em-dash and
//  no en-dash-as-separator.
//

import XCTest
@testable import LDACore
@testable import LDAUI

private func assertActionableAsteriskPreflightError(
    _ error: Error,
    replacement: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let typeName = String(reflecting: type(of: error))
    let typedValue = typeName + " " + String(reflecting: error)
    XCTAssertTrue(
        typedValue.localizedCaseInsensitiveContains("asterisk")
            || typedValue.localizedCaseInsensitiveContains("ambigu")
            || typedValue.localizedCaseInsensitiveContains("outbound"),
        "the refusal needs a dedicated typed error, got \(typeName)",
        file: file,
        line: line
    )
    let message = error.localizedDescription
    XCTAssertTrue(message.localizedCaseInsensitiveContains("asterisk"), message, file: file, line: line)
    XCTAssertTrue(message.contains(replacement), message, file: file, line: line)
    XCTAssertTrue(
        message.localizedCaseInsensitiveContains("token")
            || message.localizedCaseInsensitiveContains("pseudonym"),
        "the message must tell the user which safe style to choose: \(message)",
        file: file,
        line: line
    )
}

final class StandaloneAsteriskPreflightTests: XCTestCase {

    private var workDir: URL!
    private static let createdAt = "2026-09-01T00:00:00Z"

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "StandaloneAsteriskPreflightTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    private func phoneSpans(in text: String) -> [Span] {
        ["13812345678", "13887655678"].map { value in
            let range = (text as NSString).range(of: value)
            precondition(range.location != NSNotFound)
            return Span(
                start: range.location,
                end: range.location + range.length,
                type: .phone,
                text: value,
                source: .deterministic,
                confidence: 1.0,
                priority: 100
            )
        }
    }

    func testStandaloneExportBlocksTheExactRestorerAmbiguityBeforeWritingArtifacts() throws {
        let text = "A: 13812345678 B: 13887655678."
        let output = workDir.appendingPathComponent("out", isDirectory: true)

        let tokenized = Tokenizer.tokenize(
            text: text,
            spans: phoneSpans(in: text),
            sourceFile: "phones.txt",
            createdAtISO8601: Self.createdAt,
            style: .asterisk
        )
        let exactVerdict = Restorer.restore(
            text: tokenized.tokenizedText,
            mapping: tokenized.mapping
        )
        XCTAssertEqual(exactVerdict.ambiguousReplacements, ["138****5678"])

        XCTAssertThrowsError(
            try ReviewModel.performExport(
                text: text,
                acceptedSpans: phoneSpans(in: text),
                source: nil,
                custom: [],
                useLLM: false,
                modelPath: nil,
                outputDir: output,
                passphrase: "pw",
                createdAtISO8601: Self.createdAt,
                style: .asterisk
            )
        ) { error in
            assertActionableAsteriskPreflightError(
                error,
                replacement: "138****5678"
            )
        }

        let artifacts = (try? FileManager.default.contentsOfDirectory(
            at: output,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertTrue(artifacts.isEmpty, "preflight must run before any redacted file or sidecar is written")
    }
}

@MainActor
final class SessionAsteriskPreflightTests: XCTestCase {

    private var workDir: URL!
    private static let createdAt = "2026-09-01T00:00:00Z"

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SessionAsteriskPreflightTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    private func makeSession() -> SessionModel {
        let session = SessionModel(makeModel: {
            let model = ReviewModel(modelPath: nil)
            model.useLLM = false
            return model
        })
        session.outputStyleProvider = { .asterisk }
        session.clientProtection = { _ in .passphrase("pw") }
        session.recordStore = {
            try SessionRecordStore(
                rootDirectory: self.workDir.appendingPathComponent("records", isDirectory: true)
            )
        }
        session.recordProtection = { .passphrase("pw") }
        session.parkedMappingURL = {
            self.workDir.appendingPathComponent("parked.ldamap")
        }
        session.parkedProtection = { .passphrase("parked-pw") }
        return session
    }

    func testSessionHandoffBlocksAsteriskAmbiguityBeforePublishingOrParking() async throws {
        let source = workDir.appendingPathComponent("phones.txt")
        try Data("A: 13812345678 B: 13887655678.".utf8).write(to: source)
        let session = makeSession()
        await session.addDocuments([source])
        await session.anonymizeAll()

        XCTAssertThrowsError(
            try session.buildHandToAI(createdAtISO8601: Self.createdAt)
        ) { error in
            assertActionableAsteriskPreflightError(error, replacement: "138****5678")
        }

        XCTAssertNil(session.sessionMapping, "a refused copy must not become the restorable session")
        XCTAssertNil(session.currentRecordID, "a refused copy must not be recorded as a completed handoff")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: try session.parkedMappingURL().path),
            "a refused copy must not park a mapping for content that never left"
        )
    }
}
