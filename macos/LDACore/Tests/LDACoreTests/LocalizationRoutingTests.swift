//
//  LocalizationRoutingTests.swift
//  LDACoreTests
//
//  Enforces the localization idiom added by AppLanguageEnvironment.swift.
//  Text("x"), Button("x"), Label("x", systemImage:), .help("x"), a literal
//  passed to a LocalizedStringKey-typed parameter, and Text(LocalizedStringKey(s))
//  all resolve against Bundle.main and the system locale, missing
//  LDACore_LDAUI.bundle's in-app language override entirely. L10n.text,
//  L10n.button and .l10nHelp are the only sanctioned way to render copy in
//  Sources/LDAUI and Sources/LDAApp.
//
//  This is a per-file RATCHET, not a global ban. Hundreds of literal sites
//  and dozens of LocalizedStringKey occurrences exist across this package
//  today, so a global empty-match assertion could never be committed and
//  would enforce nothing. A handful of files are cleaned to a pinned budget
//  of zero; the rest keep their measured count as a ceiling that can only go
//  down. A file that reaches zero must be REMOVED from the table, which is
//  what stops a stale nonzero budget from surviving a cleanup and is checked
//  by testTheBudgetTableNeverOutlivesItsOwnViolations below.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import XCTest
@testable import LDAUI

final class LocalizationRoutingTests: XCTestCase {

    // MARK: - The checked-in budget

    /// Regular-literal violations (Text("x"), .help("x"), and the rest of
    /// LocalizationScanner.family1Names / family2Names) still allowed per
    /// file, measured against this branch. Pinned at 0 for every file this
    /// wizard-language change touches directly.
    private static let literalBudget: [String: Int] = [
        "MatterWorkspaceView.swift": 58,
        "FillShell.swift": 37,
        "FillLibraryViews.swift": 35,
        "EntitySidebar.swift": 31,
        "FillShellSheets.swift": 22,
        "FillReviewViews.swift": 18,
        "DocumentPane.swift": 14,
        "SessionViews.swift": 14,
        "WorkspaceSheets.swift": 11,
        "ClientMatterFlow.swift": 10,
        "ExportFlow.swift": 10,
        "FillShellViews.swift": 9,
        "ComplianceReportSheets.swift": 8,
        "AppShellToolbar.swift": 7,
        "HandoffCompletionCard.swift": 6,
        "WorkspaceFlow.swift": 4,
        "RootShell.swift": 2,
        "ModelSetupFlow.swift": 2,
        "DeanonymizeShell.swift": 2,
        "AppShell.swift": 1,
        "AppShellWorkflowHeader.swift": 1
    ]

    /// `LocalizedStringKey` token occurrences still allowed per file, same
    /// shape and same pinned-zero files as `literalBudget`.
    private static let localizedStringKeyBudget: [String: Int] = [
        "MatterWorkspaceView.swift": 13,
        "ComplianceReportSheets.swift": 9,
        "DeanonymizeShell.swift": 4,
        "EntitySidebar.swift": 3,
        "FillLibraryViews.swift": 3,
        "AppearanceMode.swift": 2,
        "DocumentPane.swift": 2,
        "EntityTypePresentation.swift": 2,
        "GuidedWorkflowPresentation.swift": 2,
        "RootShell.swift": 2,
        "FillReviewViews.swift": 1,
        "FillShell.swift": 1,
        "FillShellViews.swift": 1,
        "WorkspaceFlow.swift": 1,
        "WorkspaceSheets.swift": 1
    ]

    // MARK: - Test A: no literal reaches a localizing position

