//
//  TestHermeticityTests.swift
//  LDACoreTests
//
//  Enforces the invariant that makes concurrent test runs trustworthy.
//
//  `swift test --scratch-path` isolates build products. It does NOT isolate the
//  Keychain or the UserDefaults database, which are per user, nor the GPU, which
//  is per machine. On 2026-08-31 two concurrent runs of one unchanged commit
//  reported "1647 tests, 12 failures" and "1647 tests, 7 failures", and a third
//  serial run reported zero. A suite that reports a different number depending
//  on what else is running cannot be used to decide whether a change is safe.
//
//  These checks are static: they read the test sources the way
//  NetworkChokepointTests reads Sources/, and fail when a NEW test reintroduces
//  a machine-global name. That is deliberate. The failure they guard against is
//  a race, and a race cannot be caught reliably by running it; the property
//  ("no test names anything another process could also name") can be checked
//  exactly.
//
//  If one of these fails, the fix is never to add an allowlist entry for
//  convenience. Route the name through TestNamespace, which is unique per
//  process by construction.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest

final class TestHermeticityTests: XCTestCase {

    // MARK: - Source access

    /// The test target's source directory, located relative to this file so the
    /// check follows the sources when they move.
    private static let testSourceDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()

    private struct SourceFile {
        let name: String
        let text: String
        /// Every string literal in the file, quotes stripped. Good enough for
        /// this purpose: the test sources contain no raw strings and no
        /// escaped quotes inside a literal on a line we care about.
        let literals: [String]
    }

    private func testSources() throws -> [SourceFile] {
        let names = try FileManager.default
            .contentsOfDirectory(atPath: Self.testSourceDirectory.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        XCTAssertGreaterThan(names.count, 100, "the test sources were not found")

        return try names.map { name in
            let text = try String(
                contentsOf: Self.testSourceDirectory.appendingPathComponent(name),
                encoding: .utf8
            )
            return SourceFile(name: name, text: text, literals: Self.stringLiterals(in: text))
        }
    }

    /// Extract string literals, skipping full-line comments so that prose about
    /// a banned name does not trip the checks that read literals.
    private static func stringLiterals(in text: String) -> [String] {
        var found: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
            var current: String?
            var previous: Character?
            for character in line {
                if character == "\"", previous != "\\" {
                    if let open = current {
                        found.append(open)
                        current = nil
                    } else {
                        current = ""
                    }
                } else if current != nil {
                    current?.append(character)
                }
                previous = character
            }
        }
        return found
    }

    /// Lines of code (comments dropped) that contain needle.
    private func codeLines(_ file: SourceFile, containing needle: String) -> [String] {
        file.text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .filter { $0.contains(needle) }
    }

    /// The argument text following `label` on a line, up to the matching close
    /// paren or the end of the line. Enough to tell a plain literal from an
    /// expression.
    private func argument(after label: String, on line: String) -> String? {
        guard let start = line.range(of: label) else { return nil }
        let rest = line[start.upperBound...]
        guard let close = rest.firstIndex(of: ")") else {
            return String(rest).trimmingCharacters(in: .whitespaces)
        }
        return String(rest[..<close]).trimmingCharacters(in: .whitespaces)
    }

    /// True when text is a bare string literal with no interpolation, which is
    /// the shape that names something every process would also name.
    private func isPlainLiteral(_ text: String) -> Bool {
        text.hasPrefix("\"") && !text.contains("\\(")
    }

    // MARK: - Rule 1: the shared UserDefaults domain

    /// UserDefaults.standard is one domain per user, so two test processes read
    /// and write the same keys. A test that clears a key there also clears it
    /// for the other run, and a test that asserts a key is absent can be
    /// contradicted by the other run restoring it.
    func testNoTestReadsOrWritesTheSharedUserDefaultsDomain() throws {
        let offenders = try testSources()
            .filter { $0.name != "TestHermeticityTests.swift" }
            .filter { !codeLines($0, containing: "UserDefaults.standard").isEmpty }
            .map(\.name)

        XCTAssertEqual(
            offenders, [],
            "these suites use the shared UserDefaults domain. Inject a private "
                + "suite from TestNamespace.defaults(_:) through the seam the "
                + "production type exposes."
        )
    }

    /// Every suite that creates a UserDefaults suite must derive the name from
    /// TestNamespace, so the name carries this process's token.
    func testEveryUserDefaultsSuiteNameComesFromTheProcessNamespace() throws {
        let offenders = try testSources()
            .filter { $0.name != "TestHermeticityTests.swift" && $0.name != "TestNamespace.swift" }
            .filter { !codeLines($0, containing: "UserDefaults(suiteName:").isEmpty }
            .filter { !$0.text.contains("TestNamespace.") }
            .map(\.name)

        XCTAssertEqual(
            offenders, [],
            "these suites build a UserDefaults suite name without TestNamespace. "
                + "A UUID happens to be unique too, but routing every name "
                + "through one place is what keeps the guarantee checkable."
        )
    }

