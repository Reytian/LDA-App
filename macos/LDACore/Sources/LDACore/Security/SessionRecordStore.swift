//
//  SessionRecordStore.swift
//  LDACore
//
//  Per-session records (R18): what was protected and what was restored, so
//  the user can review and trust each round-trip after the fact. A record
//  holds counts, entity types, and document names; it NEVER holds the
//  sensitive values themselves (those live only in the encrypted mapping).
//  Records are still encrypted at rest because document names and client
//  labels are themselves confidential.
//
//  One file per record (<id>.ldarec) under ApplicationSupport/LDA/Records,
//  encrypted by EncryptedContainer (magic LDAREC) with one shared Keychain
//  key (account "records") or a caller-supplied passphrase.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

// MARK: - Record types

/// One document inside a session record: its name and what was protected.
public struct SessionRecordDocument: Codable, Equatable, Sendable {
    public var name: String
    public var entityCount: Int
    /// The distinct entity-type wire strings protected in this document.
    public var entityTypes: [String]

    public init(name: String, entityCount: Int, entityTypes: [String]) {
        self.name = name
        self.entityCount = entityCount
        self.entityTypes = entityTypes
    }
}

/// One restore performed against the session's mapping.
public struct SessionRestoreEvent: Codable, Equatable, Sendable {
    public var atISO8601: String
    public var restoredCount: Int
    public var orphanCount: Int
    public var suspectCount: Int

    public init(atISO8601: String, restoredCount: Int, orphanCount: Int, suspectCount: Int) {
        self.atISO8601 = atISO8601
        self.restoredCount = restoredCount
        self.orphanCount = orphanCount
        self.suspectCount = suspectCount
    }
}

/// One session's record: what was protected, under which client, and every
/// restore that ran against it.
public struct SessionRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var createdAtISO8601: String
    public var clientLabel: String?
    public var documents: [SessionRecordDocument]
    /// Distinct protected identities in the session mapping.
    public var protectedValueCount: Int
    public var restoreEvents: [SessionRestoreEvent]

    public init(
        id: UUID = UUID(),
        createdAtISO8601: String,
        clientLabel: String?,
        documents: [SessionRecordDocument],
        protectedValueCount: Int,
        restoreEvents: [SessionRestoreEvent] = []
    ) {
        self.id = id
        self.createdAtISO8601 = createdAtISO8601
        self.clientLabel = clientLabel
        self.documents = documents
        self.protectedValueCount = protectedValueCount
        self.restoreEvents = restoreEvents
    }
}

// MARK: - Store

/// Encrypted per-session record directory.
public struct SessionRecordStore {

    /// The directory holding one .ldarec file per session.
    public let root: URL

    private static let fileExtension = "ldarec"

    /// The shared Keychain account for record files.
    public static let keychainAccount = "records"

    private static let container = EncryptedContainer(
        magic: Array("LDAREC".utf8),
        keychainService: "ai.openclaw.lda.recordkey",
        containerDescription: "Session record"
    )

    /// Creates or opens the store. nil rootDirectory uses the production
    /// default (<ApplicationSupport>/LDA/Records).
    public init(rootDirectory: URL? = nil) throws {
        if let provided = rootDirectory {
            self.root = provided
        } else {
            let appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            self.root = appSupport
                .appendingPathComponent("LDA", isDirectory: true)
                .appendingPathComponent("Records", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// The default protection: the shared records Keychain key.
    public static func defaultProtection() -> MappingProtection {
        .keychain(account: keychainAccount)
    }

    // MARK: - Public API

    /// Save (or overwrite) one record.
    public func save(
        _ record: SessionRecord,
        protection: MappingProtection? = nil
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plaintext: Data
        do {
            plaintext = try encoder.encode(record)
        } catch {
            throw DocumentIOError.corrupt("Failed to encode session record: \(error)")
        }
        try Self.container.save(
            plaintext,
            to: fileURL(for: record.id),
            protection: protection ?? Self.defaultProtection()
        )
    }

    /// Load one record by id, or nil when absent.
    public func load(
        id: UUID,
        protection: MappingProtection? = nil
    ) throws -> SessionRecord? {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let plaintext = try Self.container.load(
            from: url,
            protection: protection ?? Self.defaultProtection()
        )
        do {
            return try JSONDecoder().decode(SessionRecord.self, from: plaintext)
        } catch {
            throw DocumentIOError.corrupt("Decrypted payload is not a session record: \(error)")
        }
    }

    /// Every record, newest first. A record that fails to decrypt is skipped
    /// (a damaged record must not hide the readable history).
    public func list(protection: MappingProtection? = nil) throws -> [SessionRecord] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        var records: [SessionRecord] = []
        for url in contents where url.pathExtension == Self.fileExtension {
            guard let idString = url.deletingPathExtension().lastPathComponent as String?,
                  let id = UUID(uuidString: idString),
                  let record = try? load(id: id, protection: protection) else {
                continue
            }
            records.append(record)
        }
        return records.sorted {
            ($0.createdAtISO8601, $0.id.uuidString) > ($1.createdAtISO8601, $1.id.uuidString)
        }
    }

    /// Append one restore event to an existing record. A missing record is a
    /// no-op (the session may predate record keeping).
    public func appendRestoreEvent(
        to id: UUID,
        event: SessionRestoreEvent,
        protection: MappingProtection? = nil
    ) throws {
        guard var record = try load(id: id, protection: protection) else { return }
        record.restoreEvents.append(event)
        try save(record, protection: protection)
    }

    /// Delete one record. A missing record is treated as success.
    public func delete(id: UUID) throws {
        let url = fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - File naming

    private func fileURL(for id: UUID) -> URL {
        root.appendingPathComponent("\(id.uuidString).\(Self.fileExtension)")
    }
}
