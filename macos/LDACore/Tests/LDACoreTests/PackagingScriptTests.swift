import Foundation
import XCTest

final class PackagingScriptTests: XCTestCase {
    func testPackagingWithoutScratchPathBuildsBundle() throws {
        let fixture = try PackagingFixture(swiftExitStatus: 0)
        defer { fixture.remove() }

        let result = try fixture.run()

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.distURL
                    .appendingPathComponent("LDA.app/Contents/MacOS/LDAApp")
                    .path
            ),
            result.output
        )
    }

    func testPackagingRefusesWhenTheQuickModelIsMissing() throws {
        // Shipping without the bundled Quick model leaves a fresh install with
        // no working model at all. The script used to warn and continue, which
        // produced a silently degraded build; it must now fail loudly.
        let fixture = try PackagingFixture(swiftExitStatus: 0)
        defer { fixture.remove() }

        let result = try fixture.run(withModel: false)

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("Quick model not found"), result.output)
    }

    func testPackagedBundleCarriesTheResourceBundle() throws {
        // Regression: the script did not copy SwiftPM resource bundles, so the
        // packaged app had no Models.json, the tier catalog was empty, and the
        // ladder collapsed to Patterns only.
        let fixture = try PackagingFixture(swiftExitStatus: 0)
        defer { fixture.remove() }

        _ = try fixture.run()

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.distURL
                    .appendingPathComponent(
                        "LDA.app/Contents/Resources/LDACore_LDAUI.bundle/Models.json")
                    .path
            ),
            "the resource bundle must be inside Contents/Resources: codesign "
            + "rejects unsealed contents at the bundle root"
        )
    }

    func testPackagedBundlePromotesLocalizationsForSwiftUI() throws {
        let fixture = try PackagingFixture(swiftExitStatus: 0)
        defer { fixture.remove() }

        let result = try fixture.run()

        XCTAssertEqual(result.status, 0, result.output)
        for identifier in ["en", "fr", "zh-hans", "zh-hant"] {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: fixture.distURL.appendingPathComponent(
                        "LDA.app/Contents/Resources/\(identifier).lproj/Localizable.strings"
                    ).path
                ),
                "SwiftUI cannot localize from the nested SwiftPM bundle alone. "
                + "Missing main-bundle catalog for \(identifier).\n\(result.output)"
            )
        }
    }

    func testPackagingPropagatesBuildFailure() throws {
        let fixture = try PackagingFixture(swiftExitStatus: 23)
        defer { fixture.remove() }

        let result = try fixture.run(scratchPath: fixture.rootURL.appendingPathComponent("scratch"))

        XCTAssertNotEqual(result.status, 0, result.output)
    }
}

private struct PackagingFixture {
    let rootURL: URL
    let distURL: URL
    private let fakeBinURL: URL
    private let swiftBinURL: URL

    init(swiftExitStatus: Int32) throws {
        let fm = FileManager.default
        rootURL = fm.temporaryDirectory
            .appendingPathComponent("lda-packaging-tests-" + UUID().uuidString, isDirectory: true)
        distURL = rootURL.appendingPathComponent("dist", isDirectory: true)
        fakeBinURL = rootURL.appendingPathComponent("fake-bin", isDirectory: true)
        swiftBinURL = rootURL.appendingPathComponent("swift-bin", isDirectory: true)

        try fm.createDirectory(at: fakeBinURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: swiftBinURL, withIntermediateDirectories: true)
        try writeExecutable(
            named: "LDAApp",
            in: swiftBinURL,
            contents: "#!/bin/bash\nexit 0\n"
        )
        try writeExecutable(
            named: "swift",
            in: fakeBinURL,
            contents: """
            #!/bin/bash
            for argument in "$@"; do
              if [ "$argument" = "--show-bin-path" ]; then
                printf '%s\\n' "$FAKE_SWIFT_BIN_PATH"
                exit 0
              fi
            done
            """ + "\nexit " + String(swiftExitStatus) + "\n"
        )
        try writeExecutable(named: "xattr", in: fakeBinURL, contents: "#!/bin/bash\nexit 0\n")
        try writeExecutable(named: "codesign", in: fakeBinURL, contents: "#!/bin/bash\nexit 0\n")

        // SwiftPM emits resource bundles beside the binary, and the script now
        // copies them into the .app because LDAUI reads Models.json at startup.
        // Without this the fixture would not resemble a real build output.
        let resourceBundle = swiftBinURL.appendingPathComponent("LDACore_LDAUI.bundle")
        try FileManager.default.createDirectory(
            at: resourceBundle, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: resourceBundle.appendingPathComponent("Models.json"))
        for identifier in ["en", "fr", "zh-hans", "zh-hant"] {
            let localization = resourceBundle.appendingPathComponent(
                "\(identifier).lproj",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: localization,
                withIntermediateDirectories: true
            )
            try Data("\"Language\" = \"Language\";\n".utf8).write(
                to: localization.appendingPathComponent("Localizable.strings")
            )
        }

        // The Quick model. The script refuses to ship without it, which is
        // covered separately by testPackagingRefusesWhenTheQuickModelIsMissing.
        modelURL = rootURL.appendingPathComponent("Qwen3.5-4B-Q4_K_M.gguf")
        try Data("GGUF".utf8).write(to: modelURL)
    }

    /// The stand-in Quick model this fixture provides.
    private(set) var modelURL = URL(fileURLWithPath: "/dev/null")

    func run(
        scratchPath: URL? = nil,
        withModel: Bool = true
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.packageRoot.appendingPathComponent("packaging/package-app.sh").path]
        process.currentDirectoryURL = Self.packageRoot

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = fakeBinURL.path + ":" + (environment["PATH"] ?? "")
        environment["DIST_PATH"] = distURL.path
        environment["MODEL_PATH"] = withModel
            ? modelURL.path
            : rootURL.appendingPathComponent("missing.gguf").path
        environment["STAGE_SOURCE"] = "0"
        environment["FAKE_SWIFT_BIN_PATH"] = swiftBinURL.path
        environment.removeValue(forKey: "SCRATCH_PATH")
        if let scratchPath {
            environment["SCRATCH_PATH"] = scratchPath.path
        }
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func writeExecutable(named name: String, in directory: URL, contents: String) throws {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: url.path
        )
    }
}
