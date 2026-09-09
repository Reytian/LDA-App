//
//  PackagingScriptTests.swift
//  LDACoreTests
//
//  Drives packaging/package-app.sh against a fake toolchain so the packaging
//  rules are covered by the unit suite rather than by memory.
//
//  Bundling a model is opt in. BUNDLE_MODEL=1 is the only thing that turns it
//  on, and when it is on the file is verified against the packaged Models.json
//  before it is copied. That verification is the only moment in the product's
//  life when a bundled model can be checked at all: ModelCatalog.bundledPath
//  resolves straight through Bundle.main, so ModelInstaller never sees it.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import CryptoKit
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

    func testPackagingWithoutABundledModelSucceeds() throws {
        // The model-less build is the shipping configuration, so it must need
        // no flag at all and must say plainly that no model went in.
        let fixture = try PackagingFixture(swiftExitStatus: 0)
        defer { fixture.remove() }

        let result = try fixture.run()

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("No model bundled"), result.output)
        XCTAssertEqual(fixture.bundledModelFileNames(), [], result.output)
    }

    func testPackagingWithoutABundledModelIgnoresAStaleModelPath() throws {
        // This is the test that pins the opt-in decision. A model file sitting
        // at MODEL_PATH must not change the product: two builds of the same
        // commit have to ship the same app whatever is on the build machine.
        let fixture = try PackagingFixture(swiftExitStatus: 0)
        defer { fixture.remove() }

        let result = try fixture.run(modelURL: fixture.modelURL)

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(fixture.bundledModelFileNames(), [], result.output)
    }

    func testBundleModelWithAMissingFileRefuses() throws {
        let fixture = try PackagingFixture(swiftExitStatus: 0)
        defer { fixture.remove() }

        let result = try fixture.run(bundleModel: true, modelURL: fixture.missingModelURL)

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(
            result.output.contains("BUNDLE_MODEL is set but there is no model file"),
            result.output
        )
    }

    func testBundleModelWithAWrongChecksumRefuses() throws {
        // Same name, same byte count, different bytes. Only the digest can
        // tell these apart, which is why the digest check is not optional.
        let fixture = try PackagingFixture(swiftExitStatus: 0)
        defer { fixture.remove() }

        let result = try fixture.run(bundleModel: true, modelURL: fixture.wrongBytesModelURL)

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("does not match the checksum"), result.output)
        XCTAssertEqual(fixture.bundledModelFileNames(), [], result.output)
    }

    func testBundleModelWithAWrongSizeRefuses() throws {
        let fixture = try PackagingFixture(swiftExitStatus: 0)
        defer { fixture.remove() }

        let result = try fixture.run(bundleModel: true, modelURL: fixture.wrongSizeModelURL)

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("Models.json expects"), result.output)
        XCTAssertEqual(fixture.bundledModelFileNames(), [], result.output)
    }

    func testBundleModelWithAnUnparseableManifestRefuses() throws {
        // A manifest the script cannot read is a hard failure, never a skip:
        // skipping would ship an unverified 2.7 GB blob.
        let fixture = try PackagingFixture(swiftExitStatus: 0, manifestIsParseable: false)
        defer { fixture.remove() }

        let result = try fixture.run(bundleModel: true, modelURL: fixture.modelURL)

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(
            result.output.contains("Refusing to bundle a model that cannot be verified"),
            result.output
        )
        XCTAssertEqual(fixture.bundledModelFileNames(), [], result.output)
    }

    func testBundleModelWithTheRightChecksumBundlesIt() throws {
        let fixture = try PackagingFixture(swiftExitStatus: 0)
        defer { fixture.remove() }

        let result = try fixture.run(bundleModel: true, modelURL: fixture.modelURL)

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("checksum verified"), result.output)
        XCTAssertEqual(
            fixture.bundledModelFileNames(),
            [fixture.modelURL.lastPathComponent],
            result.output
        )
    }

    func testChecksumVerificationIgnoresAStubbedShasumOnPath() throws {
        // The fixture prepends a fake bin directory to PATH because codesign
        // and xattr have to be stubbed. If the script resolved shasum through
        // PATH the integrity check would be theatre, so this fixture also
        // stubs an always-agreeing shasum and the wrong file must still be
        // refused.
        let fixture = try PackagingFixture(swiftExitStatus: 0, stubShasumToAlwaysAgree: true)
        defer { fixture.remove() }

        let result = try fixture.run(bundleModel: true, modelURL: fixture.wrongBytesModelURL)

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("does not match the checksum"), result.output)
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

    func testPackagedBundleVerifiesEveryLocalizationInTheNestedBundle() throws {
        // No promotion to Contents/Resources any more: every string now
        // reaches the interface through L10n.text / L10n.button / .l10nHelp
        // / L10n.string, which resolve against LDACore_LDAUI.bundle's own
        // nested .lproj folders directly (Localization.swift), so SwiftUI's
        // Bundle.main-only initializers are no longer in the resolution path
        // at all. The script still refuses to ship an app missing a language.
        let fixture = try PackagingFixture(swiftExitStatus: 0)
        defer { fixture.remove() }

        let result = try fixture.run()

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.distURL.appendingPathComponent(
                    "LDA.app/Contents/Resources/en.lproj/Localizable.strings"
                ).path
            ),
            "the promotion is retired; a top-level .lproj must not appear.\n\(result.output)"
        )
        for identifier in ["en", "fr", "zh-hans", "zh-hant"] {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: fixture.distURL.appendingPathComponent(
                        "LDA.app/Contents/Resources/LDACore_LDAUI.bundle/\(identifier).lproj/Localizable.strings"
                    ).path
                ),
                "Missing nested-bundle catalog for \(identifier).\n\(result.output)"
            )
        }
    }

    func testPackagingRefusesAnAppMissingALanguage() throws {
        let fixture = try PackagingFixture(swiftExitStatus: 0, omitLocalization: "fr")
        defer { fixture.remove() }

        let result = try fixture.run()

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(
            result.output.contains("Missing fr interface localization"), result.output
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

    /// A stand-in Quick model whose bytes match the fixture manifest.
    let modelURL: URL
    /// Same name and byte count as `modelURL`, different bytes. Only the
    /// digest separates the two.
    let wrongBytesModelURL: URL
    /// Same name as `modelURL`, different byte count.
    let wrongSizeModelURL: URL
    /// A path with no file at it.
    let missingModelURL: URL
    /// The SHA-256 the fixture manifest publishes for `modelURL`.
    let expectedDigest: String

    init(
        swiftExitStatus: Int32,
        manifestIsParseable: Bool = true,
        stubShasumToAlwaysAgree: Bool = false,
        omitLocalization: String? = nil
    ) throws {
        let fm = FileManager.default
        rootURL = fm.temporaryDirectory
            .appendingPathComponent("lda-packaging-tests-" + UUID().uuidString, isDirectory: true)
        distURL = rootURL.appendingPathComponent("dist", isDirectory: true)
        fakeBinURL = rootURL.appendingPathComponent("fake-bin", isDirectory: true)
        swiftBinURL = rootURL.appendingPathComponent("swift-bin", isDirectory: true)

        try fm.createDirectory(at: fakeBinURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: swiftBinURL, withIntermediateDirectories: true)
        // The current app package includes the CLI and MCP helpers as well.
        for executable in ["LDAApp", "lda", "lda-mcp"] {
            try Self.writeExecutable(
                named: executable,
                in: swiftBinURL,
                contents: "#!/bin/bash\nexit 0\n"
            )
        }
        try Self.writeExecutable(
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
        try Self.writeExecutable(named: "xattr", in: fakeBinURL, contents: "#!/bin/bash\nexit 0\n")
        try Self.writeExecutable(named: "codesign", in: fakeBinURL, contents: "#!/bin/bash\nexit 0\n")

        // The stand-in Quick model, plus the two near misses. All three carry
        // the same file name because the script looks the expected figures up
        // by the basename of MODEL_PATH.
        let modelName = "Qwen3.5-4B-Q4_K_M.gguf"
        let modelBytes = Data("GGUF stand-in for the Quick model".utf8)
        modelURL = rootURL.appendingPathComponent(modelName)
        try modelBytes.write(to: modelURL)

        let wrongBytesDirectory = rootURL.appendingPathComponent("wrong-bytes", isDirectory: true)
        try fm.createDirectory(at: wrongBytesDirectory, withIntermediateDirectories: true)
        wrongBytesModelURL = wrongBytesDirectory.appendingPathComponent(modelName)
        var tampered = modelBytes
        tampered[tampered.startIndex] = tampered[tampered.startIndex] ^ 0xFF
        try tampered.write(to: wrongBytesModelURL)

        let wrongSizeDirectory = rootURL.appendingPathComponent("wrong-size", isDirectory: true)
        try fm.createDirectory(at: wrongSizeDirectory, withIntermediateDirectories: true)
        wrongSizeModelURL = wrongSizeDirectory.appendingPathComponent(modelName)
        try (modelBytes + Data("truncation guard".utf8)).write(to: wrongSizeModelURL)

        missingModelURL = rootURL.appendingPathComponent("missing.gguf")

        // Computed here, never hardcoded, so the fixture cannot drift away
        // from the bytes it just wrote.
        expectedDigest = Self.hexDigest(of: modelBytes)

        if stubShasumToAlwaysAgree {
            // Prints the digest the script hopes for, whatever it was asked
            // about. The script must never reach this: it calls
            // /usr/bin/shasum by absolute path.
            try Self.writeExecutable(
                named: "shasum",
                in: fakeBinURL,
                contents: "#!/bin/bash\necho \"\(expectedDigest)  stub\"\nexit 0\n"
            )
        }

        // SwiftPM emits resource bundles beside the binary, and the script
        // copies them into the .app because LDAUI reads Models.json at startup.
        // Without this the fixture would not resemble a real build output, and
        // the model verification would have no manifest to read.
        let resourceBundle = swiftBinURL.appendingPathComponent("LDACore_LDAUI.bundle")
        try fm.createDirectory(at: resourceBundle, withIntermediateDirectories: true)
        let manifest = manifestIsParseable
            ? Self.manifest(
                fileName: modelName,
                sizeBytes: modelBytes.count,
                sha256: expectedDigest
            )
            : "[]"
        try Data(manifest.utf8).write(to: resourceBundle.appendingPathComponent("Models.json"))
        for identifier in ["en", "fr", "zh-hans", "zh-hant"] {
            if identifier == omitLocalization { continue }
            let localization = resourceBundle.appendingPathComponent(
                "\(identifier).lproj",
                isDirectory: true
            )
            try fm.createDirectory(at: localization, withIntermediateDirectories: true)
            try Data("\"Language\" = \"Language\";\n".utf8).write(
                to: localization.appendingPathComponent("Localizable.strings")
            )
        }
    }

    func run(
        scratchPath: URL? = nil,
        bundleModel: Bool = false,
        modelURL: URL? = nil,
        extraEnvironment: [String: String] = [:]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.packageRoot.appendingPathComponent("packaging/package-app.sh").path]
        process.currentDirectoryURL = Self.packageRoot

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = fakeBinURL.path + ":" + (environment["PATH"] ?? "")
        environment["DIST_PATH"] = distURL.path
        environment["STAGE_SOURCE"] = "0"
        environment["FAKE_SWIFT_BIN_PATH"] = swiftBinURL.path
        environment.removeValue(forKey: "SCRATCH_PATH")
        environment.removeValue(forKey: "MODEL_PATH")
        environment.removeValue(forKey: "BUNDLE_MODEL")
        // Never inherit a real signing identity or profile from the developer's
        // shell: the fixture must exercise the ad hoc path unless a test says
        // otherwise, or a stray CODESIGN_IDENTITY would make it sign for real.
        environment.removeValue(forKey: "CODESIGN_IDENTITY")
        environment.removeValue(forKey: "PROVISIONING_PROFILE")
        environment.removeValue(forKey: "NOTARY_PROFILE")
        for (key, value) in extraEnvironment {
            environment[key] = value
        }
        if let modelURL {
            environment["MODEL_PATH"] = modelURL.path
        }
        if bundleModel {
            environment["BUNDLE_MODEL"] = "1"
        }
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

    // MARK: - Distribution signing needs the provisioning profile

    /// The distribution entitlements carry restricted keys that macOS honours
    /// only with an embedded Developer ID provisioning profile; a binary that
    /// claims them without one is killed at exec. The script must refuse to
    /// produce that build, and it must refuse BEFORE reaching codesign, which
    /// is why a dummy identity is safe here: nothing is ever signed.
    func testASignedBuildWithoutAProvisioningProfileIsRefused() throws {
        let result = try run(extraEnvironment: [
            "CODESIGN_IDENTITY": "Developer ID Application: Fixture (FIXTURE00)"
        ])
        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(
            result.output.contains("PROVISIONING_PROFILE is not"),
            "the refusal must name the missing variable: \(result.output)"
        )
        XCTAssertTrue(
            result.output.contains("killed at launch"),
            "the refusal must say WHY a profile-less signed build is unsafe: \(result.output)"
        )
        XCTAssertFalse(
            result.output.contains("Developer ID signing with hardened runtime")
                && result.output.contains("Verifying signature"),
            "refusal must happen before any signing step runs"
        )
    }

    func testASignedBuildWithAMissingProfileFileIsRefused() throws {
        let result = try run(extraEnvironment: [
            "CODESIGN_IDENTITY": "Developer ID Application: Fixture (FIXTURE00)",
            "PROVISIONING_PROFILE": distURL.appendingPathComponent("does-not-exist.provisionprofile").path
        ])
        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(
            result.output.contains("does not exist"),
            "a dangling profile path must be refused, not silently skipped: \(result.output)"
        )
    }

    /// GGUF files sitting in the packaged bundle's Resources directory.
    func bundledModelFileNames() -> [String] {
        let resources = distURL.appendingPathComponent("LDA.app/Contents/Resources")
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: resources.path)) ?? []
        return entries.filter { $0.hasSuffix(".gguf") }.sorted()
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// A one-entry manifest shaped like the real Models.json, including the
    /// field order the script's awk pass relies on.
    private static func manifest(fileName: String, sizeBytes: Int, sha256: String) -> String {
        """
        [
          {
            "id": "quick",
            "level": "quick",
            "displayName": "Quick",
            "fileName": "\(fileName)",
            "sizeBytes": \(sizeBytes),
            "sha256": "\(sha256)"
          }
        ]
        """
    }

    private static func hexDigest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func writeExecutable(
        named name: String,
        in directory: URL,
        contents: String
    ) throws {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: url.path
        )
    }
}
