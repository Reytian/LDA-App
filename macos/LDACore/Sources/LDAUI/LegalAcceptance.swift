import CryptoKit
import Foundation
import SwiftUI

enum LegalDocument: String, CaseIterable, Identifiable, Codable {
    case terms = "TermsOfService"
    case privacy = "PrivacyPolicy"

    var id: String { rawValue }
    var title: String { self == .terms ? "Terms of Service" : "Privacy Policy" }
}

struct LegalDocuments: Codable, Equatable {
    let version: String
    let terms: String
    let privacy: String

    static func bundled() throws -> Self {
        guard let bundle = LDAResourceBundle.resolve() else {
            throw LegalAcceptanceError.documentsUnavailable
        }
        func read(_ document: LegalDocument) throws -> String {
            guard let url = bundle.url(forResource: document.rawValue, withExtension: "md"),
                  url.isFileURL else {
                throw LegalAcceptanceError.documentsUnavailable
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LegalAcceptanceError.documentsUnavailable
            }
            return text
        }
        return try Self(version: "2026-09-09", terms: read(.terms), privacy: read(.privacy))
    }

    func text(for document: LegalDocument) -> String {
        document == .terms ? terms : privacy
    }

    func digest(for document: LegalDocument) -> String {
        SHA256.hash(data: Data(text(for: document).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

struct LegalAcceptanceRecord: Codable, Equatable {
    let acceptedAt: Date
    let documents: LegalDocuments
    let termsSHA256: String
    let privacySHA256: String
    let appVersion: String?

    func matches(_ current: LegalDocuments) -> Bool {
        documents == current
            && termsSHA256 == current.digest(for: .terms)
            && privacySHA256 == current.digest(for: .privacy)
    }
}

enum LegalAcceptanceError: Error {
    case documentsUnavailable
    case acceptanceRequired
}

/// One app-owned store gates every GUI scene, independently of onboarding.
/// Receipts and the exact accepted text stay in this Mac user's preferences.
@MainActor
public final class LegalAcceptanceStore: ObservableObject {
    static let storageKey = "com.haotianyi.LDA.legalAcceptanceRecords.v1"
    let documents: LegalDocuments?
    @Published private(set) var records: [LegalAcceptanceRecord]
    private let defaults: UserDefaults

    public convenience init() {
        self.init(defaults: .standard, documents: try? LegalDocuments.bundled())
    }

    init(defaults: UserDefaults, documents: LegalDocuments?) {
        self.defaults = defaults
        self.documents = documents
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([LegalAcceptanceRecord].self, from: data) {
            records = saved
        } else {
            records = []
        }
    }

    public var hasAcceptedCurrentDocuments: Bool {
        guard let documents else { return false }
        return records.last?.matches(documents) == true
    }

    func accept(terms: Bool, privacy: Bool, at date: Date = Date()) throws {
        guard terms && privacy else { throw LegalAcceptanceError.acceptanceRequired }
        guard let documents else { throw LegalAcceptanceError.documentsUnavailable }
        guard !hasAcceptedCurrentDocuments else { return }
        let record = LegalAcceptanceRecord(
            acceptedAt: date,
            documents: documents,
            termsSHA256: documents.digest(for: .terms),
            privacySHA256: documents.digest(for: .privacy),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        )
        let updated = records + [record]
        let encoded = try JSONEncoder().encode(updated)
        defaults.set(encoded, forKey: Self.storageKey)
        records = updated
    }
}
