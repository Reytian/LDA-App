//
//  MatterMetadataStore.swift
//  LDACore
//
//  Encrypted workspace-only metadata for matter names, aliases, and reversible
//  archive state. Filenames are random identifiers so matter names do not leak
//  through the filesystem.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation

public struct MatterMetadata: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var label: String
    public var aliases: [String]
    public var isArchived: Bool

    public init(
        id: UUID = UUID(),
        label: String,
        aliases: [String] = [],
        isArchived: Bool = false
    ) {
        self.id = id
        self.label = label
        self.aliases = aliases
        self.isArchived = isArchived
    }
}

public struct MatterMetadataResolution: Equatable, Sendable {
    public let metadata: [MatterMetadata]
    public let unreadableCount: Int

    public init(metadata: [MatterMetadata], unreadableCount: Int) {
        self.metadata = metadata
        self.unreadableCount = unreadableCount
    }
}

public struct MatterMetadataStore {
    public let root: URL

    public static let keychainAccount = "workspace-metadata"

    private static let fileExtension = "ldamatter"
    private static let container = EncryptedContainer(
        magic: Array("LDAMTR".utf8),
        keychainService: "ai.openclaw.lda.matterkey",
        containerDescription: "Matter workspace metadata"
    )

    public init(rootDirectory: URL? = nil) throws {
        if let rootDirectory {
            root = rootDirectory
        } else {
            let appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            root = appSupport
                .appendingPathComponent("LDA", isDirectory: true)
                .appendingPathComponent("Matters", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public static func defaultProtection() -> MappingProtection {
        .keychain(account: keychainAccount)
    }

    public func list(
        protection: MappingProtection? = nil
    ) throws -> MatterMetadataResolution {
        let contents = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        var metadata: [MatterMetadata] = []
        var unreadableCount = 0

        for url in contents where url.pathExtension == Self.fileExtension {
            do {
                metadata.append(try load(from: url, protection: protection))
            } catch {
                unreadableCount += 1
            }
        }

        return MatterMetadataResolution(
            metadata: metadata.sorted {
                $0.label.localizedStandardCompare($1.label) == .orderedAscending
            },
            unreadableCount: unreadableCount
        )
    }

    /// Return the metadata entry that owns the label (exactly or through a
    /// rename alias), creating and persisting a new entry when none exists.
    /// The entry's stable random id is what matter-scoped stores key on, so a
    /// matter acquires its id the first time a caller needs one.
    @discardableResult
    public func ensure(
        label: String,
        protection: MappingProtection? = nil
    ) throws -> MatterMetadata {
        let cleaned = try validated(label)
        let resolved = try list(protection: protection)
        guard resolved.unreadableCount == 0 else {
            throw DocumentIOError.corrupt(
                "Matter workspace metadata exists but could not be unlocked."
            )
        }
        if let existing = resolved.metadata.first(where: {
            $0.label == cleaned || $0.aliases.contains(cleaned)
        }) {
            return existing
        }
        let created = MatterMetadata(label: cleaned)
        try save(created, protection: protection)
        return created
    }

    public func setArchived(
        label: String,
        isArchived: Bool,
        protection: MappingProtection? = nil
    ) throws {
        let cleaned = try validated(label)
        let resolved = try list(protection: protection)
        guard resolved.unreadableCount == 0 else {
            throw DocumentIOError.corrupt(
                "Matter workspace metadata exists but could not be unlocked."
            )
        }

        var item = resolved.metadata.first {
            $0.label == cleaned || $0.aliases.contains(cleaned)
        } ?? MatterMetadata(label: cleaned)
        item.isArchived = isArchived
        try save(item, protection: protection)
    }

    public func rename(
        from oldLabel: String,
        to newLabel: String,
        protection: MappingProtection? = nil
    ) throws {
        let oldLabel = try validated(oldLabel)
        let newLabel = try validated(newLabel)
        guard oldLabel != newLabel else { return }

        let resolved = try list(protection: protection)
        guard resolved.unreadableCount == 0 else {
            throw DocumentIOError.corrupt(
                "Matter workspace metadata exists but could not be unlocked."
            )
        }

        let source = resolved.metadata.first {
            $0.label == oldLabel || $0.aliases.contains(oldLabel)
        }
        if let owner = resolved.metadata.first(where: {
            $0.label == newLabel || $0.aliases.contains(newLabel)
        }), owner.id != source?.id {
            throw DocumentIOError.unsupportedFormat(
                "A different matter already uses \"\(newLabel)\"."
            )
        }

        var item = source ?? MatterMetadata(label: oldLabel)
        var aliases = item.aliases
        if item.label != newLabel {
            aliases.append(item.label)
        }
        var seen = Set<String>()
        item.aliases = aliases.filter {
            $0 != newLabel && seen.insert($0).inserted
        }
        item.label = newLabel
        try save(item, protection: protection)
    }

    private func save(
        _ metadata: MatterMetadata,
        protection: MappingProtection?
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plaintext: Data
        do {
            plaintext = try encoder.encode(metadata)
        } catch {
            throw DocumentIOError.corrupt("Failed to encode matter workspace metadata: \(error)")
        }
        try Self.container.save(
            plaintext,
            to: fileURL(for: metadata.id),
            protection: protection ?? Self.defaultProtection()
        )
    }

    private func load(
        from url: URL,
        protection: MappingProtection?
    ) throws -> MatterMetadata {
        let plaintext = try Self.container.load(
            from: url,
            protection: protection ?? Self.defaultProtection()
        )
        do {
            return try JSONDecoder().decode(MatterMetadata.self, from: plaintext)
        } catch {
            throw DocumentIOError.corrupt("Decrypted payload is not matter workspace metadata: \(error)")
        }
    }

    private func fileURL(for id: UUID) -> URL {
        root.appendingPathComponent("\(id.uuidString).\(Self.fileExtension)")
    }

    private func validated(_ label: String) throws -> String {
        let cleaned = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw DocumentIOError.unsupportedFormat("matter label must not be empty")
        }
        return cleaned
    }
}
