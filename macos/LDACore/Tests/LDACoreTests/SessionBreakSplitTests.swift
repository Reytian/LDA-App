//
//  SessionBreakSplitTests.swift
//  LDACoreTests
//
//  The last two call sites of the break-splitting rule: the SESSION paths.
//
//  LDAService.anonymize and ReviewModel.performExport already split a span
//  whose surface crosses a paragraph end, a soft line break, or a tab into
//  per-part spans (see SpanSplitter, SpanSplitTypeTests, and
//  ReviewModelExportBreakSplitTests). The session paths did not, for any
//  format, so the very same document handed to an AI through
//  SessionModel.buildHandToAI (the app's Export for AI) or through
//  LDAService.anonymizeSession (the CLI and the MCP anonymize_session tool)
//  came back with one line fewer than the source, with the date hidden inside
//  a phone token.
//
//  Each test drives a TWO document session, because a session exists to give
//  one value one identity everywhere: the split must not cost the shared
//  token.
//
//  Deterministic-only (no GGUF model). Hermetic: fixtures and stores live
//  under the temporary directory with passphrase protection, so no Keychain
//  access.
//
//  House rules: all comments and strings in English. Fixture values may be
//  Chinese. No em-dash and no en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

@MainActor
final class SessionBreakSplitTests: XCTestCase {

    private static let createdAt = "2026-09-03T00:00:00Z"

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-break-split-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    // MARK: - Fixture

    private static let probePhone = "13700001111"
    private static let probeDate = "2026-04-01"

    /// The bridged document: the phone ends line 2 and the date opens line 3,
    /// so the merger absorbs both into ONE break-crossing PHONE span.
    private static let bridgedText = """
    甲方联系人
    手机 \(probePhone)
    \(probeDate) 起生效
    乙方联系人
    邮箱 lisi@example.com
    备注：无
    完
    """

    /// The session partner: it carries the same phone on a single line, so the
    /// shared mapping must hand both documents the SAME phone token.
    private static let partnerText = "副本请联系 \(probePhone) 查收。"

    private func write(_ name: String, _ content: String) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    private func lineCount(_ text: String) -> Int {
        text.components(separatedBy: "\n").count
    }

    // MARK: - LDAService.anonymizeSession (CLI and MCP anonymize_session)

    /// The headless session path splits the crossing span: the intermediate
    /// keeps every line of the source, the date half carries its OWN type, the
    /// phone token is shared with the partner document, and the whole
    /// intermediate restores byte-identically.
    func testAnonymizeSessionSplitsABreakCrossingSpan() throws {
        let bridged = try write("bridged.txt", Self.bridgedText)
        let partner = try write("partner.txt", Self.partnerText)

        let session = try LDAService.anonymizeSession(
            inputs: [bridged, partner],
            createdAtISO8601: Self.createdAt
        )

        let markdown = session.documents[0].redactedMarkdown
        XCTAssertEqual(
            lineCount(markdown),
            lineCount(Self.bridgedText),
            "the newline between the phone and the date must survive: \(markdown.debugDescription)"
        )
        XCTAssertTrue(markdown.contains("{PHONE_1}\n{DATE_1}"), markdown)
        XCTAssertFalse(markdown.contains(Self.probePhone), "phone leaked: \(markdown)")
        XCTAssertFalse(markdown.contains(Self.probeDate), "date leaked: \(markdown)")

        // The point of a session: one value, one identity, every document.
        XCTAssertTrue(
            session.documents[1].redactedMarkdown.contains("{PHONE_1}"),
            "the partner document must reuse the phone token: "
                + session.documents[1].redactedMarkdown
        )

        // The date is protected under its own type, not inside a phone token.
        XCTAssertEqual(session.mapping.entries["{DATE_1}"]?.value, Self.probeDate)
        XCTAssertEqual(session.mapping.entries["{PHONE_1}"]?.value, Self.probePhone)

        // Restore is byte-identical for both documents.
        let mappingURL = workDir.appendingPathComponent("session.ldamap")
        try MappingStore.save(session.mapping, to: mappingURL, protection: .passphrase("pw"))
        for (index, source) in [Self.bridgedText, Self.partnerText].enumerated() {
            let report = try LDAService.restoreText(
                session.documents[index].redactedMarkdown,
                mapping: mappingURL,
                protection: .passphrase("pw")
            )
            XCTAssertEqual(report.text, source, "document \(index + 1) must restore exactly")
        }
    }

