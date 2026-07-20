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
    }

    func run(scratchPath: URL? = nil) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.packageRoot.appendingPathComponent("packaging/package-app.sh").path]
        process.currentDirectoryURL = Self.packageRoot

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = fakeBinURL.path + ":" + (environment["PATH"] ?? "")
        environment["DIST_PATH"] = distURL.path
        environment["MODEL_PATH"] = rootURL.appendingPathComponent("missing.gguf").path
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
