//
//  F11ReleaseBehaviourTests.swift
//  LDACoreTests
//
//  Review 2026-11-11, F11, after the second independent review. Two rounds of
//  fixes to how an export picks its mapping and how a returned file finds its
//  mapping each moved a wrong restore somewhere else, so for this release the
//  owner chose 2.0's behaviour, and binding every exported file to the mapping
//  that wrote it is to be designed separately (docs/design/mapping-identity.md).
//
//  This test is the proof that the release does what 2.0 did. It runs the
//  reviewers' F11 scenarios (one value in a text file, both orders; Word
//  files; values two documents share; three documents over two days; a parked
//  Export for AI round trip after a relaunch; another session's mapping) and
//  checks every redacted text, every mapping, every source restore picks and
//  every restore result against what 2.0 did in the same scenario, byte for
//  byte. Where 2.0 restored the wrong value (a day-one file after the
//  document was saved again from a session holding other placeholders, a
//  file restored while another session or a parked round trip is loaded),
//  this release does too: the user guide says so.
//
//  What F11 left in place is not covered here: a workspace that exists but
//  will not open is not overwritten (WorkspaceMappingBindingTests), and the
//  Word rewrite uses the tokens the redacted text spells.
//
//  Hermetic: every store lives under a per-test directory and every
//  workspace is sealed with a passphrase. Every value is invented.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

@MainActor
final class F11ReleaseBehaviourTests: XCTestCase {