    func testNoLiteralReachesALocalizingPosition() throws {
        let roots = [Self.uiSourcesDirectory, Self.appSourcesDirectory]
        var literalViolations: [String: Int] = [:]
        var localizedStringKeyViolations: [String: Int] = [:]
        var exemptionCount = 0

        for root in roots {
            for (file, text) in try Self.swiftFiles(in: root) {
                let scan = LocalizationScanner.scan(text)
                if scan.literalCount > 0 { literalViolations[file, default: 0] += scan.literalCount }
                if scan.localizedStringKeyCount > 0 {
                    localizedStringKeyViolations[file, default: 0] += scan.localizedStringKeyCount
                }
                exemptionCount += scan.exemptionCount
            }
        }

        XCTAssertEqual(
            exemptionCount, 0,
            "no site is exempted from this scan today; a new // l10n-exempt: "
                + "marker must be reviewed, not merely tolerated by this pin"
        )

        for (file, count) in literalViolations {
            let budget = Self.literalBudget[file] ?? 0
            XCTAssertLessThanOrEqual(
                count, budget,
                "\(file): \(count) literal violations exceed the checked-in "
                    + "budget of \(budget). Route the new site through L10n.text "
                    + "/ L10n.button / .l10nHelp, or decrement the budget if this "
                    + "is a genuine cleanup."
            )
        }
        XCTAssertEqual(
            Set(Self.literalBudget.keys), Set(literalViolations.keys),
            "a file that reached zero literal violations must be REMOVED from "
                + "literalBudget, and a file with violations must be present in it"
        )

        for (file, count) in localizedStringKeyViolations {
            let budget = Self.localizedStringKeyBudget[file] ?? 0
            XCTAssertLessThanOrEqual(
                count, budget,
                "\(file): \(count) LocalizedStringKey occurrences exceed the "
                    + "checked-in budget of \(budget)."
            )
        }
        XCTAssertEqual(
            Set(Self.localizedStringKeyBudget.keys), Set(localizedStringKeyViolations.keys),
            "a file that reached zero LocalizedStringKey occurrences must be "
                + "REMOVED from localizedStringKeyBudget"
        )
    }

