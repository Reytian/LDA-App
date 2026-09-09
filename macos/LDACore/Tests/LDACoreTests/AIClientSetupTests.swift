import XCTest
@testable import LDACore

final class AIClientSetupTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func payload(_ client: AIClient) throws -> String {
        let setup = AIClientSetup(client: client, helperPath: "/bin/echo", appPath: "/Applications/LDA.app", modelPath: "/Models/A 'quoted' model.gguf")
        return try JSONEncoder().encode(AIClientSetup.SetupPayload(setup: setup, skill: "fictional skill")).base64EncodedString()
    }

    func testCodexInstallPreservesSettingsAndSkillAndRefusesRepeatedInstall() throws {
        let target = root.appendingPathComponent(".codex/config.toml")
        let previous = "model = \"example\"\n[mcp_servers.other]\ncommand = \"other-helper\"\n"
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(previous.utf8).write(to: target)
        let skill = root.appendingPathComponent(".agents/skills/lda/SKILL.md")
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("user custom skill".utf8).write(to: skill)
        let data = try payload(.codex)
        _ = try AIClientInstaller.install(payloadBase64: data, home: root)
        let updated = try String(contentsOf: target)
        XCTAssertTrue(updated.hasPrefix(previous))
        XCTAssertTrue(updated.contains("[mcp_servers.lda]"))
        XCTAssertEqual(try String(contentsOf: skill), "user custom skill")
        XCTAssertThrowsError(try AIClientInstaller.install(payloadBase64: data, home: root))
        XCTAssertEqual(try String(contentsOf: target), updated)
        let backups = try FileManager.default.contentsOfDirectory(at: target.deletingLastPathComponent(), includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains("lda-backup") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(backups.first)), previous)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testAmbiguousCodexFormsArePreservedByteForByte() throws {
        for existing in ["mcp_servers = { other = { command = \"other\" } }", "[\"mcp_servers\".lda]\ncommand = \"old\"", "mcp_servers.lda.command = \"old\"", "[mcp_servers]\nlda = { command = \"old\" }", "[mcp_servers.lda.env]\nX = \"value\""] {
            XCTAssertThrowsError(try AIClientInstaller.checkCodexConfiguration(existing))
        }
    }

    func testJSONClientsMergeAndInstallPortableSkillWithoutRemovingOtherEntries() throws {
        for client in [AIClient.claudeCode, .claudeDesktop] {
            let home = root.appendingPathComponent(client.rawValue)
            let target = home.appendingPathComponent(client == .claudeCode ? ".claude.json" : "Library/Application Support/Claude/claude_desktop_config.json")
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"preference":true,"mcpServers":{"other":{"command":"existing"}}}"#.utf8).write(to: target)
            _ = try AIClientInstaller.install(payloadBase64: payload(client), home: home)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: target)) as? [String: Any])
            XCTAssertEqual(object["preference"] as? Bool, true)
            let servers = try XCTUnwrap(object["mcpServers"] as? [String: Any])
            XCTAssertEqual((servers["other"] as? [String: String])?["command"], "existing")
            XCTAssertEqual((servers["lda"] as? [String: Any])?["command"] as? String, "/bin/echo")
            if client == .claudeCode { XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".claude/skills/lda/SKILL.md")), "fictional skill") }
        }
    }

    func testMalformedJSONAndLinkedSettingsAreNotOverwritten() throws {
        let target = root.appendingPathComponent(".claude.json")
        try Data("{malformed".utf8).write(to: target)
        XCTAssertThrowsError(try AIClientInstaller.install(payloadBase64: payload(.claudeCode), home: root))
        XCTAssertEqual(try String(contentsOf: target), "{malformed")
        try FileManager.default.removeItem(at: target)
        let other = root.appendingPathComponent("original.json")
        try Data("{}".utf8).write(to: other)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: other)
        XCTAssertThrowsError(try AIClientInstaller.install(payloadBase64: payload(.claudeCode), home: root))
        XCTAssertEqual(try String(contentsOf: other), "{}")
    }

    func testExportedScriptUsesBundledHelperAndQuotesHostilePathLiterally() throws {
        let path = "/Applications/A 'quoted' $(touch NEVER).app/Contents/Helpers/lda-mcp"
        let script = try AIClientSetup(client: .codex, helperPath: path, appPath: "/Applications/LDA.app").installationScript(skill: "fixture")
        XCTAssertFalse(script.contains("python"))
        XCTAssertTrue(script.contains("setup --payload-base64"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "print -rn -- " + AIClientSetup.shellQuote(path)]
        let output = Pipe(); process.standardOutput = output
        try process.run()
        let received = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: received, as: UTF8.self), path)
    }
}