    private var workDir: URL!
    private var record: [String: [String: String]] = [:]

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("F11ReleaseBehaviourTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    private static let createdAt = "2026-11-11T00:00:00Z"

    private func makeSession(_ root: URL) -> SessionModel {
        let session = SessionModel(
            makeModel: {
                let model = ReviewModel(modelPath: nil)
                model.useLLM = false
                return model
            },
            clientStore: { try ClientMappingStore(rootDirectory: root.appendingPathComponent("clients")) }
        )
        session.clientProtection = { _ in .passphrase("pw") }
        session.recordStore = { try SessionRecordStore(rootDirectory: root.appendingPathComponent("records")) }
        session.recordProtection = { .passphrase("pw") }
        session.matterStore = { try MatterMetadataStore(rootDirectory: root.appendingPathComponent("matters")) }
        session.matterProtection = { .passphrase("pw") }
        let parked = root.appendingPathComponent("parked/parked.ldamap")
        try? FileManager.default.createDirectory(at: parked.deletingLastPathComponent(), withIntermediateDirectories: true)
        session.parkedMappingURL = { parked }
        session.parkedProtection = { .passphrase("parked-pw") }
        session.exportSidecarProtection = { _ in .passphrase("ai-sidecar-pw") }
        let workspaces = root.appendingPathComponent("workspaces", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspaces, withIntermediateDirectories: true)
        session.defaultWorkspaceDirectory = { workspaces }
        session.defaultWorkspaceProtection = { _ in .passphrase("workspace-pw") }
        return session
    }

    private func write(_ root: URL, _ name: String, _ content: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    private func writeDocx(_ root: URL, _ name: String, _ line: String) throws -> URL {
        try DocxTestPackage.write(
            body: DocxTestPackage.paragraph(DocxTestPackage.run(line)),
            to: root.appendingPathComponent(name)
        )
    }

    private func export(_ document: URL, from session: SessionModel, into folder: URL) async throws -> ExportResult {
        let entry = try XCTUnwrap(session.entries.first { $0.url.standardizedFileURL == document.standardizedFileURL })
        session.selectedID = entry.id
        return try await session.exportRedacted(to: folder, passphrase: nil, createdAtISO8601: Self.createdAt)
    }

    private func text(_ url: URL) throws -> String {
        url.pathExtension == "docx"
            ? try DocxImporter().importDocument(url).text
            : try String(contentsOf: url, encoding: .utf8)
    }

    private static func entries(_ mapping: Mapping?) -> String {
        guard let mapping else { return "(none)" }
        return mapping.entries.keys.sorted().map { key in
            let entry = mapping.entries[key]!
            return "\(key)=\(entry.token)=\(entry.value)"
        }.joined(separator: "; ")
    }

    /// The source restore picks for `file` and what it restores `content` to.
    private func restoreAsFile(_ file: URL, _ content: String, in session: SessionModel) -> String {
        do {
            switch try session.restoreMappingSource(for: file) {
            case .sidecar: return "sidecar"
            case .session(let m): return "session -> " + Restorer.restore(text: content, mapping: m).text
            case .defaultWorkspace(let m): return "workspace -> " + Restorer.restore(text: content, mapping: m).text
            case .clientProfile(let m): return "client -> " + Restorer.restore(text: content, mapping: m).text
            case .none: return "none"
            }
        } catch {
            return "throws"
        }
    }

    private func put(_ scenario: String, _ label: String, _ value: String) {
        record[scenario, default: [:]][label] = value
    }

    private func viaSession(_ text: String, _ session: SessionModel) -> String {
        session.sessionMapping.map { Restorer.restore(text: text, mapping: $0).text } ?? "(no session mapping)"
    }

    private func viaWorkspace(_ root: URL, _ source: URL, _ text: String) -> String {
        let mapping = (try? makeSession(root).defaultWorkspaceMapping(forSource: source)) ?? nil
        return mapping.map { Restorer.restore(text: text, mapping: $0).text } ?? "(no workspace)"
    }

    /// Day one exports `dayOne` in order; day two exports `dayTwo` in order.
    /// `bodies` maps file name to body. Records everything a user could do.
    private func runScenario(
        _ name: String,
        bodies: [(String, String)],
        dayOne: [String],
        dayTwo: [String],
        word: Bool = false
    ) async throws {
        let root = workDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var files: [String: URL] = [:]
        for (file, body) in bodies {
            files[file] = word ? try writeDocx(root, file, body) : try write(root, file, body)
        }
        let one = makeSession(root)
        await one.addDocuments(dayOne.map { files[$0]! })
        await one.anonymizeAll()
        var firstResults: [String: ExportResult] = [:]
        for file in dayOne {
            firstResults[file] = try await export(files[file]!, from: one, into: root.appendingPathComponent("day1", isDirectory: true))
            put(name, "day1 \(file) text", try text(firstResults[file]!.redactedURL))
        }
        let two = makeSession(root)
        await two.addDocuments(dayTwo.map { files[$0]! })
        await two.anonymizeAll()
        var secondResults: [String: ExportResult] = [:]
        for file in dayTwo {
            do {
                secondResults[file] = try await export(files[file]!, from: two, into: root.appendingPathComponent("day2", isDirectory: true))
                put(name, "day2 \(file) text", try text(secondResults[file]!.redactedURL))
            } catch {
                put(name, "day2 \(file) text", "(export refused)")
            }
        }
        put(name, "day2 session mapping", Self.entries(two.sessionMapping))
        for (file, _) in bodies {
            put(name, "workspace \(file)", Self.entries(try? makeSession(root).defaultWorkspaceMapping(forSource: files[file]!)))
        }
        for (label, results) in [("day1", firstResults), ("day2", secondResults)] {
            for (file, result) in results {
                let content = try text(result.redactedURL)
                put(name, "\(label) \(file) via session", viaSession(content, two))
                put(name, "\(label) \(file) via its workspace", viaWorkspace(root, files[file]!, content))
                if !word {
                    let replies = root.appendingPathComponent("replies-\(label)", isDirectory: true)
                    try FileManager.default.createDirectory(at: replies, withIntermediateDirectories: true)
                    let reply = try write(replies, "reply-\(file)", content)
                    put(name, "\(label) \(file) as a reply", restoreAsFile(reply, content, in: two))
                    let own = root.appendingPathComponent("own-\(label)", isDirectory: true)
                    try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
                    let copy = own.appendingPathComponent(result.redactedURL.lastPathComponent)
                    try? FileManager.default.removeItem(at: copy)
                    try FileManager.default.copyItem(at: result.redactedURL, to: copy)
                    put(name, "\(label) \(file) by its own name", restoreAsFile(copy, content, in: two))
                } else {
                    let reply = root.appendingPathComponent("reply-\(label)-\(file)")
                    try? FileManager.default.removeItem(at: reply)
                    try FileManager.default.copyItem(at: result.redactedURL, to: reply)
                    let picked: Mapping?
                    switch try? two.restoreMappingSource(for: reply) {
                    case .session(let m)?: picked = m; put(name, "\(label) \(file) reply source", "session")
                    case .defaultWorkspace(let m)?: picked = m; put(name, "\(label) \(file) reply source", "workspace")
                    case .clientProfile(let m)?: picked = m; put(name, "\(label) \(file) reply source", "client")
                    default: picked = nil; put(name, "\(label) \(file) reply source", "other")
                    }
                    if let picked {
                        let out = root.appendingPathComponent("restored-\(label)-\(file)")
                        try? FileManager.default.removeItem(at: out)
                        _ = try LDAService.restore(editedRedacted: reply, mapping: picked, output: out)
                        put(name, "\(label) \(file) reply restored as Word", try text(out))
                    }
                }
            }
        }
        if !word {
            let quoted = try dayTwo.compactMap { secondResults[$0] }.map { try text($0.redactedURL) }.joined(separator: "\n")
            put(name, "one reply quoting every day-two file, via session", viaSession(quoted, two))
        }
    }

    private static let a = "Engagement Letter. Mail alice@alpha.example about the matter."
    private static let b = "Engagement Letter. Mail bob@beta.example about the matter."
    private static let c = "Engagement Letter. Mail carol@gamma.example about the matter."

    func testEveryF11ScenarioRestoresExactlyAs20Did() async throws {
        try await runScenario("txt A then B", bodies: [("alpha.txt", Self.a), ("beta.txt", Self.b)],
                              dayOne: ["beta.txt"], dayTwo: ["alpha.txt", "beta.txt"])
        try await runScenario("txt B then A", bodies: [("alpha.txt", Self.a), ("beta.txt", Self.b)],
                              dayOne: ["beta.txt"], dayTwo: ["beta.txt", "alpha.txt"])
        try await runScenario("word A then B", bodies: [("alpha.docx", Self.a), ("beta.docx", Self.b)],
                              dayOne: ["beta.docx"], dayTwo: ["alpha.docx", "beta.docx"], word: true)
        try await runScenario("shared values", bodies: [
            ("alpha.txt", "Mail alice@alpha.example, bob@beta.example and dan@beta.example about the matter."),
            ("beta.txt", "Mail bob@beta.example and dan@beta.example about the matter."),
        ], dayOne: ["beta.txt"], dayTwo: ["alpha.txt", "beta.txt"])
        try await runScenario("three documents", bodies: [("alpha.txt", Self.a), ("beta.txt", Self.b), ("gamma.txt", Self.c)],
                              dayOne: ["beta.txt", "gamma.txt"], dayTwo: ["alpha.txt", "gamma.txt", "beta.txt"])

        // A parked Export for AI of A, then a relaunch restoring B's day-1 file.
        let parkedRoot = workDir.appendingPathComponent("parked", isDirectory: true)
        try FileManager.default.createDirectory(at: parkedRoot, withIntermediateDirectories: true)
        let pa = try write(parkedRoot, "alpha.txt", Self.a)
        let pb = try write(parkedRoot, "beta.txt", Self.b)
        let p1 = makeSession(parkedRoot)
        await p1.addDocuments([pb])
        await p1.anonymizeAll()
        let pFirst = try await export(pb, from: p1, into: parkedRoot.appendingPathComponent("day1", isDirectory: true))
        let handoff = makeSession(parkedRoot)
        await handoff.addDocuments([pa])
        await handoff.anonymizeAll()
        _ = try handoff.buildHandToAI(createdAtISO8601: Self.createdAt)
        let relaunched = makeSession(parkedRoot)
        let pContent = try text(pFirst.redactedURL)
        put("parked", "day1 beta.txt text", pContent)
        put("parked", "day1 beta.txt by its own name after a relaunch", restoreAsFile(pFirst.redactedURL, pContent, in: relaunched))
        put("parked", "session after that restore", Self.entries(relaunched.sessionMapping))

        // Another session's own mapping gives {EMAIL_1} to alice.
        let otherRoot = workDir.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let oa = try write(otherRoot, "alpha.txt", Self.a)
        let ob = try write(otherRoot, "beta.txt", Self.b)
        let o1 = makeSession(otherRoot)
        await o1.addDocuments([ob])
        await o1.anonymizeAll()
        let oFirst = try await export(ob, from: o1, into: otherRoot.appendingPathComponent("day1", isDirectory: true))
        let other = makeSession(otherRoot)
        await other.addDocuments([oa])
        await other.anonymizeAll()
        _ = try await export(oa, from: other, into: otherRoot.appendingPathComponent("other", isDirectory: true))
        let oContent = try text(oFirst.redactedURL)
        put("other session", "day1 beta.txt text", oContent)
        put("other session", "day1 beta.txt by its own name in the other session", restoreAsFile(oFirst.redactedURL, oContent, in: other))

        // F11_RECORD_OUT writes what this build does, to record it again
        // once each file carries its mapping's identity.
        if let out = ProcessInfo.processInfo.environment["F11_RECORD_OUT"] {
            let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: out))
        }
        XCTAssertEqual(Set(record.keys), Set(Self.recordedFrom20.keys), "the scenarios")
        for (scenario, expected) in Self.recordedFrom20.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(Set(record[scenario].map { Array($0.keys) } ?? []), Set(expected.keys), "\(scenario): the steps")
            for (label, value) in expected.sorted(by: { $0.key < $1.key }) {
                XCTAssertEqual(record[scenario]?[label], value, "\(scenario): \(label)")
            }
        }
    }

    /// What 2.0 (e8abdf6) did in every scenario, recorded by running this
    /// test's scenarios against that commit. Entries that restore a value
    /// other than the one written are the known limitation, not a goal.
    static let recordedFrom20: [String: [String: String]] = [
        #"other session"#: [
            #"day1 beta.txt by its own name in the other session"#: #"session -> Engagement Letter. Mail alice@alpha.example about the matter."#,
            #"day1 beta.txt text"#: #"Engagement Letter. Mail {EMAIL_1} about the matter."#,
        ],
        #"parked"#: [
            #"day1 beta.txt by its own name after a relaunch"#: #"session -> Engagement Letter. Mail alice@alpha.example about the matter."#,
            #"day1 beta.txt text"#: #"Engagement Letter. Mail {EMAIL_1} about the matter."#,
            #"session after that restore"#: #"{EMAIL_1}={EMAIL_1}=alice@alpha.example"#,
        ],
        #"shared values"#: [
            #"day1 beta.txt as a reply"#: #"session -> Mail alice@alpha.example and bob@beta.example about the matter."#,
            #"day1 beta.txt by its own name"#: #"session -> Mail alice@alpha.example and bob@beta.example about the matter."#,
            #"day1 beta.txt text"#: #"Mail {EMAIL_1} and {EMAIL_2} about the matter."#,
            #"day1 beta.txt via its workspace"#: #"Mail alice@alpha.example and bob@beta.example about the matter."#,
            #"day1 beta.txt via session"#: #"Mail alice@alpha.example and bob@beta.example about the matter."#,
            #"day2 alpha.txt as a reply"#: #"session -> Mail alice@alpha.example, bob@beta.example and dan@beta.example about the matter."#,
            #"day2 alpha.txt by its own name"#: #"session -> Mail alice@alpha.example, bob@beta.example and dan@beta.example about the matter."#,
            #"day2 alpha.txt text"#: #"Mail {EMAIL_1}, {EMAIL_2} and {EMAIL_3} about the matter."#,
            #"day2 alpha.txt via its workspace"#: #"Mail alice@alpha.example, bob@beta.example and dan@beta.example about the matter."#,
            #"day2 alpha.txt via session"#: #"Mail alice@alpha.example, bob@beta.example and dan@beta.example about the matter."#,
            #"day2 beta.txt as a reply"#: #"session -> Mail bob@beta.example and dan@beta.example about the matter."#,
            #"day2 beta.txt by its own name"#: #"session -> Mail bob@beta.example and dan@beta.example about the matter."#,
            #"day2 beta.txt text"#: #"Mail {EMAIL_2} and {EMAIL_3} about the matter."#,
            #"day2 beta.txt via its workspace"#: #"Mail bob@beta.example and dan@beta.example about the matter."#,
            #"day2 beta.txt via session"#: #"Mail bob@beta.example and dan@beta.example about the matter."#,
            #"day2 session mapping"#: #"{EMAIL_1}={EMAIL_1}=alice@alpha.example; {EMAIL_2}={EMAIL_2}=bob@beta.example; {EMAIL_3}={EMAIL_3}=dan@beta.example"#,
            #"one reply quoting every day-two file, via session"#: #"Mail alice@alpha.example, bob@beta.example and dan@beta.example about the matter.\#nMail bob@beta.example and dan@beta.example about the matter."#,
            #"workspace alpha.txt"#: #"{EMAIL_1}={EMAIL_1}=alice@alpha.example; {EMAIL_2}={EMAIL_2}=bob@beta.example; {EMAIL_3}={EMAIL_3}=dan@beta.example"#,
            #"workspace beta.txt"#: #"{EMAIL_1}={EMAIL_1}=alice@alpha.example; {EMAIL_2}={EMAIL_2}=bob@beta.example; {EMAIL_3}={EMAIL_3}=dan@beta.example"#,
        ],
        #"three documents"#: [
            #"day1 beta.txt as a reply"#: #"session -> Engagement Letter. Mail alice@alpha.example about the matter."#,
            #"day1 beta.txt by its own name"#: #"session -> Engagement Letter. Mail alice@alpha.example about the matter."#,
            #"day1 beta.txt text"#: #"Engagement Letter. Mail {EMAIL_1} about the matter."#,
            #"day1 beta.txt via its workspace"#: #"Engagement Letter. Mail alice@alpha.example about the matter."#,
            #"day1 beta.txt via session"#: #"Engagement Letter. Mail alice@alpha.example about the matter."#,
            #"day1 gamma.txt as a reply"#: #"session -> Engagement Letter. Mail carol@gamma.example about the matter."#,
            #"day1 gamma.txt by its own name"#: #"session -> Engagement Letter. Mail carol@gamma.example about the matter."#,
            #"day1 gamma.txt text"#: #"Engagement Letter. Mail {EMAIL_2} about the matter."#,
            #"day1 gamma.txt via its workspace"#: #"Engagement Letter. Mail carol@gamma.example about the matter."#,
            #"day1 gamma.txt via session"#: #"Engagement Letter. Mail carol@gamma.example about the matter."#,
            #"day2 alpha.txt as a reply"#: #"session -> Engagement Letter. Mail alice@alpha.example about the matter."#,
            #"day2 alpha.txt by its own name"#: #"session -> Engagement Letter. Mail alice@alpha.example about the matter."#,
            #"day2 alpha.txt text"#: #"Engagement Letter. Mail {EMAIL_1} about the matter."#,
            #"day2 alpha.txt via its workspace"#: #"Engagement Letter. Mail alice@alpha.example about the matter."#,
            #"day2 alpha.txt via session"#: #"Engagement Letter. Mail alice@alpha.example about the matter."#,
            #"day2 beta.txt as a reply"#: #"session -> Engagement Letter. Mail bob@beta.example about the matter."#,
            #"day2 beta.txt by its own name"#: #"session -> Engagement Letter. Mail bob@beta.example about the matter."#,
            #"day2 beta.txt text"#: #"Engagement Letter. Mail {EMAIL_3} about the matter."#,
            #"day2 beta.txt via its workspace"#: #"Engagement Letter. Mail bob@beta.example about the matter."#,
            #"day2 beta.txt via session"#: #"Engagement Letter. Mail bob@beta.example about the matter."#,
            #"day2 gamma.txt as a reply"#: #"session -> Engagement Letter. Mail carol@gamma.example about the matter."#,
            #"day2 gamma.txt by its own name"#: #"session -> Engagement Letter. Mail carol@gamma.example about the matter."#,
            #"day2 gamma.txt text"#: #"Engagement Letter. Mail {EMAIL_2} about the matter."#,
            #"day2 gamma.txt via its workspace"#: #"Engagement Letter. Mail carol@gamma.example about the matter."#,
            #"day2 gamma.txt via session"#: #"Engagement Letter. Mail carol@gamma.example about the matter."#,
            #"day2 session mapping"#: #"{EMAIL_1}={EMAIL_1}=alice@alpha.example; {EMAIL_2}={EMAIL_2}=carol@gamma.example; {EMAIL_3}={EMAIL_3}=bob@beta.example"#,
            #"one reply quoting every day-two file, via session"#: #"Engagement Letter. Mail alice@alpha.example about the matter.\#nEngagement Letter. Mail carol@gamma.example about the matter.\#nEngagement Letter. Mail bob@beta.example about the matter."#,
            #"workspace alpha.txt"#: #"{EMAIL_1}={EMAIL_1}=alice@alpha.example"#,
            #"workspace beta.txt"#: #"{EMAIL_1}={EMAIL_1}=alice@alpha.example; {EMAIL_2}={EMAIL_2}=carol@gamma.example; {EMAIL_3}={EMAIL_3}=bob@beta.example"#,
            #"workspace gamma.txt"#: #"{EMAIL_1}={EMAIL_1}=alice@alpha.example; {EMAIL_2}={EMAIL_2}=carol@gamma.example"#,
        ],
        #"txt A then B"#: [
            #"day1 beta.txt as a reply"#: #"session -> Engagement Letter. Mail alice@alpha.example about the matter."#,
            #"day1 beta.txt by its own name"#: #"session -> Engagement Letter. Mail alice@alpha.example about the matter."#,
            #"day1 beta.txt text"#: #"Engagement Letter. Mail {EMAIL_1} about the matter."#,
            #"day1 beta.txt via its workspace"#: #"Engagement Letter. Mail alice@alpha.example about the matter."#,
            #"day1 beta.txt via session"#: #"Engagement Letter. Mail alice@alpha.example about the matter."#,
            #"day2 alpha.txt as a reply"#: #"session -> Engagement Letter. Mail alice@alpha.example about the matter."#,
            #"day2 alpha.txt by its own name"#: #"session -> Engagement Letter. Mail alice@alpha.example about the matter."#,
            #"day2 alpha.txt text"#: #"Engagement Letter. Mail {EMAIL_1} about the matter."#,
            #"day2 alpha.txt via its workspace"#: #"Engagement Letter. Mail alice@alpha.example about the matter."#,
            #"day2 alpha.txt via session"#: #"Engagement Letter. Mail alice@alpha.example about the matter."#,
            #"day2 beta.txt as a reply"#: #"session -> Engagement Letter. Mail bob@beta.example about the matter."#,
            #"day2 beta.txt by its own name"#: #"session -> Engagement Letter. Mail bob@beta.example about the matter."#,
            #"day2 beta.txt text"#: #"Engagement Letter. Mail {EMAIL_2} about the matter."#,
            #"day2 beta.txt via its workspace"#: #"Engagement Letter. Mail bob@beta.example about the matter."#,
            #"day2 beta.txt via session"#: #"Engagement Letter. Mail bob@beta.example about the matter."#,
            #"day2 session mapping"#: #"{EMAIL_1}={EMAIL_1}=alice@alpha.example; {EMAIL_2}={EMAIL_2}=bob@beta.example"#,
            #"one reply quoting every day-two file, via session"#: #"Engagement Letter. Mail alice@alpha.example about the matter.\#nEngagement Letter. Mail bob@beta.example about the matter."#,
            #"workspace alpha.txt"#: #"{EMAIL_1}={EMAIL_1}=alice@alpha.example"#,
            #"workspace beta.txt"#: #"{EMAIL_1}={EMAIL_1}=alice@alpha.example; {EMAIL_2}={EMAIL_2}=bob@beta.example"#,
        ],
        #"txt B then A"#: [
            #"day1 beta.txt as a reply"#: #"session -> Engagement Letter. Mail bob@beta.example about the matter."#,
            #"day1 beta.txt by its own name"#: #"session -> Engagement Letter. Mail bob@beta.example about the matter."#,
            #"day1 beta.txt text"#: #"Engagement Letter. Mail {EMAIL_1} about the matter."#,
            #"day1 beta.txt via its workspace"#: #"Engagement Letter. Mail bob@beta.example about the matter."#,
            #"day1 beta.txt via session"#: #"Engagement Letter. Mail bob@beta.example about the matter."#,
            #"day2 alpha.txt as a reply"#: #"session -> Engagement Letter. Mail alice@alpha.example about the matter."#,
            #"day2 alpha.txt by its own name"#: #"session -> Engagement Letter. Mail alice@alpha.example about the matter."#,
            #"day2 alpha.txt text"#: #"Engagement Letter. Mail {EMAIL_2} about the matter."#,
            #"day2 alpha.txt via its workspace"#: #"Engagement Letter. Mail alice@alpha.example about the matter."#,
            #"day2 alpha.txt via session"#: #"Engagement Letter. Mail alice@alpha.example about the matter."#,
            #"day2 beta.txt as a reply"#: #"session -> Engagement Letter. Mail bob@beta.example about the matter."#,
            #"day2 beta.txt by its own name"#: #"session -> Engagement Letter. Mail bob@beta.example about the matter."#,
            #"day2 beta.txt text"#: #"Engagement Letter. Mail {EMAIL_1} about the matter."#,
            #"day2 beta.txt via its workspace"#: #"Engagement Letter. Mail bob@beta.example about the matter."#,
            #"day2 beta.txt via session"#: #"Engagement Letter. Mail bob@beta.example about the matter."#,
            #"day2 session mapping"#: #"{EMAIL_1}={EMAIL_1}=bob@beta.example; {EMAIL_2}={EMAIL_2}=alice@alpha.example"#,
            #"one reply quoting every day-two file, via session"#: #"Engagement Letter. Mail bob@beta.example about the matter.\#nEngagement Letter. Mail alice@alpha.example about the matter."#,
            #"workspace alpha.txt"#: #"{EMAIL_1}={EMAIL_1}=bob@beta.example; {EMAIL_2}={EMAIL_2}=alice@alpha.example"#,
            #"workspace beta.txt"#: #"{EMAIL_1}={EMAIL_1}=bob@beta.example"#,
        ],
        #"word A then B"#: [
            #"day1 beta.docx reply restored as Word"#: #"Engagement Letter. Mail alice@alpha.example about the matter."#,
            #"day1 beta.docx reply source"#: #"session"#,
            #"day1 beta.docx text"#: #"Engagement Letter. Mail {EMAIL_1} about the matter."#,
            #"day1 beta.docx via its workspace"#: #"Engagement Letter. Mail alice@alpha.example about the matter."#,
            #"day1 beta.docx via session"#: #"Engagement Letter. Mail alice@alpha.example about the matter."#,
            #"day2 alpha.docx reply restored as Word"#: #"Engagement Letter. Mail alice@alpha.example about the matter."#,
            #"day2 alpha.docx reply source"#: #"session"#,
            #"day2 alpha.docx text"#: #"Engagement Letter. Mail {EMAIL_1} about the matter."#,
            #"day2 alpha.docx via its workspace"#: #"Engagement Letter. Mail alice@alpha.example about the matter."#,
            #"day2 alpha.docx via session"#: #"Engagement Letter. Mail alice@alpha.example about the matter."#,
            #"day2 beta.docx reply restored as Word"#: #"Engagement Letter. Mail bob@beta.example about the matter."#,
            #"day2 beta.docx reply source"#: #"session"#,
            #"day2 beta.docx text"#: #"Engagement Letter. Mail {EMAIL_2} about the matter."#,
            #"day2 beta.docx via its workspace"#: #"Engagement Letter. Mail bob@beta.example about the matter."#,
            #"day2 beta.docx via session"#: #"Engagement Letter. Mail bob@beta.example about the matter."#,
            #"day2 session mapping"#: #"{EMAIL_1}={EMAIL_1}=alice@alpha.example; {EMAIL_2}={EMAIL_2}=bob@beta.example"#,
            #"workspace alpha.docx"#: #"{EMAIL_1}={EMAIL_1}=alice@alpha.example"#,
            #"workspace beta.docx"#: #"{EMAIL_1}={EMAIL_1}=alice@alpha.example; {EMAIL_2}={EMAIL_2}=bob@beta.example"#,
        ],
    ]
}