    /// The per-document span list the CLI and the MCP surface report is the
    /// SPLIT list, mirroring LDAService.anonymize: the parts are what was
    /// actually redacted, so a DATE part is reported as a DATE.
    func testAnonymizeSessionReportsThePartsItRedacted() throws {
        let bridged = try write("bridged.txt", Self.bridgedText)
        let partner = try write("partner.txt", Self.partnerText)

        let session = try LDAService.anonymizeSession(
            inputs: [bridged, partner],
            createdAtISO8601: Self.createdAt
        )

        let reported = session.documents[0].entities
        XCTAssertEqual(session.documents[0].entityCount, reported.count)
        XCTAssertFalse(
            reported.contains { $0.text.contains("\n") },
            "no reported span may still carry a break: \(reported.map(\.text))"
        )
        XCTAssertTrue(
            reported.contains { $0.text == Self.probeDate && $0.type == .date },
            "the date half must be reported as a DATE: "
                + "\(reported.map { "\($0.text)/\($0.type.rawValue)" })"
        )
        XCTAssertTrue(
            reported.contains { $0.text == Self.probePhone && $0.type == .phone },
            "the phone half must be reported as a PHONE"
        )
    }

    // MARK: - SessionModel.buildHandToAI (the app's Export for AI)

    /// The GUI handoff splits the crossing span too, and the sealed chip on
    /// the value the user reviewed still shows a token: the value WAS
    /// protected, in two pieces, and reporting nothing would tell the user it
    /// is exposed.
    func testBuildHandToAISplitsABreakCrossingSpanAndKeepsTheChip() async throws {
        let session = makeSession()
        let bridged = try write("bridged.txt", Self.bridgedText)
        let partner = try write("partner.txt", Self.partnerText)
        await session.addDocuments([bridged, partner])
        await session.anonymizeAll()

        // Fixture guard: the review list holds ONE span bridging the break.
        let bridging = try XCTUnwrap(
            session.entries[0].model.entities.first { $0.span.text.contains("\n") },
            "fixture: the merger must produce a break-crossing span"
        )
        XCTAssertEqual(bridging.span.text, "\(Self.probePhone)\n\(Self.probeDate)")

        let handoff = try XCTUnwrap(session.buildHandToAI(createdAtISO8601: Self.createdAt))

        let markdown = try XCTUnwrap(handoff.perDocument[session.entries[0].id])
        XCTAssertEqual(
            lineCount(markdown),
            lineCount(Self.bridgedText),
            "the exported Markdown must keep every line: \(markdown.debugDescription)"
        )
        XCTAssertTrue(markdown.contains("{PHONE_1}\n{DATE_1}"), markdown)
        XCTAssertFalse(markdown.contains(Self.probePhone), "phone leaked: \(markdown)")
        XCTAssertFalse(markdown.contains(Self.probeDate), "date leaked: \(markdown)")

        let partnerMarkdown = try XCTUnwrap(handoff.perDocument[session.entries[1].id])
        XCTAssertTrue(
            partnerMarkdown.contains("{PHONE_1}"),
            "the partner document must reuse the phone token: \(partnerMarkdown)"
        )

        // Restore against the session mapping is byte-identical.
        let mapping = try XCTUnwrap(session.sessionMapping)
        XCTAssertEqual(mapping.entries["{DATE_1}"]?.value, Self.probeDate)
        XCTAssertEqual(Restorer.restore(text: markdown, mapping: mapping).text, Self.bridgedText)
        XCTAssertEqual(
            Restorer.restore(text: partnerMarkdown, mapping: mapping).text,
            Self.partnerText
        )

        // The sealed chip on the split value shows the first part's token.
        let sealed = try XCTUnwrap(
            session.entries[0].model.entities.first { $0.span.text.contains("\n") }
        )
        XCTAssertEqual(
            sealed.token,
            "{PHONE_1}",
            "a split value must keep a sealed chip, not look unprotected"
        )
    }

    // MARK: - Session scaffolding

    /// A deterministic-only session whose every store lives under the temp
    /// root with passphrase protection, so no Keychain access happens.
    private func makeSession() -> SessionModel {
        let clientRoot = workDir.appendingPathComponent("clients")
        let session = SessionModel(
            makeModel: {
                let model = ReviewModel(modelPath: nil)
                model.useLLM = false
                return model
            },
            clientStore: { try ClientMappingStore(rootDirectory: clientRoot) }
        )
        session.clientProtection = { _ in .passphrase("pw") }
        let recordRoot = workDir.appendingPathComponent("records")
        session.recordStore = { try SessionRecordStore(rootDirectory: recordRoot) }
        session.recordProtection = { .passphrase("pw") }
        let matterRoot = workDir.appendingPathComponent("matters")
        session.matterStore = { try MatterMetadataStore(rootDirectory: matterRoot) }
        session.matterProtection = { .passphrase("pw") }
        let parkedURL = workDir.appendingPathComponent("parked-test.ldamap")
        session.parkedMappingURL = { parkedURL }
        session.parkedProtection = { .passphrase("parked-pw") }
        session.exportSidecarProtection = { _ in .passphrase("sidecar-pw") }
        return session
    }
}
