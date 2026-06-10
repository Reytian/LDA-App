//
//  LearningStore.swift
//  LDAUI
//
//  On-device learning. Every export records the user's final accept and reject
//  decisions. Over time the app:
//    - auto-redacts values the user keeps accepting (recurring clients, parties,
//      project names), pre-applied on future documents without re-typing; and
//    - suppresses values the user keeps rejecting, so the same false positive
//      stops appearing.
//  This is what makes the tool feel smarter with use. It is fully local and
//  persists to the app sandbox via UserDefaults. Learning only remembers the
//  fuzzy types (PERSON, COMPANY, ADDRESS) for redaction, since structured PII is
//  already caught deterministically. Rejections are remembered for every type.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import LDACore

/// What the learned counts imply for a value.
public enum LearnedDecision: String, Codable {
    case redact     // net accepted: auto-redact next time
    case suppress   // net rejected: hide next time
    case neutral    // tied: let the engine decide
}

/// One remembered value and how the user has treated it over time.
public struct LearnedTerm: Codable, Identifiable, Equatable {
    public var id: String        // "TYPE|lowercased value"
    public var value: String     // last seen surface, for display
    public var type: EntityType
    public var acceptCount: Int
    public var rejectCount: Int

    public var decision: LearnedDecision {
        if acceptCount > rejectCount { return .redact }
        if rejectCount > acceptCount { return .suppress }
        return .neutral
    }
}

/// Persisted, observable record of what the app has learned from the user.
@MainActor
public final class LearningStore: ObservableObject {

    @Published public private(set) var terms: [String: LearnedTerm]

    /// The fuzzy types worth remembering as redaction vocabulary.
    private static let learnableForRedaction: Set<EntityType> = [.person, .company, .address]

    private let defaults: UserDefaults
    private let storageKey: String

    /// UserDefaults key for the encrypted blob. The bare storageKey is the
    /// LEGACY plaintext location, migrated away on first load.
    private var sealedKey: String { storageKey + ".sealed" }

    /// Keychain account for this store's vault key.
    private var vaultAccount: String { "store.\(storageKey)" }

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = "com.haotianyi.LDA.learnedTerms"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey

        // Preferred path: the encrypted blob. (Local constants: computed
        // properties are unavailable before stored properties initialize.)
        if let sealed = defaults.data(forKey: storageKey + ".sealed"),
           let data = try? LocalDataVault.open(sealed, account: "store.\(storageKey)"),
           let decoded = try? JSONDecoder().decode([String: LearnedTerm].self, from: data) {
            self.terms = decoded
            return
        }

        // Legacy plaintext blob: load once, then migrate to the vault. Learned
        // terms are a de facto client list; they must not stay readable on disk.
        if let legacy = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: LearnedTerm].self, from: legacy) {
            self.terms = decoded
            save()
            return
        }

        self.terms = [:]
    }

    /// A stable key for a value and type. Pure, so usable off the main actor.
    public nonisolated static func key(value: String, type: EntityType) -> String {
        "\(type.rawValue)|\(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    /// Record the user's final decisions from one export. Accepted fuzzy values
    /// reinforce redaction; rejected values (any type) reinforce suppression.
    public func record(
        accepted: [(value: String, type: EntityType)],
        rejected: [(value: String, type: EntityType)]
    ) {
        var changed = false
        for item in accepted where Self.learnableForRedaction.contains(item.type) {
            bump(value: item.value, type: item.type, accepted: true)
            changed = true
        }
        for item in rejected {
            bump(value: item.value, type: item.type, accepted: false)
            changed = true
        }
        if changed { save() }
    }

    /// Net-accepted terms to auto-redact, as literal custom patterns.
    public var redactPatterns: [CustomPattern] {
        terms.values
            .filter { $0.decision == .redact }
            .map { CustomPattern(text: $0.value, type: $0.type, caseSensitive: false, isRegex: false) }
    }

    /// Net-rejected (value, type) keys to suppress from detection.
    public var suppressKeys: Set<String> {
        Set(terms.values.filter { $0.decision == .suppress }.map { $0.id })
    }

    /// Learned terms sorted for display (most reinforced first).
    public var sortedTerms: [LearnedTerm] {
        terms.values.sorted { ($0.acceptCount + $0.rejectCount) > ($1.acceptCount + $1.rejectCount) }
    }

    /// All learned terms (unordered), for export.
    public var allTerms: [LearnedTerm] {
        Array(terms.values)
    }

    /// Merge in learned terms from a shared profile by summing their accept and
    /// reject counts into any matching local term. Returns how many were touched.
    @discardableResult
    public func merge(_ incoming: [LearnedTerm]) -> Int {
        guard !incoming.isEmpty else { return 0 }
        for term in incoming {
            if var existing = terms[term.id] {
                existing.acceptCount += term.acceptCount
                existing.rejectCount += term.rejectCount
                if !term.value.isEmpty { existing.value = term.value }
                terms[term.id] = existing
            } else {
                terms[term.id] = term
            }
        }
        save()
        return incoming.count
    }

    /// Forget one learned term.
    public func forget(_ id: String) {
        terms[id] = nil
        save()
    }

    /// Forget everything.
    public func reset() {
        terms = [:]
        save()
    }

    private func bump(value: String, type: EntityType, accepted: Bool) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let id = Self.key(value: trimmed, type: type)
        var term = terms[id] ?? LearnedTerm(id: id, value: trimmed, type: type, acceptCount: 0, rejectCount: 0)
        term.value = trimmed
        if accepted { term.acceptCount += 1 } else { term.rejectCount += 1 }
        terms[id] = term
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(terms)
            let sealed = try LocalDataVault.seal(data, account: vaultAccount)
            defaults.set(sealed, forKey: sealedKey)
            // Never leave a plaintext copy behind, including right after the
            // legacy migration.
            defaults.removeObject(forKey: storageKey)
        } catch {
            // Persisting learned terms must never corrupt the in-memory state;
            // a failed save keeps the previous blob. Loud in debug builds.
            assertionFailure("LearningStore failed to persist: \(error)")
        }
    }
}
