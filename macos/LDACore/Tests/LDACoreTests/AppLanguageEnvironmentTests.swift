//
//  AppLanguageEnvironmentTests.swift
//  LDACoreTests
//
//  The localization idiom that replaces LocalizedStringKey: \.appLanguage in
//  the SwiftUI environment, and L10n.text / L10n.button / L10n.formatted
//  reading it. See LocalizationRoutingTests for the per-file enforcement that
//  makes the old idiom (Text("x"), LocalizedStringKey, ...) a build-time
//  failure once a file's budget reaches zero.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import SwiftUI
import XCTest
@testable import LDAUI

final class AppLanguageEnvironmentTests: XCTestCase {

    func testEnvironmentDefaultsToSystemAndRoundTrips() {
        var values = EnvironmentValues()
        XCTAssertEqual(values.appLanguage, .system)

        values.appLanguage = .simplifiedChinese
        XCTAssertEqual(values.appLanguage, .simplifiedChinese)
    }

    func testFormattedResolvesAgainstTheGivenLanguageRatherThanUserDefaults() {
        let (defaults, name) = TestNamespace.defaults("app-language-environment")
        defer { defaults.removePersistentDomain(forName: name) }

        // The stored preference says French; the environment override, which
        // is what L10n.text and L10n.button actually read, says Simplified
        // Chinese. The environment value must win, because that is the whole
        // point of routing copy through it rather than through
        // AppLanguage.selected(defaults:).
        AppLanguage.select(.french, defaults: defaults)
        XCTAssertEqual(
            L10n.string("Restore", language: .simplifiedChinese, defaults: defaults),
            "恢复"
        )
        XCTAssertEqual(
            L10n.formatted("Restore", language: .simplifiedChinese, []),
            "恢复"
        )
    }

    func testFormattedSubstitutesArgumentsAfterResolvingTheKey() {
        // "%@ of %@" / "%@ / %@" is a shared key already in all four catalogs.
        let formatted = L10n.formatted(
            "%@ of %@",
            language: .english,
            ["3.6 GB" as NSString, "7.1 GB" as NSString]
        )
        XCTAssertEqual(formatted, "3.6 GB of 7.1 GB")
    }

    func testFormattedWithNoArgumentsReturnsTheResolvedStringUnchanged() {
        XCTAssertEqual(
            L10n.formatted("Continue", language: .french, []),
            L10n.string("Continue", language: .french)
        )
    }

    // MARK: - AppLanguage.nativeName(language:)

    func testNativeNameOfConcreteLanguagesIsLocaleIndependent() {
        // The four concrete endonyms are correct and locale-independent by
        // design (Non goal 7): they name themselves, not the current
        // interface language.
        for language in [
            AppLanguage.simplifiedChinese, .traditionalChinese, .english, .french
        ] {
            XCTAssertEqual(
                language.nativeName(language: .french),
                language.nativeName(language: .simplifiedChinese)
            )
        }
    }

    func testFollowSystemNativeNameResolvesAgainstTheGivenLanguage() {
        XCTAssertEqual(AppLanguage.system.nativeName(language: .english), "Follow System")
        XCTAssertEqual(AppLanguage.system.nativeName(language: .french), "Selon le système")
        XCTAssertEqual(AppLanguage.system.nativeName(language: .simplifiedChinese), "跟随系统")
        XCTAssertEqual(AppLanguage.system.nativeName(language: .traditionalChinese), "跟隨系統")
    }

    func testNativeNameWithNoLanguageFallsBackToStandardUserDefaults() {
        // The nil default is the ONLY seam that still touches UserDefaults
        // directly; every SwiftUI call site instead threads \.appLanguage
        // through so a screen updates without relaunching.
        XCTAssertEqual(
            AppLanguage.system.nativeName(),
            AppLanguage.system.nativeName(language: AppLanguage.selected())
        )
    }
}
