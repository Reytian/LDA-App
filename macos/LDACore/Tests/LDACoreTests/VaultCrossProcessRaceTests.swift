//
//  VaultCrossProcessRaceTests.swift
//  LDACoreTests
//
//  Finding 7 (2026-09-06 review): DocumentVault's registry read-modify-write
//  transaction was guarded only by an in-process NSLock, so two SEPARATE
//  processes sharing one vault directory (the lda CLI and lda-mcp server
//  both operate on the same vault) could each load the registry, append
//  their own entry, and save: the later write silently discarded the
//  earlier one. Encrypted objects landed on disk and every `lda vault stage`
//  process exited 0 with a distinct handle, but the registry ended up
//  listing only one of them: a silent data-loss defect in a product whose
//  whole premise is that staged material is never silently lost.
//
//  These tests spawn the REAL `lda` executable N times concurrently. An
//  in-process @testable call (as CLIVaultTests uses) cannot reproduce this:
//  it is one process, one NSLock, no cross-process contention at all.
//
//  Isolation matches VaultTestSupport: a private temp vault directory per
//  test and the shared test passphrase over LDA_VAULT_PASSPHRASE, so no
//  child process ever touches the real Keychain.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class VaultCrossProcessRaceTests: XCTestCase {

    private var workDir: URL!

    /// Concurrent staging processes per race. The reviewer's repro used 6;
    /// the fix instructions ask for 8 to leave margin.
    private static let processCount = 8

    /// How many times the whole race is repeated inside one test: a fix that
    /// only narrows the window (rather than closing it) must still fail on
    /// at least one repeat.
    private static let raceRepeats = 3

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultCrossProcessRaceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir, FileManager.default.fileExists(atPath: workDir.path) {
            try? FileManager.default.removeItem(at: workDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Locating the built CLI

    /// A distinct error so a missing executable stops the test via a thrown
    /// error AFTER XCTFail has recorded a message that says how to fix it.
    /// Never XCTSkip here: a silently skipped race test is exactly the kind
    /// of silence this finding is about.
    private struct MissingExecutable: Error {}

    /// Locate the `lda` executable SwiftPM builds next to the xctest bundle
    /// for this test target.
    private func ldaExecutableURL() throws -> URL {
        let candidate = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("lda")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            XCTFail(
                "the lda executable product was not found at \(candidate.path). "
                    + "Build it first, for example: "
                    + "swift build --scratch-path ~/Developer/lda-fix-vault --product lda"
            )
            throw MissingExecutable()
        }
        return candidate
    }

    // MARK: - The race

    /// Spawn processCount `lda vault stage` processes against ONE vault
    /// directory, all started before any is awaited, and assert every
    /// staged document is both encrypted on disk AND registered. Repeated
    /// raceRepeats times so a fix that merely narrows the window still
    /// shows a failure somewhere in the run.
    func testConcurrentCLIStagingRegistersEveryDocument() throws {
        let executable = try ldaExecutableURL()

        for raceIndex in 0 ..< Self.raceRepeats {
            try runOneRace(raceIndex: raceIndex, executable: executable)
        }
    }

    private func runOneRace(raceIndex: Int, executable: URL) throws {
        let raceRoot = workDir.appendingPathComponent("race-\(raceIndex)", isDirectory: true)
        let vaultRoot = raceRoot.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: raceRoot, withIntermediateDirectories: true)

        var environment = ProcessInfo.processInfo.environment
        environment[DocumentVault.passphraseEnvironmentKey] = VaultTestSupport.passphrase

        let processes = try (0 ..< Self.processCount).map { index -> Process in
            let source = raceRoot.appendingPathComponent("source-\(index).txt")
            try Data("synthetic staging race fixture race\(raceIndex) doc\(index)".utf8)
                .write(to: source)

            let process = Process()
            process.executableURL = executable
            process.arguments = ["vault", "stage", source.path, "--vault-dir", vaultRoot.path]
            process.environment = environment
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            return process
        }

        defer {
            for process in processes where process.isRunning {
                process.terminate()
            }
        }

        // Start every process BEFORE waiting on any of them, so all N
        // really contend the SAME registry read-modify-write window.
        for process in processes {
            try process.run()
        }
        for process in processes {
            process.waitUntilExit()
        }

        for (index, process) in processes.enumerated() {
            let errorPipe = process.standardError as? Pipe
            let errorText = errorPipe.map {
                String(decoding: $0.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            } ?? ""
            XCTAssertEqual(
                process.terminationStatus, 0,
                "race \(raceIndex): stage process \(index) exited "
                    + "\(process.terminationStatus): \(errorText)"
            )
        }

        let registered = try VaultTestSupport.vault(root: vaultRoot).list()
        let objectDirectories = try FileManager.default.contentsOfDirectory(
            atPath: vaultRoot.appendingPathComponent(DocumentVault.objectsDirectoryName).path
        )

        XCTAssertEqual(
            registered.count, Self.processCount,
            "race \(raceIndex): expected \(Self.processCount) registered entries but "
                + "found \(registered.count); a concurrent write overwrote the others"
        )
        XCTAssertEqual(
            objectDirectories.count, Self.processCount,
            "race \(raceIndex): expected \(Self.processCount) object directories on disk"
        )
    }

    // MARK: - Registry write atomicity

    /// The registry is written through Data.write(options: .atomic) (temp
    /// file plus rename), so a concurrent reader polling the STABLE path
    /// must never observe a truncated or otherwise malformed file: it sees
    /// either the fully-formed old version or the fully-formed new one.
    /// This is a regression guard for the second half of finding 7's fix
    /// ("an atomic registry write so a crash mid-write cannot corrupt it").
    func testRegistryWriteNeverExposesAPartialFileUnderItsStableName() throws {
        let vaultRoot = workDir.appendingPathComponent("atomic-vault", isDirectory: true)
        let vault = VaultTestSupport.vault(root: vaultRoot)
        let registryPath = vaultRoot.appendingPathComponent(DocumentVault.sealedRegistryFileName).path
        let magic = Array("LDAVREG".utf8)

        var malformedObservations: [String] = []
        let observationsLock = NSLock()
        let stopSignal = DispatchSemaphore(value: 0)
        let pollerFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            while stopSignal.wait(timeout: .now()) == .timedOut {
                if let bytes = FileManager.default.contents(atPath: registryPath) {
                    let wellFormed = bytes.count >= magic.count && Array(bytes.prefix(magic.count)) == magic
                    if !wellFormed {
                        observationsLock.lock()
                        malformedObservations.append("size=\(bytes.count)")
                        observationsLock.unlock()
                    }
                }
            }
            pollerFinished.signal()
        }

        for index in 0 ..< 20 {
            let source = workDir.appendingPathComponent("atomic-source-\(index).txt")
            try Data("atomicity fixture \(index) mail\(index)@example.com".utf8).write(to: source)
            _ = try vault.stage(fileURL: source, stagedAtISO8601: "2026-09-06T00:00:00Z")
        }

        stopSignal.signal()
        _ = pollerFinished.wait(timeout: .now() + 5)

        XCTAssertTrue(
            malformedObservations.isEmpty,
            "registry.sealed must never be visible as a partial file under its stable "
                + "name; observed: \(malformedObservations)"
        )
    }
}
