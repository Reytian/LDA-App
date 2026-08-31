//
//  TestNamespace.swift
//  LDACoreTests
//
//  A per-PROCESS namespace for every machine-global name a test creates.
//
//  Why this exists: `swift test --scratch-path` isolates BUILD products only.
//  The Keychain and the UserDefaults database are per USER, so two suites
//  running at once from two worktrees share them. A test that mints a
//  fixed-name vault account and drops it in tearDown therefore deletes the
//  other process's key mid-test, and the other process fails while reading a
//  blob it sealed correctly. Evidence: main reported "1647 tests, 12 failures"
//  and "1647 tests, 7 failures" for the same commit in two concurrent runs.
//
//  The rule this file enforces by construction: every Keychain account, every
//  UserDefaults suite, and every store base key a test creates carries `token`,
//  which is unique to this process. Two concurrent suites then cannot name the
//  same thing, so neither can read, overwrite, or delete the other's state.
//
//  What this file deliberately does NOT do: rename or delete anything that is
//  shared by design (the records key, the audit keys, the portfolio library
//  index key, legacy per-file accounts). Those are production accounts. A test
//  may read them; a test must never delete one, because deleting a shared
//  legacy account also removes its ".userpresence" variant and breaks Touch ID
//  on the developer's machine. TestHermeticityTests enforces both halves.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import XCTest

enum TestNamespace {

    /// The prefix every generated name starts with, so leftovers are obviously
    /// test litter and can be swept by name.
    static let prefix = "ldatest"

    /// Unique to this test process: the pid plus a random component, computed
    /// once. The pid alone is not enough because pids are recycled, and the
    /// random part alone loses the ability to attribute litter to a run.
    static let token: String = {
        let pid = ProcessInfo.processInfo.processIdentifier
        let entropy = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .prefix(12)
        return "p\(pid)x\(entropy)"
    }()

    // MARK: - Derived names

    /// A UserDefaults suite name unique to this process and this call.
    ///
    /// Suite names are also the argument to removePersistentDomain(forName:),
    /// so callers must keep the returned value to clean up. Prefer
    /// `defaults(_:)`, which hands back both.
    ///
    /// Recorded for the exit sweep here rather than in `defaults(_:)`: a name
    /// minted through this function is handed straight to
    /// UserDefaults(suiteName:) by the caller, and recording at the one place
    /// every suite name is born is what makes the sweep complete.
    static func suiteName(_ label: String) -> String {
        let name = unique(label)
        record(suiteName: name)
        return name
    }

    /// A Keychain account unique to this process and this call. Safe to delete
    /// in tearDown: nothing else on the machine can be using it.
    static func keychainAccount(_ label: String) -> String {
        unique(label)
    }

    /// A base key for LearningStore / CustomPatternStore (their `storageKey`
    /// and `baseKey` parameters), unique to this process and this call.
    ///
    /// Stability matters here: a suite holds the returned value in a `let` and
    /// uses it for both the store and the tearDown cleanup, so the store's
    /// vault account and the account tearDown deletes are the same one. Two
    /// processes never agree on the value, which is the whole point.
    static func storeBaseKey(_ label: String) -> String {
        unique(label)
    }

    /// A file-name-safe unique base name, for tests where the tool under test
    /// derives a Keychain account from a document's base name (the CLI's
    /// "lda-<mapping base>" is the case that matters). Dashes rather than dots,
    /// so `deletingPathExtension()` still behaves.
    static func fileBaseName(_ label: String) -> String {
        "\(label)-\(token)-\(nextSequence())"
    }

