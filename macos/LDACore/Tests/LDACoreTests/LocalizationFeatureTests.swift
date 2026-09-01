import Foundation
import XCTest
@testable import LDAUI
import LDACore

final class LocalizationFeatureTests: XCTestCase {
    func testLanguageSelectionRoundTripsAndUnknownValuesFallBackSafely() {
        let (defaults, name) = TestNamespace.defaults("interface-language")
        defer { defaults.removePersistentDomain(forName: name) }

        XCTAssertEqual(AppLanguage.selected(defaults: defaults), .system)

        for language in AppLanguage.allCases {
            AppLanguage.select(language, defaults: defaults)
            XCTAssertEqual(AppLanguage.selected(defaults: defaults), language)
        }

        defaults.set("unsupported-language", forKey: AppLanguage.storageKey)
        XCTAssertEqual(AppLanguage.selected(defaults: defaults), .system)
    }

    func testExplicitLanguagesUseStableLocaleIdentifiers() {
        XCTAssertEqual(AppLanguage.english.locale.identifier, "en")
        XCTAssertEqual(AppLanguage.french.locale.identifier, "fr")
        XCTAssertEqual(AppLanguage.simplifiedChinese.locale.identifier, "zh-Hans")
        XCTAssertEqual(AppLanguage.traditionalChinese.locale.identifier, "zh-Hant")
    }

    func testRepresentativeWorkflowLabelsResolveInEveryLanguage() {
        let expected: [(AppLanguage, [String])] = [
            (.english, ["Matters", "Anonymize", "Restore", "Fill"]),
            (.french, ["Dossiers", "Anonymiser", "Restaurer", "Remplir"]),
            (.simplifiedChinese, ["事项", "匿名化", "恢复", "填写"]),
            (.traditionalChinese, ["案件", "匿名化", "還原", "填寫"])
        ]

        for (language, labels) in expected {
            XCTAssertEqual(L10n.string("Matters", language: language), labels[0])
            XCTAssertEqual(L10n.string("Anonymize", language: language), labels[1])
            XCTAssertEqual(L10n.string("Restore", language: language), labels[2])
            XCTAssertEqual(L10n.string("Fill", language: language), labels[3])
        }
    }

    func testPersistedLanguageChangesResolvedCopyWithoutRelaunch() {
        let (defaults, name) = TestNamespace.defaults("runtime-localization")
        defer { defaults.removePersistentDomain(forName: name) }

        AppLanguage.select(.english, defaults: defaults)
        XCTAssertEqual(L10n.string("Restore", defaults: defaults), "Restore")

        AppLanguage.select(.french, defaults: defaults)
        XCTAssertEqual(L10n.string("Restore", defaults: defaults), "Restaurer")

        AppLanguage.select(.simplifiedChinese, defaults: defaults)
        XCTAssertEqual(L10n.string("Restore", defaults: defaults), "恢复")

        AppLanguage.select(.traditionalChinese, defaults: defaults)
        XCTAssertEqual(L10n.string("Restore", defaults: defaults), "還原")
    }

    func testSystemPreferenceChoosesTheClosestSupportedLocalization() {
        XCTAssertEqual(
            L10n.string("Restore", language: .system, preferredLanguages: ["fr-CA"]),
            "Restaurer"
        )
        XCTAssertEqual(
            L10n.string("Restore", language: .system, preferredLanguages: ["zh-TW"]),
            "還原"
        )
        XCTAssertEqual(
            L10n.string("Restore", language: .system, preferredLanguages: ["zh-Hans-TW"]),
            "恢复",
            "An explicit Chinese script must take priority over the region."
        )
        XCTAssertEqual(
            L10n.string("Restore", language: .system, preferredLanguages: ["ja-JP"]),
            "Restore"
        )
    }

    func testLanguagePreferenceOffersATestablePersistenceSeam() throws {
        let source = try String(
            contentsOf: Self.packageRoot.appendingPathComponent("Sources/LDAUI/AppLanguage.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("selected(defaults:"))
        XCTAssertTrue(source.contains("select("))
    }

    func testLocalizationResolverUsesTheLDAUIResourceBundle() throws {
        let url = Self.packageRoot.appendingPathComponent("Sources/LDAUI/Localization.swift")
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("Localization.swift is missing")
            return
        }

        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("enum L10n"))
        XCTAssertTrue(source.contains("LDAResourceBundle"))
        XCTAssertFalse(source.contains("Bundle.module"))
    }

    func testLocalizationInfrastructureAndSupportedCatalogsExist() throws {
        let uiSources = Self.packageRoot.appendingPathComponent("Sources/LDAUI")
        let resources = uiSources.appendingPathComponent("Resources")

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: uiSources.appendingPathComponent("AppLanguage.swift").path
            ),
            "A shared persisted language preference must live in LDAUI."
        )

