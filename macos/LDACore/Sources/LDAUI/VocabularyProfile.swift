//
//  VocabularyProfile.swift
//  LDAUI
//
//  A portable, shareable snapshot of the user's custom vocabulary and learned
//  memory. Export writes one JSON file; import merges it into the local stores.
//  This lets a team share a common list, or a user carry their setup to another
//  device. The file is plain JSON (a glossary of terms to redact), so it is
//  inspectable and mergeable; it is not encrypted, so treat it like any shared
//  glossary that may name clients or matters.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import LDACore

/// A versioned bundle of the custom vocabulary and the learned terms.
public struct VocabularyProfile: Codable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var exportedAtISO8601: String
    public var patterns: [CustomPattern]
    public var learned: [LearnedTerm]

    public init(
        version: Int = VocabularyProfile.currentVersion,
        exportedAtISO8601: String,
        patterns: [CustomPattern],
        learned: [LearnedTerm]
    ) {
        self.version = version
        self.exportedAtISO8601 = exportedAtISO8601
        self.patterns = patterns
        self.learned = learned
    }
}

/// Encode and decode profiles for sharing.
public enum Portability {
    /// Pretty-printed, stable JSON so a profile diffs cleanly in version control.
    public static func encode(_ profile: VocabularyProfile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(profile)
    }

    public static func decode(_ data: Data) throws -> VocabularyProfile {
        try JSONDecoder().decode(VocabularyProfile.self, from: data)
    }
}
