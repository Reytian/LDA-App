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
    /// Protected entity counts keyed by entity-type wire string. Optional:
    /// records written before the compliance report existed carry only the
    /// total count and the distinct type list.
    public var entityCountsByType: [String: Int]?

    public init(
        name: String,
        entityCount: Int,
        entityTypes: [String],
        entityCountsByType: [String: Int]? = nil
    ) {
        self.name = name
        self.entityCount = entityCount
        self.entityTypes = entityTypes
        self.entityCountsByType = entityCountsByType
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case entityCount
        case entityTypes
        case entityCountsByType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.entityCount = try container.decode(Int.self, forKey: .entityCount)
        self.entityTypes = try container.decode([String].self, forKey: .entityTypes)
        // Legacy payloads predate per-type counts; decode as absent.
        self.entityCountsByType = try container.decodeIfPresent(
            [String: Int].self,
            forKey: .entityCountsByType
        )
    }
}

/// Scan-side verification counts recorded when the handoff was built. The
/// restore-side twin is SessionRestoreEvent, which records orphanCount and
/// suspectCount per restore.
public struct SessionScanVerification: Codable, Equatable, Sendable {
    /// Additional occurrences the literal rescan recall pass surfaced.
    public var rescanHitCount: Int
    /// Cross-document rescan warnings still open when the handoff was built.
    public var rescanWarningCount: Int
    /// Near-miss placeholder shapes reported by placeholder forensics.
    public var forensicsSuspectCount: Int

    public init(rescanHitCount: Int, rescanWarningCount: Int, forensicsSuspectCount: Int) {
        self.rescanHitCount = rescanHitCount
        self.rescanWarningCount = rescanWarningCount
        self.forensicsSuspectCount = forensicsSuspectCount
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
    /// The substitution style the handoff was rendered in. Optional: records
    /// written before the compliance report existed carry no style.
    public var substitutionStyle: SubstitutionStyle?
    /// The detection model's display name, for example the GGUF file name.
    /// Optional, and value free: a model name is not client data.
    public var modelName: String?
    /// The app version that wrote the record (CFBundleShortVersionString).
    public var appVersion: String?
    /// Scan-side verification counts recorded at handoff time.
    public var scanVerification: SessionScanVerification?

    public init(
        id: UUID = UUID(),
        createdAtISO8601: String,
        clientLabel: String?,
        documents: [SessionRecordDocument],
        protectedValueCount: Int,
        restoreEvents: [SessionRestoreEvent] = [],
        substitutionStyle: SubstitutionStyle? = nil,
        modelName: String? = nil,
        appVersion: String? = nil,
        scanVerification: SessionScanVerification? = nil
    ) {
        self.id = id
        self.createdAtISO8601 = createdAtISO8601
        self.clientLabel = clientLabel
        self.documents = documents
        self.protectedValueCount = protectedValueCount
        self.restoreEvents = restoreEvents
        self.substitutionStyle = substitutionStyle
        self.modelName = modelName
        self.appVersion = appVersion
        self.scanVerification = scanVerification
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAtISO8601
        case clientLabel
        case documents
        case protectedValueCount
        case restoreEvents
        case substitutionStyle
        case modelName
        case appVersion
        case scanVerification
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.createdAtISO8601 = try container.decode(String.self, forKey: .createdAtISO8601)
        self.clientLabel = try container.decodeIfPresent(String.self, forKey: .clientLabel)
        self.documents = try container.decode([SessionRecordDocument].self, forKey: .documents)
        self.protectedValueCount = try container.decode(Int.self, forKey: .protectedValueCount)
        self.restoreEvents = try container.decode([SessionRestoreEvent].self, forKey: .restoreEvents)
        // Legacy payloads predate the compliance report fields; decode all of
        // them as absent so old records keep loading.
        self.substitutionStyle = try container.decodeIfPresent(
            SubstitutionStyle.self,
            forKey: .substitutionStyle
        )
        self.modelName = try container.decodeIfPresent(String.self, forKey: .modelName)
        self.appVersion = try container.decodeIfPresent(String.self, forKey: .appVersion)
        self.scanVerification = try container.decodeIfPresent(
            SessionScanVerification.self,
            forKey: .scanVerification
        )
    }
}

public struct SessionRecordResolution: Equatable, Sendable {
    public let records: [SessionRecord]
    public let unreadableCount: Int

    public init(records: [SessionRecord], unreadableCount: Int) {
        self.records = records
        self.unreadableCount = unreadableCount
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

    /// Every readable record, newest first, plus a count of records that could
    /// not be unlocked or validated.
    public func resolve(
        protection: MappingProtection? = nil
    ) throws -> SessionRecordResolution {
        let contents = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        var records: [SessionRecord] = []
        var unreadableCount = 0
        for url in contents where url.pathExtension == Self.fileExtension {
            let idString = url.deletingPathExtension().lastPathComponent
            guard let id = UUID(uuidString: idString) else {
                unreadableCount += 1
                continue
            }
            do {
                if let record = try load(id: id, protection: protection) {
                    records.append(record)
                } else {
                    unreadableCount += 1
                }
            } catch {
                unreadableCount += 1
            }
        }
        return SessionRecordResolution(
            records: records.sorted {
                ($0.createdAtISO8601, $0.id.uuidString) > ($1.createdAtISO8601, $1.id.uuidString)
            },
            unreadableCount: unreadableCount
        )
    }

    /// Every record, newest first. A damaged record does not hide readable
    /// history, but an entirely locked history still surfaces as an error.
    public func list(protection: MappingProtection? = nil) throws -> [SessionRecord] {
        let resolution = try resolve(protection: protection)
        if resolution.records.isEmpty, resolution.unreadableCount > 0 {
            throw DocumentIOError.corrupt("Session history exists but could not be unlocked.")
        }
        return resolution.records
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

    /// Stamp (or overwrite) the scan-side verification summary on an existing
    /// record. A missing record is a no-op (the session may predate record
    /// keeping), mirroring appendRestoreEvent.
    public func updateScanVerification(
        to id: UUID,
        verification: SessionScanVerification,
        protection: MappingProtection? = nil
    ) throws {
        guard var record = try load(id: id, protection: protection) else { return }
        record.scanVerification = verification
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
