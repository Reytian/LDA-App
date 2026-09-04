//
//  LiveModelTestSupport.swift
//  LDACoreTests
//
//  The single chokepoint for tests that load the real GGUF model.
//
//  Why a lock: the model is 2.7 GB and llama.cpp puts it in Metal's unified
//  memory. One process fits; two do not. When two suites run at once from two
//  worktrees, the second allocation fails with
//  kIOGPUCommandBufferCallbackErrorOutOfMemory, and llama.cpp does NOT throw.
//  It keeps decoding and returns garbage, so the assertions fail on content
//  ("missing COMPANY value; got:  WHERE") and the run reports a different
//  failure count every time. That is the mechanism behind the observed
//  "12 failures, then 0, then 7" on one unchanged commit, and no amount of
//  Keychain or UserDefaults namespacing addresses it: the GPU is one machine
//  resource, not a per-process one.
//
//  So live-model tests take a machine-wide advisory lock and run one at a time
//  across every process on the machine. Serial per test, correct in every
//  interleaving. The cost is wall-clock time when suites overlap, which is the
//  right trade against a suite that reports a different number every run.
//
//  The lock file lives in the per-user temporary directory, which every test
//  process of one user resolves to the same path, so it is the same lock for
//  every worktree.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import XCTest

enum LiveModelTestSupport {

    // MARK: - Model resolution

    /// Launch-environment key that overrides the model location.
    static let modelPathEnvironmentKey = "LDA_MODEL_PATH"

    /// Directory that holds installed GGUF models, relative to the home
    /// directory. The one place this DIRECTORY is written down.
    static let modelDirectorySubpath = "Developer/lda-models"

    /// Absolute location of that directory.
    static var modelDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(modelDirectorySubpath)
    }

    /// The shipped detection-tier catalog, read from the source tree.
    static var catalogURL: URL {
        URL(fileURLWithPath: #filePath)          // .../Tests/LDACoreTests/<this file>
            .deletingLastPathComponent()          // .../Tests/LDACoreTests
            .deletingLastPathComponent()          // .../Tests
            .deletingLastPathComponent()          // package root
            .appendingPathComponent("Sources/LDAUI/Resources/Models.json")
    }

    /// File name of the smallest catalog tier, read from Models.json rather
    /// than restated here.
    ///
    /// This used to be a hardcoded "lda-v2-Q4_K_M.gguf". That fine-tune was
    /// later retired in favour of stock Qwen3.5-4B and the constant was never
    /// updated, so modelPath() resolved a file that no longer exists, every
    /// caller turned the nil into XCTSkip, and all eight live-model tests went
    /// quiet WITHOUT A SINGLE FAILURE. XCTSkip is green, so a summary line
    /// reading "2158 tests, 0 failures" was indistinguishable from one where
    /// the model had actually loaded, and PERSON detection is LLM-only. Reading
    /// the catalog means retiring the next model breaks ONE test loudly
    /// instead of silently disarming the live suite.
    static func catalogModelFileName() -> String? {
        guard let data = try? Data(contentsOf: catalogURL),
              let tiers = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let smallest = tiers.first,
              let fileName = smallest["fileName"] as? String,
              !fileName.isEmpty
        else { return nil }
        return fileName
    }

    /// Every .gguf actually sitting in the model directory.
    static func installedModelFileNames() -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: modelDirectoryURL,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents
            .filter { $0.pathExtension.lowercased() == "gguf" }
            .map { $0.lastPathComponent }
            .sorted()
    }

    /// The GGUF model path, or nil when the model is not installed.
    ///
    /// Resolve order: the LDA_MODEL_PATH environment override, then the
    /// smallest catalog tier inside the model directory.
    static func modelPath() -> String? {
        if let override = ProcessInfo.processInfo.environment[modelPathEnvironmentKey],
           FileManager.default.fileExists(atPath: override) {
            return override
        }
        guard let fileName = catalogModelFileName() else { return nil }
        let candidate = modelDirectoryURL.appendingPathComponent(fileName).path
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }

    /// The GGUF model path, or an XCTSkip when the model is not installed, so
    /// the suite stays green on a machine without the 2.7 GB download.
    ///
    /// The message names the directory searched AND the file wanted, because
    /// the failure this replaces was a skip that said neither.
    static func requireModelPath() throws -> String {
        guard let path = modelPath() else {
            let wanted = catalogModelFileName() ?? "(catalog unreadable)"
            let present = installedModelFileNames()
            let presentNote = present.isEmpty
                ? "that directory holds no .gguf at all"
                : "that directory holds: \(present.joined(separator: ", "))"
            throw XCTSkip(
                "GGUF model not present. Wanted \(wanted) in "
                    + "\(modelDirectoryURL.path); \(presentNote). "
                    + "Set \(modelPathEnvironmentKey) to override."
            )
        }
        return path
    }

    // MARK: - Machine-wide exclusive access

    /// Path of the advisory lock every live-model test contends for. Derived
    /// from the per-user temporary directory so all of this user's test
    /// processes, in every worktree, agree on it.
    static var lockFileURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lda-live-model-tests.lock")
    }

    /// Run body while holding exclusive, machine-wide access to the GPU-resident
    /// model. Blocks until any other test process has released it.
    ///
    /// The wait is unbounded on purpose. A timeout would have to either fail a
    /// test that is fine or run it unlocked, and running it unlocked is the
    /// exact flake this helper exists to remove. A holder that dies releases
    /// the lock anyway: flock is tied to the open file description, so the
    /// kernel drops it when the process exits, crash included.
    ///
    /// Create the engine INSIDE body. Its locals are released when body
    /// returns, which happens before the deferred unlock, so the model is out
    /// of unified memory before the next waiter is admitted.
    ///
    /// A lock that cannot be taken (an unwritable temporary directory) is not
    /// worth failing a test over: body still runs, unserialized, exactly as it
    /// did before this helper existed.
    static func withExclusiveModelAccess<T>(_ body: () throws -> T) rethrows -> T {
        guard let handle = Lock.acquire(at: lockFileURL) else {
            return try body()
        }
        defer { handle.release() }
        return try body()
    }

    /// The model path plus exclusive machine-wide access for the duration of
    /// body. The one call live-model tests should use.
    ///
    /// Skips before taking the lock when the model is absent, so a machine
    /// without the download never waits on anything.
    static func withLiveModel<T>(_ body: (String) throws -> T) throws -> T {
        let path = try requireModelPath()
        return try withExclusiveModelAccess { try body(path) }
    }

    /// An flock-based advisory lock. flock is per open file description and is
    /// dropped by the kernel when the descriptor closes, so a crashed test
    /// process cannot wedge the lock for the others.
    private struct Lock {
        let descriptor: Int32

        static func acquire(at url: URL) -> Lock? {
            let descriptor = open(url.path, O_CREAT | O_RDWR, 0o644)
            guard descriptor >= 0 else { return nil }
            // Blocking exclusive lock. EINTR is the only retryable failure.
            while flock(descriptor, LOCK_EX) != 0 {
                if errno == EINTR { continue }
                close(descriptor)
                return nil
            }
            return Lock(descriptor: descriptor)
        }

        func release() {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }
}
