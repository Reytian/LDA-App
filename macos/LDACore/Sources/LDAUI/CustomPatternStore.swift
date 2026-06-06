//
//  CustomPatternStore.swift
//  LDAUI
//
//  Persists the user's custom vocabulary (terms to always redact) across launches
//  via UserDefaults inside the app's sandbox container. The store is the single
//  source of truth that both the Settings editor and the ReviewModel read.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import LDACore

/// An observable, persisted list of user-defined redaction terms.
@MainActor
public final class CustomPatternStore: ObservableObject {

    /// The current vocabulary. Mutations persist automatically.
    @Published public var patterns: [CustomPattern] {
        didSet { save() }
    }

    private let defaults: UserDefaults
    private let storageKey: String

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = "com.haotianyi.LDA.customPatterns"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([CustomPattern].self, from: data) {
            self.patterns = decoded
        } else {
            self.patterns = []
        }
    }

    /// Append a new, empty term ready for editing.
    public func add() {
        patterns.append(CustomPattern(text: "", type: .company))
    }

    /// Remove terms at the given offsets (List onDelete).
    public func remove(atOffsets offsets: IndexSet) {
        patterns.remove(atOffsets: offsets)
    }

    /// Merge in patterns from a shared profile, skipping ones already present
    /// (by term, type, regex flag, and case sensitivity). Imported patterns get
    /// fresh ids so they never collide with local ones. Returns how many were added.
    @discardableResult
    public func merge(_ incoming: [CustomPattern]) -> Int {
        var existingKeys = Set(patterns.map(Self.contentKey))
        var added = 0
        for var pattern in incoming {
            let key = Self.contentKey(pattern)
            guard !key.isEmpty, !existingKeys.contains(key) else { continue }
            pattern.id = UUID()
            patterns.append(pattern)
            existingKeys.insert(key)
            added += 1
        }
        return added
    }

    private static func contentKey(_ p: CustomPattern) -> String {
        let text = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        let normalized = p.caseSensitive ? text : text.lowercased()
        return "\(p.type.rawValue)|\(p.isRegex ? "re" : "lit")|\(p.caseSensitive ? "cs" : "ci")|\(normalized)"
    }

    /// The terms that are non-empty and therefore actually applied to documents.
    public var activePatterns: [CustomPattern] {
        patterns.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(patterns) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