        for identifier in ["en", "fr", "zh-Hans", "zh-Hant"] {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: resources
                        .appendingPathComponent("\(identifier).lproj/Localizable.strings")
                        .path
                ),
                "Missing translated catalog for \(identifier)."
            )
        }
    }

    func testCatalogsCoverTheMainInterfaceAndPreserveFormatSpecifiers() throws {
        let resources = Self.packageRoot
            .appendingPathComponent("Sources/LDAUI/Resources")
        let identifiers = ["en", "fr", "zh-Hans", "zh-Hant"]
        var catalogs: [String: [String: String]] = [:]

        for identifier in identifiers {
            catalogs[identifier] = try Self.catalog(
                at: resources.appendingPathComponent(
                    "\(identifier).lproj/Localizable.strings"
                )
            )
        }

        let english = try XCTUnwrap(catalogs["en"])
        XCTAssertGreaterThanOrEqual(
            english.count,
            340,
            "The localization catalog must cover the full visible interface."
        )
        for key in [
            "Choose the language LDA uses for its interface. Follow System uses your Mac language.",
            "System", "Light", "Dark",
            "Placeholders", "Pseudonyms", "Asterisks",
            "Bring documents in", "Hand the safe copy to any AI", "Bring the answer back"
        ] {
            XCTAssertNotNil(
                english[key],
                "Dynamic presentation copy must have an explicit catalog entry: \(key)"
            )
        }

        for identifier in identifiers {
            let translated = try XCTUnwrap(catalogs[identifier])
            XCTAssertEqual(
                Set(translated.keys),
                Set(english.keys),
                "\(identifier) must translate the same keys as English."
            )

            for (key, value) in translated {
                XCTAssertFalse(
                    value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "\(identifier) has an empty translation for \(key)."
                )
                XCTAssertFalse(
                    value.contains("\u{2014}") || value.contains("\u{2013}"),
                    "\(identifier) uses a prohibited dash character in \(key)."
                )
                XCTAssertEqual(
                    Self.formatSpecifiers(in: value),
                    Self.formatSpecifiers(in: key),
                    "\(identifier) changed a format placeholder in \(key)."
                )
                XCTAssertEqual(
                    Self.formatArgumentTypes(in: value),
                    Self.formatArgumentTypes(in: key),
                    "\(identifier) changed the argument order in \(key). "
                        + "Use positional specifiers before reordering formatted values."
                )
            }
        }
    }

    func testHighVisibilityDynamicControlsReachALocalizationBoundary() throws {
        let sources = Self.packageRoot.appendingPathComponent("Sources/LDAUI")
        let appShell = try String(
            contentsOf: sources.appendingPathComponent("AppShell.swift"),
            encoding: .utf8
        )
        let restore = try String(
            contentsOf: sources.appendingPathComponent("DeanonymizeShell.swift"),
            encoding: .utf8
        )
        let fillLibrary = try String(
            contentsOf: sources.appendingPathComponent("FillLibraryViews.swift"),
            encoding: .utf8
        )
        let fillShell = try String(
            contentsOf: sources.appendingPathComponent("FillShell.swift"),
            encoding: .utf8
        )
        let documentPane = try String(
            contentsOf: sources.appendingPathComponent("DocumentPane.swift"),
            encoding: .utf8
        )
        let fillSheets = try String(
            contentsOf: sources.appendingPathComponent("FillShellSheets.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(restore.contains("title: LocalizedStringKey"))
        XCTAssertTrue(appShell.contains("scanButton(title: LocalizedStringKey"))
        XCTAssertTrue(restore.contains("body: LocalizedStringKey"))
        XCTAssertTrue(restore.contains("buttonTitle: LocalizedStringKey"))
        XCTAssertTrue(restore.contains(".help(L10n.string(buttonHelp))"))
        XCTAssertTrue(fillLibrary.contains("Text(LocalizedStringKey(kindDisplayName(kind)))"))
        XCTAssertTrue(fillLibrary.contains("Text(LocalizedStringKey(kindDescription))"))
        XCTAssertTrue(fillShell.contains("LocalizedStringKey(profilePrimaryActionLabel)"))
        XCTAssertTrue(fillShell.contains(".help(L10n.string(profilePrimaryActionHelp))"))
        XCTAssertTrue(documentPane.contains("Text(mode.localizedKey).tag(mode)"))
        XCTAssertTrue(fillSheets.contains("title: L10n.string(\"Save failed\")"))
        XCTAssertTrue(fillSheets.contains("title: L10n.string(\"Load failed\")"))
    }

    func testPassphraseValidationAndInstallFailuresUseSelectedLanguage() {
        XCTAssertEqual(
            WorkspacePresentation.message(
                for: .tooShort(minimum: 8),
                language: .french
            ),
            "Utilisez au moins 8 caractères."
        )
        XCTAssertEqual(
            ComplianceReportPresentation.message(
                for: .empty,
                language: .simplifiedChinese
            ),
            "请输入此报告文件的密码。"
        )
        XCTAssertTrue(
            ModelInstallError.offlineMode
                .localizedMessage(language: .traditionalChinese)
                .contains("離線模式")
        )
    }

    func testSettingsHistoryAndSharingOutcomesUseWholeLocalizedPhrases() {
        XCTAssertEqual(
            SettingsHistoryPresentation.documentsLine(
                protectedValueCount: 1,
                documentSummaries: ["contrat.pdf (2)"],
                language: .french
            ),
            "1 identité protégée dans : contrat.pdf (2)"
        )
        XCTAssertEqual(
            SettingsHistoryPresentation.restoresLine(
                restoreCount: 0,
                restoredValueCount: 0,
                flaggedCount: 0,
                language: .traditionalChinese
            ),
            "尚未還原。"
        )
        XCTAssertTrue(
            SettingsSharingPresentation.imported(
                vocabularyCount: 2,
                learnedCount: 1,
                language: .simplifiedChinese
            ).contains("2")
        )
    }

    func testFillStatusCopyUsesWholePhrasePluralizationInEveryLanguage() {
        for language in [
            AppLanguage.english,
            .french,
            .simplifiedChinese,
            .traditionalChinese
        ] {
            let values = [
                FillStatusPresentation.reviewing(total: 1, confirmed: 1, language: language),
                FillStatusPresentation.reviewing(total: 2, confirmed: 1, language: language),
                FillStatusPresentation.completed(
                    filled: 1,
                    fileName: "Output.pdf",
                    skipped: 0,
                    language: language
                ),
                FillStatusPresentation.completed(
                    filled: 2,
                    fileName: "Output.pdf",
                    skipped: 3,
                    language: language
                )
            ]

            for value in values {
                XCTAssertFalse(value.contains("%"), "Unresolved format in: \(value)")
            }

            if language == .simplifiedChinese || language == .traditionalChinese {
                for value in values {
                    XCTAssertFalse(
                        value.range(of: #"\d+s\b"#, options: .regularExpression) != nil,
                        "English plural suffix leaked into Chinese: \(value)"
                    )
                }
            }
        }
    }

    func testEntityHeadingsLocalizeWithoutChangingStableWireValues() {
        XCTAssertEqual(EntityType.person.rawValue, "PERSON")
        XCTAssertEqual(EntityType.company.rawValue, "COMPANY")
        XCTAssertEqual(
            EntityTypePresentation.localizedName(for: .person, language: .french),
            "Personne"
        )
        XCTAssertEqual(
            EntityTypePresentation.localizedName(
                for: .bankAccount,
                language: .simplifiedChinese
            ),
            "银行账户"
        )
        XCTAssertEqual(
            EntityTypePresentation.localizedName(
                for: .nationalID,
                language: .traditionalChinese
            ),
            "身分證件號碼"
        )
    }

    func testProfileFieldLabelsLocalizeWithoutChangingStableWireKeys() {
        XCTAssertEqual(ProfileFieldKey.companyName.rawKey, "companyName")
        XCTAssertEqual(
            ProfileFieldPresentation.localizedName(
                for: .companyName,
                language: .french
            ),
            "Nom de la société"
        )
        XCTAssertEqual(
            ProfileFieldPresentation.localizedName(
                for: .passportNumber,
                language: .simplifiedChinese
            ),
            "护照号码"
        )
        XCTAssertEqual(
            ProfileFieldPresentation.localizedName(
                for: .registeredOffice,
                language: .traditionalChinese
            ),
            "註冊地址"
        )
        XCTAssertEqual(
            ProfileFieldPresentation.localizedName(
                for: .custom("受益人"),
                language: .french
            ),
            "受益人",
            "User-defined field names must remain verbatim."
        )
    }

    func testModelGuidanceUsesTheSelectedInterfaceLanguage() {
        XCTAssertNotEqual(
            ModelAnnotation.localizedBody(for: .quick, language: .french),
            ModelAnnotation.body(for: .quick)
        )
        XCTAssertTrue(
            ModelAnnotation.localizedBody(
                for: .balanced,
                language: .simplifiedChinese
            ).contains("35")
        )

        let tier = ModelTier(
            id: "test",
            level: DetectionLevel.quick.rawValue,
            displayName: "Test",
            fileName: "test.gguf",
            sizeBytes: 2_500_000_000,
            sha256: "",
            peakRSSGB: 8.5,
            secondsPerDocument: 75,
            architecture: "test",
            blockCount: 1,
            embeddingLength: 1,
            sourceURL: "https://example.invalid/test.gguf"
        )
        let facts = ModelAnnotation.localizedFacts(
            for: tier,
            bundled: true,
            language: .traditionalChinese
        )
        XCTAssertTrue(facts.contains("2.50 GB"))
        XCTAssertTrue(facts.contains("75"))
        XCTAssertFalse(facts.contains("a contract"))

        let requirement = MemoryGate.localizedRequirementText(
            for: tier,
            installedGB: 16,
            language: .simplifiedChinese
        )
        XCTAssertTrue(requirement.contains("16 GB"))
        XCTAssertFalse(requirement.contains("This Mac has"))
    }

    func testPrimaryAnonymizeStatusCopyUsesTheSelectedInterfaceLanguage() {
        let completion = AnonymizeWorkflowPresentation.copyCompletionDetail(
            documentCount: 2,
            skippedCount: 1,
            language: .french
        )
        XCTAssertTrue(completion.contains("documents caviardés"), completion)
        XCTAssertTrue(completion.contains("1 document non analysé"), completion)

        let detecting = AnonymizeWorkflowPresentation.detectingLabel(
            progress: 0.42,
            eta: "约剩余 12 秒",
            language: .simplifiedChinese
        )
        XCTAssertTrue(detecting.contains("42%"), detecting)
        XCTAssertTrue(detecting.contains("正在检测个人信息"), detecting)

        let help = AnonymizeWorkflowPresentation.copyForAIHelp(
            ready: 1,
            candidates: 3,
            language: .traditionalChinese
        )
        XCTAssertTrue(help.contains("1"), help)
        XCTAssertTrue(help.contains("3"), help)
        XCTAssertFalse(help.contains("Copy the redacted text"), help)
    }

    func testImageExportWarningsUseTheSelectedInterfaceLanguage() throws {
        let candidate = try XCTUnwrap(
            ImageExportPresentation.sealCandidateDetail(
                count: 2,
                language: .french
            )
        )
        XCTAssertTrue(candidate.contains("2 zones rouges"), candidate)

        let warning = try XCTUnwrap(
            ImageExportPresentation.unboxedWarning(
                count: 1,
                language: .simplifiedChinese
            )
        )
        XCTAssertTrue(warning.contains("1 个已隐去值"), warning)
        XCTAssertFalse(warning.contains("Warning:"), warning)
    }

    func testSettingsAndEveryAppSceneUseTheSharedLanguagePreference() throws {
        let app = try String(
            contentsOf: Self.packageRoot.appendingPathComponent("Sources/LDAApp/LDAApp.swift"),
            encoding: .utf8
        )
        let settings = try String(
            contentsOf: Self.packageRoot.appendingPathComponent("Sources/LDAUI/SettingsView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(settings.contains("AppLanguage.storageKey"))
        XCTAssertTrue(settings.contains("Picker(\"Language\""))
        XCTAssertTrue(app.contains("@AppStorage(AppLanguage.storageKey)"))
        XCTAssertGreaterThanOrEqual(
            app.components(separatedBy: ".environment(\\.locale, appLocale)").count - 1,
            3,
            "The main window, Settings, and menu-bar companion must all update immediately."
        )
    }

    func testDynamicPickersAndFirstRunExperienceObserveTheLanguagePreference() throws {
        let rootShell = try String(
            contentsOf: Self.packageRoot.appendingPathComponent("Sources/LDAUI/RootShell.swift"),
            encoding: .utf8
        )
        let settings = try String(
            contentsOf: Self.packageRoot.appendingPathComponent("Sources/LDAUI/SettingsView.swift"),
            encoding: .utf8
        )
        let onboarding = try String(
            contentsOf: Self.packageRoot.appendingPathComponent("Sources/LDAUI/OnboardingView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(rootShell.contains("Text(mode.localizedKey)"))
        XCTAssertFalse(rootShell.contains("Text(mode.rawValue)"))
        XCTAssertTrue(settings.contains("Text($0.localizedKey)"))
        XCTAssertTrue(settings.contains("Text(LocalizedStringKey(Self.label(for: style)))"))
        XCTAssertTrue(settings.contains("Text(LocalizedStringKey(Self.explanation(for:"))
        XCTAssertTrue(onboarding.contains("@AppStorage(AppLanguage.storageKey)"))
        XCTAssertTrue(onboarding.contains("Picker(\"Language\""))
        XCTAssertFalse(
            onboarding.contains("document.\\nRestore Clipboard"),
            "The two onboarding warnings must be separate localized Text values."
        )
    }

    func testNativePanelsDoNotBypassTheRuntimeLanguagePreference() throws {
        let sources = Self.packageRoot.appendingPathComponent("Sources")
        let directories = ["LDAUI", "LDAApp"].map {
            sources.appendingPathComponent($0, isDirectory: true)
        }
        let patterns = [
            #"\.(?:message|prompt|messageText|informativeText)\s*=\s*\""#,
            #"addButton\(withTitle:\s*\""#
        ]
        let expressions = try patterns.map { try NSRegularExpression(pattern: $0) }
        var violations: [String] = []

        for directory in directories {
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: nil
            ) else { continue }

            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let source = try String(contentsOf: url, encoding: .utf8)
                let range = NSRange(source.startIndex..., in: source)
                if expressions.contains(where: { $0.firstMatch(in: source, range: range) != nil }) {
                    violations.append(url.lastPathComponent)
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "Native panels must resolve copy through L10n: \(violations.sorted())"
        )
    }

    func testVisibleTextDoesNotUseStringConcatenationThatBypassesLocalization() throws {
        let directory = Self.packageRoot.appendingPathComponent("Sources/LDAUI")
        let expression = try NSRegularExpression(
            pattern: #"\bText\(\s*\"[^\"]*\"\s*\+"#
        )
        var violations: [String] = []

        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            XCTFail("Could not enumerate LDAUI sources.")
            return
        }

        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            if expression.firstMatch(in: source, range: range) != nil {
                violations.append(url.lastPathComponent)
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "Text(String) bypasses localization when its String is built with +: "
                + "\(violations.sorted())"
        )
    }

    func testPackageAndAppBundleDeclareSupportedLocalizations() throws {
        let package = try String(
            contentsOf: Self.packageRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(package.contains("defaultLocalization: \"en\""))

        let infoURL = Self.packageRoot.appendingPathComponent("packaging/Info.plist")
        let info = try XCTUnwrap(
            try PropertyListSerialization.propertyList(
                from: Data(contentsOf: infoURL),
                format: nil
            ) as? [String: Any]
        )
        XCTAssertEqual(info["CFBundleDevelopmentRegion"] as? String, "en")
        XCTAssertEqual(
            Set(info["CFBundleLocalizations"] as? [String] ?? []),
            Set(["en", "fr", "zh-Hans", "zh-Hant"])
        )
    }

    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func catalog(at url: URL) throws -> [String: String] {
        let dictionary = try XCTUnwrap(
            NSDictionary(contentsOf: url) as? [String: String],
            "Could not parse \(url.lastPathComponent)."
        )
        return dictionary
    }

    private static func formatSpecifiers(in value: String) -> [String] {
        let pattern = #"%(?:\d+\$)?(?:ll|l|h)?[@a-zA-Z]"#
        let expression = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            guard let range = Range(match.range, in: value) else { return nil }
            return String(value[range])
        }.sorted()
    }

    private static func formatArgumentTypes(in value: String) -> [String] {
        let pattern = #"%(?:\d+\$)?((?:ll|l|h)?[@a-zA-Z])"#
        let expression = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            guard let typeRange = Range(match.range(at: 1), in: value) else { return nil }
            return String(value[typeRange])
        }
    }
}
