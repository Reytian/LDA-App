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
    private let vault: StoreVault

    /// True when the stored blob exists but could not be opened at launch.
    /// Nothing is written over it this session: the vocabulary it holds may still
    /// open on the next launch, and an overwrite would lose them for good.
    public private(set) var isHoldingUnreadableBlob = false

    /// The production UserDefaults key of the GLOBAL vocabulary blob.
    /// Nonisolated so scope derivation and matter cleanup can run anywhere.
    public nonisolated static var defaultStorageKey: String {
        "com.haotianyi.LDA.customPatterns"
    }

    /// UserDefaults key for the encrypted blob. The bare storageKey is the
    /// LEGACY plaintext location, migrated away on first load.
    private var sealedKey: String { StoreBlobKeys.sealed(storageKey) }

    /// Keychain account for this store's vault key.
    private var vaultAccount: String { StoreBlobKeys.vaultAccount(storageKey) }

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = CustomPatternStore.defaultStorageKey
    ,
        vault: StoreVault = .keychain
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.vault = vault

        // Preferred path: the encrypted blob. (Static helpers here: instance
        // computed properties are unavailable before stored properties
        // initialize.)
        if let sealed = defaults.data(forKey: StoreBlobKeys.sealed(storageKey)) {
            if let data = try? vault.open(sealed, StoreBlobKeys.vaultAccount(storageKey)),
               let decoded = try? JSONDecoder().decode([CustomPattern].self, from: data) {
                self.patterns = decoded
                return
            }
            // The blob is there but will not open (a refused or locked
            // Keychain, a key that went missing, damaged bytes). Review
            // 2026-11-11 (T4): it used to load as empty and the next save
            // wrote over it, so one refusal cost every stored term. It is
            // kept as it is; this session runs on what it holds in memory.
            self.patterns = []
            self.isHoldingUnreadableBlob = true
            return
        }

        // Legacy plaintext blob: load once, then migrate to the vault (the
        // vocabulary holds client and party names). Property observers do not
        // fire during init, so the migration save is explicit.
        if let legacy = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([CustomPattern].self, from: legacy) {
            self.patterns = decoded
            save()
            return
        }

        self.patterns = []
    }

    /// Open the store for one scope over the same defaults. Global scope uses
    /// the existing storage key unchanged, byte for byte; matter scope derives
    /// a key that embeds only the matter's random id, never its label.
    public convenience init(
        scope: StoreScope,
        defaults: UserDefaults = .standard,
        baseKey: String = CustomPatternStore.defaultStorageKey
    ) {
        self.init(defaults: defaults, storageKey: scope.storageKey(base: baseKey))
    }

    /// Delete this store's persisted blob and vault key for one matter. Call
    /// when the matter itself is deleted. The global blob and every other
    /// matter are structurally out of reach: the storage key embeds the id.
    public nonisolated static func removeMatterScope(
        id: UUID,
        defaults: UserDefaults = .standard,
        baseKey: String = CustomPatternStore.defaultStorageKey
    ) {
        let storageKey = StoreScope.matter(id: id).storageKey(base: baseKey)
        StoreBlobKeys.removeAll(storageKey: storageKey, defaults: defaults)
    }

    /// Checked erasure used by matter deletion. Unlike removeMatterScope,
    /// failure to destroy the unique vault key is surfaced to the caller.
    public nonisolated static func eraseMatterScope(
        id: UUID,
        defaults: UserDefaults = .standard,
        baseKey: String = CustomPatternStore.defaultStorageKey
    ) throws {
        let storageKey = StoreScope.matter(id: id).storageKey(base: baseKey)
        try StoreBlobKeys.eraseAll(storageKey: storageKey, defaults: defaults)
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

    /// Identity of a pattern's redaction behavior (term, type, regex flag,
    /// case sensitivity). Module-visible so the scoped facade deduplicates
    /// layers by the same notion merge uses.
    static func contentKey(_ p: CustomPattern) -> String {
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
        // Never over a blob this session could not read (see
        // isHoldingUnreadableBlob).
        guard !isHoldingUnreadableBlob else { return }
        do {
            let data = try JSONEncoder().encode(patterns)
            let sealed = try vault.seal(data, vaultAccount)
            defaults.set(sealed, forKey: sealedKey)
            // Never leave a plaintext copy behind, including right after the
            // legacy migration.
            defaults.removeObject(forKey: storageKey)
        } catch {
            // A failed save keeps the previous blob; loud in debug builds.
            assertionFailure("CustomPatternStore failed to persist: \(error)")
        }
    }
}
