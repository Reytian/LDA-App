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

    /// Default on-disk location of the GGUF model, relative to the home
    /// directory. The one place this path is written down.
    static let defaultModelSubpath = "Developer/lda-models/lda-v2-Q4_K_M.gguf"

    /// The GGUF model path, or nil when the model is not installed.
    ///
    /// Resolve order: the LDA_MODEL_PATH environment override, then the
    /// default location under the home directory.
    static func modelPath() -> String? {
        if let override = ProcessInfo.processInfo.environment[modelPathEnvironmentKey],
           FileManager.default.fileExists(atPath: override) {
            return override
        }
        let candidate = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(defaultModelSubpath)
            .path
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }

    /// The GGUF model path, or an XCTSkip when the model is not installed, so
    /// the suite stays green on a machine without the 2.7 GB download.
    static func requireModelPath() throws -> String {
        guard let path = modelPath() else {
            throw XCTSkip(
                "GGUF model not present; set \(modelPathEnvironmentKey) or place it at "
                    + "~/\(defaultModelSubpath)"
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
