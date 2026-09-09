//
//  NetworkChokepointTests.swift
//  LDACoreTests
//
//  Enforces the invariant the privacy claim rests on.
//
//  LDA.app carries com.apple.security.network.client so it can download models.
//  Its own network access is limited to model downloads. A user-selected
//  tutorial link may open a fixed GitHub page in the default browser, and a
//  support link may open a blank email addressed to the fixed support mailbox.
//  Before the entitlement, the OS enforced the download boundary and a reviewer
//  could verify it by reading one file. Now WE enforce it, so it needs to be
//  checked by something that runs on every commit rather than by discipline.
//
//  If a second file legitimately needs the network, that is a product decision
//  that requires the published wording to change. It is not a matter of adding
//  a name to the list below.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import XCTest

final class NetworkChokepointTests: XCTestCase {

    /// The one file permitted to use the network.
    private let allowedFile = "ModelInstaller.swift"

    /// URL-taking APIs that are network capable but are used here on local
    /// files or the built-in local LDA bridge only. Each entry has been read and confirmed to build its URL from
    /// a file path. They are listed rather than ignored so that a NEW use is
    /// still flagged and has to be justified: `Data(contentsOf:)` on a remote
    /// URL performs a synchronous network GET that no amount of URLSession
    /// auditing would reveal.
    private let auditedLocalOnlyAPIs: [String: Set<String>] = [
        "Data(contentsOf:": [
            "ModelTiers.swift",        // Models.json from the app bundle
            "SettingsView.swift",      // profile JSON chosen in an open panel
            "EncryptedContainer.swift",// the encrypted mapping container
            "TextDocumentIO.swift"     // a document the user opened
        ],
        // The URL is generated from MCPWorkspaceRequest, never passed through from an
        // MCP argument. It always has the lda-mcp scheme and targets the local LDA app.
        // MCPWorkspaceBridgeTests verifies the request shape and rejects other schemes.
        "NSWorkspace.shared.open": ["MCPWorkspaceTools.swift"],
        "String(contentsOf:": [
            "NetworkChokepointTests.swift",
            "LegalAcceptance.swift"    // bundled Markdown; requires a file URL
        ]
    ]

    // The user requested this browser link during setup. Match the entire line
    // so an additional URL, query string or document-derived destination is refused.
    private let tutorialBrowserLink = #"Link(destination: URL(string: "https://github.com/Reytian/LDA-App/releases/tag/tutorials-20260909")!) {"#

    // This fixed mailto URL contains no subject, body, attachment, or app data.
    private let supportEmailLink = #"Link(destination: URL(string: "mailto:formelocale@protonmail.com")!) {"#

    /// Symbols that indicate outbound network capability.
    private let networkSymbols = [
        "URLSession", "NSURLSession", "CFSocket", "NWConnection",
        "Network.framework", "socket(",
        // CFStream alone never matches CFReadStream/CFWriteStream, which are
        // the names that actually appear.
        "CFReadStream", "CFWriteStream",
        // Opening a URL hands the request to another app, which still reaches
        // the network on the user's behalf.
        "NSWorkspace.shared.open", "WKWebView",
        // SwiftUI's own two ways of doing the same thing. Listed because the
        // model catalog now carries an offline release page URL, and the
        // decision was that it stays COPYABLE TEXT: a Link or an openURL call
        // would hand a request to a browser, which is the act the entitlement
        // rationale describes. Adding one is a product decision, not a tidy-up.
        //
        // Spelled with the parenthesis, and with the trailing paren on the
        // environment key, so the local helper `openURLs(_:)` in
        // DocumentPane.swift (which opens documents the user dropped) is not a
        // false positive.
        //
        // "Link(" also matches any identifier ENDING in Link, such as a
        // `copyOfflineLink(...)` helper or `createSymbolicLink(...)`. When that
        // happens the fix is to rename the identifier, not to loosen this list:
        // a substring check that a reviewer can read in one line is worth more
        // than a precise one nobody trusts.
        "Link(", ".openURL)", "openURL(",
        // These take a URL and will happily perform a synchronous GET if that
        // URL is remote, which no amount of URLSession auditing would reveal.
        "Data(contentsOf:", "String(contentsOf:"
    ]