    // MARK: - Rule 2: Keychain deletions

    /// Every call that removes a Keychain item from a test. One list, so a new
    /// deletion helper is covered by both deletion rules at once.
    private let deleteCalls = [
        "LocalDataVault.deleteKey(account:",
        "deleteKeychainKey(account:",
        "deleteDigestKeyForTesting(account:"
    ]


    /// Accounts a test deletes must be ones it minted. A plain string literal
    /// names an account every concurrent process would also name, so deleting
    /// it destroys the other run's key while that run is still using it.
    func testEveryKeychainDeletionNamesAProcessUniqueAccount() throws {
        var offenders: [String] = []

        for file in try testSources() where file.name != "TestHermeticityTests.swift" {
            for call in deleteCalls {
                for line in codeLines(file, containing: call) {
                    guard let argument = argument(after: call, on: line) else { continue }
                    if isPlainLiteral(argument) {
                        offenders.append("\(file.name): \(argument)")
                    }
                }
            }
        }

        XCTAssertEqual(
            offenders, [],
            "these deletions target a fixed account name. Mint the account with "
                + "TestNamespace.keychainAccount(_:) or TestNamespace.storeBaseKey(_:) "
                + "and delete only that."
        )
    }

    /// Some accounts are shared by design: the records key, the audit keys, the
    /// portfolio library keys, the parked-session key, and the production store
    /// base keys. A test may read them. A test must NEVER delete one: deleting
    /// a shared legacy account also removes its ".userpresence" variant, which
    /// is the item Touch ID unlocks, so the deletion breaks the developer's
    /// machine and not just the run.
    func testNoTestDeletesASharedOrLegacyKeychainAccount() throws {
        let sharedAccountMarkers = [
            "SessionRecordStore.keychainAccount",
            "SecurityEventLog.keychainAccount",
            "SecurityEventLog.digestKeyKeychainAccount",
            "DocumentVault.masterKeyAccount",
            "LearningStore.defaultStorageKey",
            "CustomPatternStore.defaultStorageKey",
            "lda-parked-session",
            "\"records\"",
            "\"index\"",
            "\"library\""
        ]
        var offenders: [String] = []

        for file in try testSources() where file.name != "TestHermeticityTests.swift" {
            for call in deleteCalls {
                for line in codeLines(file, containing: call) {
                    guard let argument = argument(after: call, on: line) else { continue }
                    for marker in sharedAccountMarkers where argument.contains(marker) {
                        offenders.append("\(file.name): \(argument)")
                    }
                }
            }
        }

        XCTAssertEqual(
            offenders, [],
            "these deletions target an account that is shared by design. Reading "
                + "one is fine; deleting one removes the .userpresence variant "
                + "Touch ID depends on."
        )
    }

    /// A fixed Keychain account is one account for the whole machine. Two
    /// concurrent processes then race on creating it: whichever loses gets
    /// errSecDuplicateItem, and the suites that treat any Keychain error as
    /// "unavailable" turn that into a skip, so the two runs report different
    /// numbers even when nothing failed.
    func testNoTestSealsUnderAFixedKeychainAccount() throws {
        /// Files that must name a fixed account, with the reason. Each has been
        /// read: the account belongs to the type under test, and no test in the
        /// file deletes it, so a concurrent run can only read the same key.
        let audited: [String: String] = [
            // PortfolioLibrary writes its index under its own account "index".
            // A test that hand-crafts an index file has to use that name or the
            // library cannot open what the test wrote.
            "PortfolioLibraryTests.swift": "the library's own index account",
            "TestHermeticityTests.swift": "names the pattern"
        ]
        /// Every way a test names the account it will seal under, including the
        /// derivations the CLI and the MCP server apply to a document base name:
        /// "doc.txt" there is "lda-doc_redacted" in the Keychain, which is one
        /// account for the whole machine.
        let accountCalls = [
            ".keychain(account:",
            "keychainAccount(forMappingBaseName:"
        ]
        var offenders: [String] = []

        for file in try testSources() where audited[file.name] == nil {
            for call in accountCalls {
                for line in codeLines(file, containing: call) {
                    guard let argument = argument(after: call, on: line) else { continue }
                    if isPlainLiteral(argument) {
                        offenders.append("\(file.name): \(call) \(argument)")
                    }
                }
            }
        }

        XCTAssertEqual(
            offenders, [],
            "these tests seal under a fixed Keychain account. Mint one with "
                + "TestNamespace.keychainAccount(_:) or a document base name "
                + "from TestNamespace.fileBaseName(_:), or add the file to the "
                + "audited list with the reason the fixed name is required."
        )
    }

