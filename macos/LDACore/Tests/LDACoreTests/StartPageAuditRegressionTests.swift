import AppKit
import SwiftUI
import XCTest
@testable import LDAUI

@MainActor
final class StartPageAuditRegressionTests: XCTestCase {
    private let languages: [AppLanguage] = [.english, .french, .simplifiedChinese, .traditionalChinese]

    func testOnlyEmptyAnonymizeUsesTheCompactWindowBudget() {
        let compact = MainWindowLayout.minimumSize(mode: .anonymize, hasDocuments: false, needsLegalConsent: false)
        XCTAssertLessThanOrEqual(compact.width, 700, "The start page must fit beside another app on a 1440 pt desktop.")
        XCTAssertEqual(compact, CGSize(width: 640, height: 560))
        for mode in AppMode.allCases {
            XCTAssertEqual(
                MainWindowLayout.minimumSize(mode: mode, hasDocuments: true, needsLegalConsent: false),
                CGSize(width: 1100, height: 720)
            )
            XCTAssertEqual(
                MainWindowLayout.minimumSize(mode: mode, hasDocuments: false, needsLegalConsent: true),
                CGSize(width: 1100, height: 720)
            )
            if mode != .anonymize {
                XCTAssertEqual(
                    MainWindowLayout.minimumSize(mode: mode, hasDocuments: false, needsLegalConsent: false),
                    CGSize(width: 1100, height: 720)
                )
            }
        }
        XCTAssertTrue(MainWindowLayout.usesCompactModePicker(width: 640))
        XCTAssertTrue(MainWindowLayout.usesCompactModePicker(width: 1_599))
        XCTAssertFalse(MainWindowLayout.usesCompactModePicker(width: 1_600))
    }

    func testCompactModePickerFitsEveryModeInEveryLanguage() {
        for language in languages {
            for mode in AppMode.allCases {
                let host = NSHostingView(rootView:
                    AppModePicker(selection: .constant(mode), compact: true)
                        .environment(\.appLanguage, language)
                )
                XCTAssertLessThanOrEqual(host.fittingSize.width, 240.5, language.rawValue)
                XCTAssertLessThanOrEqual(host.fittingSize.height, 28, language.rawValue)
            }
        }
    }

}