    func testTextVerbatimDoesNotComposeCopy() throws {
        // Text(verbatim: "...\(x)...") is the interpolated sub-class: its
        // synthesized "%lld"-shaped key has no catalog entry at all, so it
        // renders literally instead of translating.
        let roots = [Self.uiSourcesDirectory, Self.appSourcesDirectory]
        var offenders: [String] = []
        for root in roots {
            for (file, text) in try Self.swiftFiles(in: root) {
                let composed = LocalizationScanner.composedVerbatimSites(text)
                if !composed.isEmpty { offenders.append(file) }
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "Text(verbatim:) composes copy with string interpolation in: "
                + "\(offenders.sorted()). Route the sentence through a pure "
                + "presentation function with a %lld/%@ catalog key instead."
        )
    }

    // MARK: - Test B: every L10n key resolves in all four catalogs

    func testEveryKeyHandedToL10nExistsInAllFourCatalogs() throws {
        let roots = [Self.uiSourcesDirectory, Self.appSourcesDirectory]
        var keys = Set<String>()
        for root in roots {
            for (_, text) in try Self.swiftFiles(in: root) {
                keys.formUnion(LocalizationScanner.l10nCallKeys(text))
            }
        }
        XCTAssertFalse(keys.isEmpty, "the scan found no L10n call at all; check the path")

        // Membership in the parsed .strings dictionary, not
        // "L10n.string(...) differs from the key": plenty of legitimate
        // entries (OK, LLM, a bare middle-dot separator) correctly translate
        // to the SAME text as the English key, and comparing resolved values
        // cannot tell that apart from a key that is simply absent and falling
        // back to its own name. Reading the catalog directly can.
        let identifiers = ["en", "fr", "zh-Hans", "zh-Hant"]
        var catalogs: [String: [String: String]] = [:]
        for identifier in identifiers {
            catalogs[identifier] = try Self.catalog(identifier: identifier)
        }

        for identifier in identifiers {
            let catalog = try XCTUnwrap(catalogs[identifier])
            for key in keys.sorted() {
                let value = catalog[key]
                XCTAssertNotNil(
                    value,
                    "\(identifier) has no catalog entry at all for key: \(key)"
                )
                XCTAssertFalse(
                    (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "\(identifier) has an empty catalog entry for key: \(key)"
                )
            }
        }
    }

    private static func catalog(identifier: String) throws -> [String: String] {
        let url = uiSourcesDirectory
            .appendingPathComponent("Resources")
            .appendingPathComponent("\(identifier).lproj/Localizable.strings")
        return try XCTUnwrap(
            NSDictionary(contentsOf: url) as? [String: String],
            "could not parse \(identifier)"
        )
    }

    // MARK: - Test C: setup copy reads as the target language, not English
    //
    // Deviation from the spec text: it describes one "no Latin letter"
    // assertion applying to Chinese AND French alike. French is written in
    // Latin script, so that rule cannot hold for French sentences (the
    // failing run that found this: genuine, already-shipped French sentences
    // like "Exporter une copie..." tripped a literal "no Latin letter"
    // check). The two symptoms are different and need different checks:
    // Chinese copy silently reading as English (an untranslated sentence
    // leaking through) versus French copy silently reading as English (a
    // missing translation falling back to the English value). So Chinese
    // gets the "no Latin letter outside the allow-set, and at least one CJK
    // codepoint" rule from the spec verbatim; French gets "differs from the
    // English value", which is the check that actually catches a missing
    // French translation.

    func testEveryChineseAndFrenchSetupStringIsActuallyTranslated() {
        // The allow-set is deliberately small: brand names, units, and the
        // handful of Latin tokens (huggingface.co, .gguf, .zip, the WeChat ID
        // abbreviation) that legally appear inside otherwise-Chinese prose.
        let allowed = [
            "GB", "MB", "Mac", "LDA", "AI", "PDF", "Word", "ChatGPT", "Claude",
            "Markdown", "huggingface.co", "zip", "gguf", "Cmd", "ID", "WeChat"
        ]

        func stripAllowed(_ value: String) -> String {
            var stripped = value
            for token in allowed.sorted(by: { $0.count > $1.count }) {
                stripped = stripped.replacingOccurrences(of: token, with: "")
            }
            return stripped
        }

        func containsLatinLetter(_ value: String) -> Bool {
            stripAllowed(value).unicodeScalars.contains {
                CharacterSet.letters.contains($0) && $0.isASCII
            }
        }

        func containsCJK(_ value: String) -> Bool {
            value.unicodeScalars.contains { scalar in
                (0x4E00...0x9FFF).contains(scalar.value)
            }
        }

        let values = Self.setupPresentationStrings()
        XCTAssertFalse(values.isEmpty, "the setup copy fixture is empty; check ModelSetupPresentation/OnboardingPresentation")

        for (label, resolve) in values {
            let english = resolve(.english)
            for language in [AppLanguage.simplifiedChinese, .traditionalChinese] {
                let value = resolve(language)
                XCTAssertFalse(
                    containsLatinLetter(value),
                    "\(language.rawValue) \(label) still reads like English: \(value)"
                )
                XCTAssertTrue(
                    containsCJK(value),
                    "\(language.rawValue) \(label) has no Chinese at all: \(value)"
                )
            }
            let french = resolve(.french)
            XCTAssertNotEqual(
                french, english,
                "fr \(label) is missing a translation and fell back to English: \(french)"
            )
        }
    }

    /// Every ModelSetupPresentation / OnboardingPresentation string surfaced
    /// on the wizard's model step or language step, paired with a label for
    /// failure messages.
    private static func setupPresentationStrings() -> [(String, (AppLanguage) -> String)] {
        var out: [(String, (AppLanguage) -> String)] = []
        for route in [
            ModelSetupPresentation.AskRoute.download,
            .importOnly,
            .unavailable
        ] {
            out.append(("askTitleKey(\(route))", { language in
                L10n.string(ModelSetupPresentation.askTitleKey(route: route), language: language)
            }))
            out.append(("askBody(\(route))", { language in
                ModelSetupPresentation.askBody(route: route, language: language).joined(separator: " ")
            }))
        }
        out.append(("scanConfirmation", { language in
            let c = ModelSetupPresentation.scanConfirmation(language: language)
            return [c.title, c.message, c.proceed].joined(separator: " ")
        }))
        for reason in [ModelSetupPresentation.ExportGateReason.didNotRun, .ranPartially] {
            out.append(("exportConfirmation(\(reason))", { language in
                let c = ModelSetupPresentation.exportConfirmation(reason: reason, language: language)
                return [c.title, c.message, c.proceed].joined(separator: " ")
            }))
        }
        return out
    }

    // MARK: - File access

    private static let uiSourcesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/LDAUI", isDirectory: true)

    private static let appSourcesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/LDAApp", isDirectory: true)

    private static func swiftFiles(in directory: URL) throws -> [(name: String, text: String)] {
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil
        ) else {
            XCTFail("could not walk \(directory.path)")
            return []
        }
        var out: [(String, String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            out.append((url.lastPathComponent, text))
        }
        return out
    }
}

// MARK: - LocalizationScanner

/// The scanner behind `LocalizationRoutingTests`, kept separate so its three
/// syntactic mechanisms are easy to audit on their own:
///
/// 1. The quote must be the first non-space character after the open paren,
///    so a pre-resolved String (`Text(verbatim: s)`, `Button(title)`,
///    `Text(L10n.string("x"))`, `L10n.text("x")`) never matches.
/// 2. A literal immediately inside an `L10n.` call is excluded even if it
///    would otherwise match, so a future `L10n.Text(...)` overload could not
///    silently become invisible to this scan by construction alone.
/// 3. `LocalizedStringKey` is banned as a bare TOKEN, not just as a call, so
///    `title: LocalizedStringKey`, `Text(LocalizedStringKey(x))`, and
///    `var x: LocalizedStringKey` are all caught in one assertion.
enum LocalizationScanner {

    struct ScanResult {
        var literalCount = 0
        var localizedStringKeyCount = 0
        var exemptionCount = 0
    }

    private static let family1Names =
        "Text|Button|Label|Picker|Toggle|TextField|SecureField|Link|Stepper|Section"
    private static let family2Names =
        "help|alert|confirmationDialog|navigationTitle|navigationSubtitle|"
            + "accessibilityLabel|accessibilityHint|accessibilityValue|badge|toolTip"

    private static let family1Regex = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_.])(?:\#(family1Names))\s*\(\s*""#
    )
    private static let family2Regex = try! NSRegularExpression(
        pattern: #"\.(?:\#(family2Names))\s*\(\s*""#
    )
    private static let localizedStringKeyRegex = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])LocalizedStringKey(?![A-Za-z0-9_])"#
    )
    private static let composedVerbatimRegex = try! NSRegularExpression(
        pattern: #"Text\(verbatim:\s*"(?:[^"\\]|\\.)*\\\((?:[^"\\]|\\.)*"\)"#
    )
    private static let l10nCallRegex = try! NSRegularExpression(
        pattern: #"L10n\.(?:string|text|button)\(\s*"((?:[^"\\]|\\.)*)"|\.l10nHelp\(\s*"((?:[^"\\]|\\.)*)""#
    )
    private static let exemptMarkerRegex = try! NSRegularExpression(pattern: #"//\s*l10n-exempt:"#)

    static func scan(_ text: String) -> ScanResult {
        var result = ScanResult()
        let stripped = strippedForScanning(text)
        let ns = stripped as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let lineStarts = Self.lineStartOffsets(of: text)

        func isExemptOrL10n(at location: Int) -> Bool {
            let prefixStart = max(0, location - 5)
            let prefix = ns.substring(with: NSRange(location: prefixStart, length: location - prefixStart))
            if prefix == "L10n." { return true }
            let line = Self.lineNumber(offset: location, lineStarts: lineStarts)
            if Self.lineIsExempt(text, line: line) {
                result.exemptionCount += 1
                return true
            }
            return false
        }

        for regex in [family1Regex, family2Regex] {
            for match in regex.matches(in: stripped, range: fullRange) {
                guard !isExemptOrL10n(at: match.range.location) else { continue }
                result.literalCount += 1
            }
        }
        for match in localizedStringKeyRegex.matches(in: stripped, range: fullRange) {
            guard !isExemptOrL10n(at: match.range.location) else { continue }
            result.localizedStringKeyCount += 1
        }
        return result
    }

    static func composedVerbatimSites(_ text: String) -> [String] {
        let stripped = strippedForScanning(text)
        let ns = stripped as NSString
        let range = NSRange(location: 0, length: ns.length)
        return composedVerbatimRegex.matches(in: stripped, range: range).map {
            ns.substring(with: $0.range)
        }
    }

    /// Every string literal passed as the first argument to `L10n.string`,
    /// `L10n.text`, `L10n.button` or `.l10nHelp`, unescaped.
    static func l10nCallKeys(_ text: String) -> Set<String> {
        let stripped = strippedForScanning(text)
        let ns = stripped as NSString
        let range = NSRange(location: 0, length: ns.length)
        var keys = Set<String>()
        for match in l10nCallRegex.matches(in: stripped, range: range) {
            for groupIndex in [1, 2] {
                let groupRange = match.range(at: groupIndex)
                guard groupRange.location != NSNotFound else { continue }
                let raw = ns.substring(with: groupRange)
                keys.insert(unescape(raw))
            }
        }
        return keys
    }

    /// Undoes Swift string-literal escaping well enough for a catalog key:
    /// `\"`, `\n`, `\\`, and `\u{XXXX}`, which several existing keys use for
    /// a middle dot separator (U+00B7) rather than typing the glyph.
    private static func unescape(_ raw: String) -> String {
        var out = ""
        let chars = Array(raw)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count {
                switch chars[i + 1] {
                case "\"": out.append("\""); i += 2
                case "n": out.append("\n"); i += 2
                case "\\": out.append("\\"); i += 2
                case "u" where i + 2 < chars.count && chars[i + 2] == "{":
                    var j = i + 3
                    var hex = ""
                    while j < chars.count, chars[j] != "}" {
                        hex.append(chars[j])
                        j += 1
                    }
                    if let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) {
                        out.append(Character(scalar))
                    }
                    i = j + 1
                default:
                    out.append(chars[i])
                    i += 1
                }
                continue
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    /// Blanks out `//` and `/* */` comment text with spaces (preserving
    /// length and newlines, so byte offsets and reported lines still match
    /// the source) while tracking string-literal state, so a `//` or `/*`
    /// inside a string literal is not mistaken for the start of a comment.
    private static func strippedForScanning(_ text: String) -> String {
        var units = Array(text.utf16)
        let quote: UInt16 = 34
        let backslash: UInt16 = 92
        let slash: UInt16 = 47
        let star: UInt16 = 42
        let newline: UInt16 = 10
        let space: UInt16 = 32

        var i = 0
        var inString = false
        var inBlockComment = false
        while i < units.count {
            if inBlockComment {
                if i + 1 < units.count, units[i] == star, units[i + 1] == slash {
                    units[i] = space
                    units[i + 1] = space
                    i += 2
                    inBlockComment = false
                } else {
                    if units[i] != newline { units[i] = space }
                    i += 1
                }
                continue
            }
            if inString {
                if units[i] == backslash, i + 1 < units.count {
                    i += 2
                    continue
                }
                if units[i] == quote { inString = false }
                i += 1
                continue
            }
            if i + 1 < units.count, units[i] == slash, units[i + 1] == slash {
                var j = i
                while j < units.count, units[j] != newline {
                    units[j] = space
                    j += 1
                }
                i = j
                continue
            }
            if i + 1 < units.count, units[i] == slash, units[i + 1] == star {
                units[i] = space
                units[i + 1] = space
                i += 2
                inBlockComment = true
                continue
            }
            if units[i] == quote {
                inString = true
                i += 1
                continue
            }
            i += 1
        }
        return String(utf16CodeUnits: units, count: units.count)
    }

    private static func lineStartOffsets(of text: String) -> [Int] {
        var starts = [0]
        var offset = 0
        for scalar in text.utf16 {
            offset += 1
            if scalar == 10 { starts.append(offset) }
        }
        return starts
    }

    /// 1-indexed line number containing UTF-16 `offset`.
    private static func lineNumber(offset: Int, lineStarts: [Int]) -> Int {
        var lo = 0
        var hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo + 1
    }

    /// True when line `line` or the line immediately before it carries a
    /// `// l10n-exempt:` marker, checked against the ORIGINAL text (not the
    /// comment-stripped copy, since the marker IS a comment).
    private static func lineIsExempt(_ text: String, line: Int) -> Bool {
        let lines = text.components(separatedBy: "\n")
        for candidate in [line, line - 1] {
            guard candidate >= 1, candidate <= lines.count else { continue }
            let lineText = lines[candidate - 1]
            let range = NSRange(location: 0, length: (lineText as NSString).length)
            if exemptMarkerRegex.firstMatch(in: lineText, range: range) != nil { return true }
        }
        return false
    }
}
