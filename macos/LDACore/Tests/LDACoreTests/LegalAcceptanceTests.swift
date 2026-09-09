import Foundation
import XCTest
@testable import LDAUI

@MainActor
final class LegalAcceptanceTests: XCTestCase {
    private let documents = LegalDocuments(version: "1", terms: "Terms A", privacy: "Privacy A")

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let (defaults, suite) = TestNamespace.defaults("legal-acceptance")
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    func testFirstUseRequiresAcceptanceEvenAfterOldOnboardingWasCompleted() throws {
        try withDefaults { defaults in
            defaults.set(true, forKey: "com.haotianyi.LDA.hasCompletedFirstRun")
            let store = LegalAcceptanceStore(defaults: defaults, documents: documents)
            XCTAssertFalse(store.hasAcceptedCurrentDocuments)
            XCTAssertTrue(store.records.isEmpty)
        }
    }

    func testNeitherSingleCheckboxNorNoCheckboxCanRecordAcceptance() throws {
        try withDefaults { defaults in
            let store = LegalAcceptanceStore(defaults: defaults, documents: documents)
            for selection in [(false, false), (true, false), (false, true)] {
                XCTAssertThrowsError(try store.accept(terms: selection.0, privacy: selection.1))
                XCTAssertFalse(store.hasAcceptedCurrentDocuments)
                XCTAssertNil(defaults.data(forKey: LegalAcceptanceStore.storageKey))
            }
        }
    }

    func testBothDocumentsAndDateSurviveRelaunch() throws {
        try withDefaults { defaults in
            let date = Date(timeIntervalSince1970: 1_800_000_000)
            let store = LegalAcceptanceStore(defaults: defaults, documents: documents)
            try store.accept(terms: true, privacy: true, at: date)
            let relaunched = LegalAcceptanceStore(defaults: defaults, documents: documents)
            XCTAssertTrue(relaunched.hasAcceptedCurrentDocuments)
            let receipt = try XCTUnwrap(relaunched.records.last)
            XCTAssertEqual(receipt.acceptedAt, date)
            XCTAssertEqual(receipt.documents, documents)
            XCTAssertEqual(receipt.termsSHA256.count, 64)
            XCTAssertEqual(receipt.privacySHA256.count, 64)
        }
    }

    func testEitherDocumentChangeRequiresFreshAcceptanceEvenWithoutVersionBump() throws {
        try withDefaults { defaults in
            try LegalAcceptanceStore(defaults: defaults, documents: documents)
                .accept(terms: true, privacy: true)
            let changes = [
                LegalDocuments(version: "1", terms: "Terms B", privacy: documents.privacy),
                LegalDocuments(version: "1", terms: documents.terms, privacy: "Privacy B"),
                LegalDocuments(version: "2", terms: documents.terms, privacy: documents.privacy)
            ]
            for changed in changes {
                let updated = LegalAcceptanceStore(defaults: defaults, documents: changed)
                XCTAssertFalse(updated.hasAcceptedCurrentDocuments)
            }
        }
    }

    func testReacceptanceRetainsPreviousExactTextAndDoesNotDuplicateCurrentReceipt() throws {
        try withDefaults { defaults in
            try LegalAcceptanceStore(defaults: defaults, documents: documents)
                .accept(terms: true, privacy: true)
            let changed = LegalDocuments(version: "2", terms: "Terms B", privacy: "Privacy B")
            let updated = LegalAcceptanceStore(defaults: defaults, documents: changed)
            try updated.accept(terms: true, privacy: true)
            try updated.accept(terms: true, privacy: true)
            XCTAssertEqual(updated.records.count, 2)
            XCTAssertEqual(updated.records.first?.documents, documents)
            XCTAssertEqual(updated.records.last?.documents, changed)
            XCTAssertTrue(updated.hasAcceptedCurrentDocuments)
        }
    }

    func testMissingDocumentsCannotUnlockOrCreateReceipt() throws {
        try withDefaults { defaults in
            let store = LegalAcceptanceStore(defaults: defaults, documents: nil)
            XCTAssertThrowsError(try store.accept(terms: true, privacy: true))
            XCTAssertFalse(store.hasAcceptedCurrentDocuments)
            XCTAssertNil(defaults.data(forKey: LegalAcceptanceStore.storageKey))
        }
    }

    func testUnreadableReceiptFailsClosed() throws {
        try withDefaults { defaults in
            defaults.set(Data("broken receipt".utf8), forKey: LegalAcceptanceStore.storageKey)
            XCTAssertFalse(LegalAcceptanceStore(defaults: defaults, documents: documents)
                .hasAcceptedCurrentDocuments)
        }
    }

    func testMissingBundleDoesNotHonorAnExistingReceipt() throws {
        try withDefaults { defaults in
            try LegalAcceptanceStore(defaults: defaults, documents: documents)
                .accept(terms: true, privacy: true)
            XCTAssertFalse(LegalAcceptanceStore(defaults: defaults, documents: nil)
                .hasAcceptedCurrentDocuments)
        }
    }

    func testMismatchedReceiptFingerprintFailsClosed() throws {
        try withDefaults { defaults in
            let receipt = LegalAcceptanceRecord(
                acceptedAt: Date(), documents: documents,
                termsSHA256: "invalid", privacySHA256: documents.digest(for: .privacy),
                appVersion: nil
            )
            defaults.set(try JSONEncoder().encode([receipt]), forKey: LegalAcceptanceStore.storageKey)
            XCTAssertFalse(LegalAcceptanceStore(defaults: defaults, documents: documents)
                .hasAcceptedCurrentDocuments)
        }
    }

    func testBundledDocumentsAreAvailableOfflineAndIdentifyTheRequestedDeveloper() throws {
        let bundled = try LegalDocuments.bundled()
        for document in LegalDocument.allCases {
            let text = bundled.text(for: document)
            XCTAssertTrue(text.contains("Forme Locale Studio"))
            XCTAssertTrue(text.contains(bundled.version))
            XCTAssertFalse(text.contains("GitHub Issues"))
            XCTAssertFalse(text.contains("github.com/Reytian/LDA-App/issues"))
            XCTAssertTrue(text.contains("formelocale@protonmail.com"))
            XCTAssertFalse(text.contains("yihaotian@gmail.com"))
            XCTAssertFalse(text.contains("\u{2014}"))
            XCTAssertFalse(text.contains("[TODO"))
        }
        XCTAssertTrue(bundled.terms.contains("New York State law"))
        XCTAssertTrue(bundled.terms.contains("GPLv3 controls"))
    }
}