    /// A fresh, empty UserDefaults suite plus the name needed to remove it.
    ///
    /// The suite is empty because the name has never existed before, which is
    /// what makes assertions about "nothing else is in this domain" meaningful.
    ///
    /// The name is recorded for the exit sweep by `suiteName(_:)`, so a suite
    /// whose owner forgets `removePersistentDomain(forName:)` still does not
    /// leave a plist in ~/Library/Preferences.
    static func defaults(_ label: String) -> (defaults: UserDefaults, name: String) {
        let name = suiteName(label)
        // A brand new suite name always resolves, so the force unwrap cannot
        // fire; UserDefaults(suiteName:) returns nil only for a name that
        // collides with a reserved domain such as the standard one.
        guard let defaults = UserDefaults(suiteName: name) else {
            fatalError("UserDefaults refused the generated suite name \(name)")
        }
        return (defaults, name)
    }

    // MARK: - Exit sweep

    /// Erase every UserDefaults suite this process minted.
    ///
    /// Why this is not left to each tearDown, and why it does more than call
    /// removePersistentDomain: MEASURED on macOS 26, `removePersistentDomain`
    /// followed by `synchronize()` clears the value in memory and leaves the
    /// old value ON DISK. A probe that wrote "secret-value", removed the
    /// domain, synchronized, and then read the file from the shell still found
    /// `"k.sealed" => "secret-value"` in ~/Library/Preferences. Every cleanup
    /// in this suite that trusts removePersistentDomain alone has therefore
    /// been leaving its data behind, which for LearningStore and
    /// CustomPatternStore is a sealed blob of learned party names whose vault
    /// key is also on the machine.
    ///
    /// So: remove the domain (which is what makes the in-process state
    /// correct), then unlink the plist (which is what actually erases it).
    ///
    /// Runs from an XCTest observer rather than atexit because at atexit the
    /// process dies before cfprefsd applies anything at all.
    ///
    /// Idempotent, and safe by construction: the only paths it can unlink are
    /// suites named by `unique(_:)`, which this process minted.
    ///
    /// cfprefsd may still write an EMPTY plist for the domain name afterwards.
    /// That shell carries no data and is not worth chasing; what matters, and
    /// what TestHermeticityTests asserts, is that no value survives on disk.
    static func sweepMintedSuites() {
        let names: [String] = suiteLock.withLock {
            let snapshot = mintedSuiteNames
            mintedSuiteNames = []
            return snapshot
        }
        for name in names {
            guard name.hasPrefix("\(prefix)."), let suite = UserDefaults(suiteName: name) else {
                continue
            }
            suite.removePersistentDomain(forName: name)
            suite.synchronize()
            try? FileManager.default.removeItem(at: preferencesFileURL(suiteName: name))
        }
    }

    /// Where a suite's plist lives. Not a public detail of UserDefaults, but
    /// erasing a suite is not possible through the API alone.
    private static func preferencesFileURL(suiteName name: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Preferences", isDirectory: true)
            .appendingPathComponent("\(name).plist")
    }

    private static let suiteLock = NSLock()
    private static var mintedSuiteNames: [String] = []
    private static var didRegisterSweep = false

    private static func record(suiteName name: String) {
        suiteLock.withLock {
            mintedSuiteNames.append(name)
            guard !didRegisterSweep else { return }
            didRegisterSweep = true
            XCTestObservationCenter.shared.addTestObserver(SuiteSweeper.shared)
        }
    }

    // MARK: - Uniqueness

    private static let sequenceLock = NSLock()
    private static var sequence = 0

    private static func nextSequence() -> Int {
        sequenceLock.withLock {
            sequence += 1
            return sequence
        }
    }

    /// "ldatest.<pid+random>.<n>.<label>": process-unique through the token,
    /// call-unique through the counter, and readable through the label.
    private static func unique(_ label: String) -> String {
        "\(prefix).\(token).\(nextSequence()).\(label)"
    }
}

/// Sweeps the minted UserDefaults suites when the test bundle finishes, which
/// is the last point at which the process can still talk to cfprefsd.
private final class SuiteSweeper: NSObject, XCTestObservation {

    /// Retained for the life of the process: XCTestObservationCenter holds
    /// observers weakly.
    static let shared = SuiteSweeper()

    func testBundleDidFinish(_ testBundle: Bundle) {
        TestNamespace.sweepMintedSuites()
    }
}
