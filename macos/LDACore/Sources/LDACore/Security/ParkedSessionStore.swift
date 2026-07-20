//
//  ParkedSessionStore.swift
//  LDACore
//
//  Encrypted persistence for an awaiting-AI round trip. The matter label lives
//  inside the encrypted payload with the mapping and never in UserDefaults.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation

/// Everything needed to resume an awaiting-AI round trip after relaunch.
public struct ParkedSessionState: Codable, Equatable, Sendable {
    public var mapping: Mapping
    public var clientLabel: String?

    public init(mapping: Mapping, clientLabel: String?) {
        self.mapping = mapping
        self.clientLabel = clientLabel
    }
}

/// Stores parked round-trip context in a distinct encrypted container.
public enum ParkedSessionStore {
    private static let container = EncryptedContainer(
        magic: Array("LDAPRK".utf8),
        keychainService: "ai.openclaw.lda.parkedkey",
        containerDescription: "Parked session"
    )

    public static func save(
        _ state: ParkedSessionState,
        to url: URL,
        protection: MappingProtection
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            try container.save(encoder.encode(state), to: url, protection: protection)
        } catch let error as DocumentIOError {
            throw error
        } catch {
            throw DocumentIOError.corrupt("Failed to encode parked session: \(error)")
        }
    }

    public static func load(
        from url: URL,
        protection: MappingProtection
    ) throws -> ParkedSessionState {
        let plaintext = try container.load(from: url, protection: protection)
        do {
            return try JSONDecoder().decode(ParkedSessionState.self, from: plaintext)
        } catch {
            throw DocumentIOError.corrupt(
                "Decrypted payload is not a valid parked session: \(error)"
            )
        }
    }
}
