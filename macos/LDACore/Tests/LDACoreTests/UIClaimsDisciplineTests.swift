//
//  UIClaimsDisciplineTests.swift
//  LDACoreTests
//
//  Guards user-visible UI copy against absolute privacy claims that the
//  model download path, support workflows, or future app behavior can make
//  inaccurate. Claims about a specific protected object may still be used.
//
//  House rules: English only. No em-dash and no en-dash-as-separator.
//

import Foundation
import XCTest

final class UIClaimsDisciplineTests: XCTestCase {

    private let forbiddenClaims = [
        "100%",
        "zero upload",
        "documents never leave this mac",
        "never leaves the machine",
        "guaranteed",
        "all sensitive information",
        "everything stays on this mac",
        "everything in it stays on this mac",
        "everything runs on this mac",
        "nothing leaves this mac",
        "mappings never leave this mac",
        "nothing about a document is ever sent anywhere",
        "lda uses the network for one thing only",
        "the only time lda uses the network",
        "lda reaches the network for exactly one thing",
        "lda uses the network only to",
        "it connects only to huggingface.co",
        "only while a download you started is running",
        "it sends nothing but the request for that file",
        "it will run fully on this mac"
    ]

    private func uiSourcesDirectory() throws -> URL {
        let here = URL(fileURLWithPath: #filePath)
        let root = here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/LDAUI", isDirectory: true)
        guard FileManager.default.fileExists(atPath: sources.path) else {
            XCTFail("LDAUI sources not found at \(sources.path); this check must not be skipped")
            throw CocoaError(.fileNoSuchFile)
        }
        return sources
    }

    func testUserVisibleUICopyAvoidsAbsoluteLocalOnlyClaims() throws {
        let sources = try uiSourcesDirectory()
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            return XCTFail("could not walk \(sources.path)")
        }

        var scannedFiles = Set<String>()
        var offenders: [String: Set<String>] = [:]
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let name = url.lastPathComponent
            scannedFiles.insert(name)

            for literalGroup in joinedStringLiteralGroups(in: text) {
                let normalized = normalizeClaim(literalGroup)
                for claim in forbiddenClaims where normalized.contains(claim) {
                    offenders[name, default: []].insert(claim)
                }
            }
        }

        XCTAssertTrue(
            scannedFiles.contains("WorkspaceSheets.swift"),
            "WorkspaceSheets.swift must remain inside the UI claims audit"
        )
        for required in ["OnboardingView.swift", "SettingsView.swift", "ModelManagementView.swift"] {
            XCTAssertTrue(
                scannedFiles.contains(required),
                "\(required) must remain inside the UI claims audit"
            )
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "Absolute privacy claims appeared in user-visible UI copy: \(offenders)"
        )
    }

    func testClaimsScannerJoinsSplitSwiftStringLiterals() throws {
        let source = #"Text("Everything stays on " + "this Mac.")"#
        let groups = joinedStringLiteralGroups(in: source).map(normalizeClaim)

        XCTAssertTrue(
            groups.contains(where: { $0.contains("everything stays on this mac") }),
            "splitting a claim across adjacent Swift literals must not bypass the audit"
        )
    }

    /// Extract ordinary Swift string literals and join only literals separated
    /// by whitespace and `+`. That covers the formatting style used by the UI
    /// without merging unrelated labels from different expressions.
    private func joinedStringLiteralGroups(in source: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #""(?:\\.|[^"\\])*""#) else {
            return []
        }
        let sourceNSString = source as NSString
        let matches = regex.matches(
            in: source,
            range: NSRange(location: 0, length: sourceNSString.length)
        )

        var groups: [String] = []
        var current = ""
        var previousEnd: Int?
        for match in matches {
            if let previousEnd {
                let separatorRange = NSRange(
                    location: previousEnd,
                    length: match.range.location - previousEnd
                )
                let separator = sourceNSString.substring(with: separatorRange)
                let isAdjacent = separator.allSatisfy {
                    $0.isWhitespace || $0 == "+"
                }
                if !isAdjacent, !current.isEmpty {
                    groups.append(current)
                    current = ""
                }
            }

            let quoted = sourceNSString.substring(with: match.range)
            let content = String(quoted.dropFirst().dropLast())
                .replacingOccurrences(of: #"\""#, with: "\"")
                .replacingOccurrences(of: #"\n"#, with: " ")
            current += content
            previousEnd = match.range.location + match.range.length
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    private func normalizeClaim(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