    /// Locate Sources/ relative to this test file, so the check follows the
    /// repository rather than a hardcoded path.
    private func sourcesDirectory() throws -> URL {
        // .../macos/LDACore/Tests/LDACoreTests/NetworkChokepointTests.swift
        let here = URL(fileURLWithPath: #filePath)
        let root = here
            .deletingLastPathComponent()   // LDACoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // LDACore
        let sources = root.appendingPathComponent("Sources")
        // Deliberately NOT XCTSkip. The packaging script stages sources into a
        // temp dir and deletes it, which is exactly the environment where a skip
        // would silently disable the one check protecting the network claim.
        guard FileManager.default.fileExists(atPath: sources.path) else {
            XCTFail("Sources not found at \(sources.path); this check must not be skipped")
            throw CocoaError(.fileNoSuchFile)
        }
        return sources
    }

    func testOnlyOneFileInTheAppMayTouchTheNetwork() throws {
        let sources = try sourcesDirectory()
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            return XCTFail("could not walk \(sources.path)")
        }

        var offenders: [String: [String]] = [:]
        var tutorialLinkCount = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let name = url.lastPathComponent
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Comments discuss the invariant on purpose; only code counts.
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                for symbol in networkSymbols where line.contains(symbol) {
                    if name == allowedFile { continue }
                    if name == "TutorialGallery.swift", symbol == "Link(", trimmed == tutorialBrowserLink {
                        tutorialLinkCount += 1
                        continue
                    }
                    if name == "LegalConsentView.swift", symbol == "Link(", trimmed == supportEmailLink {
                        continue
                    }
                    if auditedLocalOnlyAPIs[symbol]?.contains(name) == true { continue }
                    offenders[name, default: []].append(symbol)
                }
            }
        }

        XCTAssertEqual(tutorialLinkCount, 1, "The fixed tutorial browser link must be reviewed if changed or removed.")
        XCTAssertTrue(
            offenders.isEmpty,
            """
            Network capability appeared outside \(allowedFile): \(offenders).
            The app publishes that it contacts the network only to download a \
            model you asked for. The fixed, user-selected tutorial and support \
            links are separately audited. Any other network use changes that claim. \
            If this is intentional, the published wording in LDA.entitlements, \
            packaging/README.md, SettingsView and OnboardingView must change \
            with it.
            """
        )
    }

    func testAuditedLocalFileReadsStillExist() throws {
        // If an audited file stops using the API, drop it from the list rather
        // than leaving a permanent exemption nobody re-reads.
        let sources = try sourcesDirectory()
        let fm = FileManager.default
        var seen: [String: Set<String>] = [:]
        if let walker = fm.enumerator(at: sources, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for (symbol, files) in auditedLocalOnlyAPIs
                where files.contains(url.lastPathComponent) && text.contains(symbol) {
                    seen[symbol, default: []].insert(url.lastPathComponent)
                }
            }
        }
        for (symbol, files) in auditedLocalOnlyAPIs {
            let live = seen[symbol] ?? []
            let stale = files.subtracting(live).subtracting(["NetworkChokepointTests.swift"])
            XCTAssertTrue(stale.isEmpty,
                          "stale exemption for \(symbol): \(stale). Remove it.")
        }
    }

    func testTheDesignatedNetworkFileStillExists() throws {
        // Guards against the check passing vacuously because the file was
        // renamed and every hit therefore disappeared.
        let sources = try sourcesDirectory()
        let path = sources.appendingPathComponent("LDAUI/\(allowedFile)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path),
                      "\(allowedFile) is missing; update this test deliberately")
        let text = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(text.contains("URLSession"),
                      "the designated network file no longer uses the network, "
                      + "so this test would pass vacuously")
    }

    func testTheServerEntitlementIsStillAbsent() throws {
        // Outbound was a deliberate decision. Inbound never was.
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let entitlements = root.appendingPathComponent("packaging/LDA.entitlements")
        guard let text = try? String(contentsOf: entitlements, encoding: .utf8) else {
            throw XCTSkip("entitlements not present in this environment")
        }
        XCTAssertFalse(
            text.contains("<key>com.apple.security.network.server</key>"),
            "nothing should be able to connect INTO this app"
        )
        XCTAssertTrue(
            text.contains("<key>com.apple.security.network.client</key>"),
            "model downloads need the outbound entitlement"
        )
    }
}