    // MARK: - Rule 3: store base keys

    /// LearningStore and CustomPatternStore derive their vault account from the
    /// storage key: "store." + storageKey. A fixed storage key is therefore a
    /// fixed Keychain account, shared across every concurrent process.
    func testNoStoreBaseKeyIsAFixedLiteral() throws {
        let labels = ["storageKey:", "baseKey:"]
        var offenders: [String] = []

        for file in try testSources() where file.name != "TestHermeticityTests.swift" {
            for label in labels {
                for line in codeLines(file, containing: label) {
                    guard let argument = argument(after: label, on: line) else { continue }
                    // Trim a trailing argument so "storageKey: "k", x: y" reads.
                    let head = argument.split(separator: ",").first.map(String.init) ?? argument
                    if isPlainLiteral(head.trimmingCharacters(in: .whitespaces)) {
                        offenders.append("\(file.name): \(label) \(head)")
                    }
                }
            }
        }

        XCTAssertEqual(
            offenders, [],
            "these store keys are fixed strings, so the vault account "
                + "\"store.<key>\" is shared with every concurrent test process. "
                + "Use TestNamespace.storeBaseKey(_:)."
        )
    }

    /// The production store base keys end in "learnedTerms" and
    /// "customPatterns". A test-local key that copies that suffix is still a
    /// fixed name; naming it through TestNamespace is the only shape allowed,
    /// and TestNamespace labels do not repeat the production suffix.
    func testNoTestSourceHardCodesAStoreBaseKeySuffix() throws {
        let bannedSuffixes = ["learnedTerms", "customPatterns"]
        let allowed: Set<String> = ["TestHermeticityTests.swift", "TestNamespace.swift"]
        var offenders: [String] = []

        for file in try testSources() where !allowed.contains(file.name) {
            for literal in file.literals {
                for suffix in bannedSuffixes where literal.contains(suffix) {
                    offenders.append("\(file.name): \"\(literal)\"")
                }
            }
        }

        XCTAssertEqual(
            offenders, [],
            "these literals hard-code a store base key. Mint one with "
                + "TestNamespace.storeBaseKey(_:) instead; the label it takes "
                + "must not repeat the production suffix."
        )
    }

    // MARK: - Rule 4: the GPU is one machine resource

    /// The GGUF model path belongs in exactly one place, so that every live
    /// load goes through the helper that serializes access to it.
    func testTheLiveModelPathIsResolvedInOnePlace() throws {
        let needle = "Developer/lda-models"
        /// Files that mention the path without loading a model. Each has been
        /// read: they build a fixture path or a UserDefaults value, never an
        /// LLMEngine.
        let auditedNonLoaders: Set<String> = [
            "LiveModelTestSupport.swift",
            "TestHermeticityTests.swift",
            "MCPPathPolicyTests.swift",
            "DetectionReportingTests.swift"
        ]

        let offenders = try testSources()
            .filter { !auditedNonLoaders.contains($0.name) }
            .filter { !codeLines($0, containing: needle).isEmpty }
            .map(\.name)

        XCTAssertEqual(
            offenders, [],
            "these suites resolve the model path themselves. Call "
                + "LiveModelTestSupport.requireModelPath(), which is the same "
                + "chokepoint that takes the machine-wide model lock."
        )
    }

    /// Two processes cannot both hold a 2.7 GB model in unified memory. The
    /// second allocation fails inside Metal, llama.cpp does not throw, and the
    /// test fails on garbage output instead. Every path that can reach a live
    /// model must therefore run inside the lock-holding helper.
    func testEveryLiveModelTestTakesTheMachineWideModelLock() throws {
        /// Ways a test can end up with a resident model.
        let liveModelEntryPoints = [
            "LiveModelTestSupport.requireModelPath",
            "LiveModelTestSupport.modelPath",
            "LLMEngine(config:"
        ]
        /// The two calls that hold the lock for the duration of their body.
        let lockHolders = ["withLiveModel", "withExclusiveModelAccess"]

        /// The support file that defines the chokepoint and this file, which
        /// quotes the needles as data.
        let infrastructure: Set<String> = [
            "LiveModelTestSupport.swift",
            "TestHermeticityTests.swift"
        ]
        /// Suites that RESOLVE the path but provably never load, mirroring
        /// testTheLiveModelPathIsResolvedInOnePlace's auditedNonLoaders.
        ///
        /// LiveModelResolverTests asserts on resolution itself: whether the
        /// catalog and the installed file agree. It cannot be wrapped in
        /// withLiveModel, because that calls requireModelPath, which throws
        /// XCTSkip when the model is absent, and a skip is precisely the
        /// silence that suite exists to break: a resolver pointed at a retired
        /// filename once disarmed all eight live tests without one failure.
        /// The exemption is policed below rather than trusted.
        let auditedNonLoaders: Set<String> = ["LiveModelResolverTests.swift"]

        let offenders = try testSources()
            .filter { !infrastructure.contains($0.name) }
            .filter { !auditedNonLoaders.contains($0.name) }
            .filter { file in
                liveModelEntryPoints.contains { !codeLines(file, containing: $0).isEmpty }
            }
            .filter { file in
                lockHolders.allSatisfy { codeLines(file, containing: $0).isEmpty }
            }
            .map(\.name)

        XCTAssertEqual(
            offenders, [],
            "these suites can load the real model without holding the machine-wide "
                + "lock, so a concurrent run silently starves the GPU and both "
                + "runs report different numbers. Wrap the body in "
                + "LiveModelTestSupport.withLiveModel."
        )

        // An exemption by name is only sound while the claim behind it holds,
        // so assert the claim instead of the name: an audited non-loader must
        // not construct an engine and must not reach the locking chokepoint.
        // Add a load to one of those files and this fires, rather than the
        // exemption quietly outliving the audit that justified it.
        for file in try testSources() where auditedNonLoaders.contains(file.name) {
            XCTAssertTrue(
                codeLines(file, containing: "LLMEngine(").isEmpty,
                "\(file.name) is exempt from the model lock on the grounds that it "
                    + "never loads a model, but it now constructs an engine. Either "
                    + "wrap it in withLiveModel or drop the exemption."
            )
            XCTAssertTrue(
                codeLines(file, containing: "requireModelPath").isEmpty,
                "\(file.name) is exempt from the model lock on the grounds that it "
                    + "never loads a model, but it now calls requireModelPath, which "
                    + "both resolves and locks. Drop the exemption."
            )
        }
    }

    // MARK: - The namespace itself

    func testTheProcessTokenCarriesThePidAndIsStable() {
        let pid = ProcessInfo.processInfo.processIdentifier
        XCTAssertTrue(
            TestNamespace.token.hasPrefix("p\(pid)x"),
            "the token must name the process that leaked an item; got \(TestNamespace.token)"
        )
        XCTAssertEqual(
            TestNamespace.token, TestNamespace.token,
            "the token is computed once per process"
        )
        XCTAssertGreaterThan(
            TestNamespace.token.count, "p\(pid)x".count,
            "a pid alone is not unique: pids are recycled"
        )
    }

    func testEveryDerivedNameIsUniquePerCallAndCarriesTheToken() {
        let names = [
            TestNamespace.suiteName("suite"),
            TestNamespace.keychainAccount("account"),
            TestNamespace.storeBaseKey("learned"),
            TestNamespace.storeBaseKey("learned")
        ]

        for name in names {
            XCTAssertTrue(
                name.hasPrefix("\(TestNamespace.prefix).\(TestNamespace.token)."),
                "\(name) does not carry the process token"
            )
        }
        XCTAssertEqual(
            Set(names).count, names.count,
            "two calls must never return the same name, even for the same label"
        )
    }

    /// A UserDefaults suite is a plist in ~/Library/Preferences, and
    /// removePersistentDomain does NOT erase it: it clears the value in memory
    /// and leaves the old one on disk. This asserts on the FILE, because an
    /// in-memory read comes back nil either way and would pass while a sealed
    /// blob of party names sat in Preferences.
    func testTheExitSweepErasesTheSuiteFileAndNotJustTheInMemoryValue() throws {
        let (defaults, name) = TestNamespace.defaults("sweep")
        defaults.set("a-sealed-blob-stand-in", forKey: "k.sealed")
        defaults.synchronize()

        let path = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Preferences")
            .appendingPathComponent("\(name).plist")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: path.path),
            "pre-condition: writing to a suite creates its plist"
        )

        TestNamespace.sweepMintedSuites()

        XCTAssertNil(
            UserDefaults(suiteName: name)?.string(forKey: "k.sealed"),
            "the sweep must clear the value"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: path.path),
            "the sweep must erase the file: removePersistentDomain alone leaves "
                + "the old contents readable on disk"
        )
    }

    func testAFreshSuiteIsEmptySoDomainAssertionsMeanSomething() {
        let (defaults, name) = TestNamespace.defaults("emptiness")
        defer { defaults.removePersistentDomain(forName: name) }

        XCTAssertEqual(
            (defaults.persistentDomain(forName: name) ?? [:]).keys.sorted(), [],
            "a generated suite name has never existed, so its domain is empty"
        )
    }
}
