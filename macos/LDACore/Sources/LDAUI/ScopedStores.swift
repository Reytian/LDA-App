//
//  ScopedStores.swift
//  LDAUI
//
//  Effective-rule facades over the global store layer and one optional matter
//  layer. Each facade exposes the same read surface the review pipeline uses
//  on the concrete store today (suppressKeys, redactPatterns, record for
//  learning; activePatterns for custom vocabulary), so the later session-layer
//  injection is a type swap, not a rewrite.
//
//  Read semantics: the union of the global and matter layers; where both
//  layers hold a rule for the same key, the matter layer wins. Write
//  semantics: the caller names the target layer; the default is .global,
//  which preserves the pre-scoping behavior.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import Combine
import LDACore

/// Union view over the global learning layer and one optional matter layer.
@MainActor
public final class ScopedLearningStore: ObservableObject {

    /// The app-wide layer. Writes land here unless .matter is named.
    public let global: LearningStore

    /// The selected matter's layer; nil when no matter is active, in which
    /// case the facade behaves exactly like the global store.
    public let matter: LearningStore?

    private var forwarders: Set<AnyCancellable> = []

    public init(global: LearningStore, matter: LearningStore? = nil) {
        self.global = global
        self.matter = matter
        forwardChanges(from: [global, matter].compactMap { $0 })
    }

    /// Republish layer mutations so SwiftUI views observing the facade
    /// refresh when either underlying store changes.
    private func forwardChanges(from layers: [LearningStore]) {
        for layer in layers {
            layer.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &forwarders)
        }
    }

    /// Terms whose rules apply under this scope: every decided matter term,
    /// plus every decided global term the matter layer has not decided. A
    /// tied (neutral) term expresses no rule and never overrides the other
    /// layer.
    private var effectiveDecidedTerms: [LearnedTerm] {
        let globalDecided = global.terms.values.filter { $0.decision != .neutral }
        guard let matter else { return Array(globalDecided) }
        let matterDecided = matter.terms.values.filter { $0.decision != .neutral }
        let overridden = Set(matterDecided.map(\.id))
        return matterDecided + globalDecided.filter { !overridden.contains($0.id) }
    }

    /// Net-rejected (value, type) keys to suppress from detection. Same
    /// contract as LearningStore.suppressKeys.
    public var suppressKeys: Set<String> {
        Set(effectiveDecidedTerms.filter { $0.decision == .suppress }.map(\.id))
    }

    /// Net-accepted terms to auto-redact, as literal custom patterns. Same
    /// contract as LearningStore.redactPatterns.
    public var redactPatterns: [CustomPattern] {
        effectiveDecidedTerms
            .filter { $0.decision == .redact }
            .map { CustomPattern(text: $0.value, type: $0.type, caseSensitive: false, isRegex: false) }
    }

    /// Record one export's decisions into the chosen layer. Returns false and
    /// records nothing when .matter is requested but no matter layer is
    /// attached: a rule meant for one matter must never bleed into the global
    /// layer, and for a redaction tool the safe failure is more detection.
    @discardableResult
    public func record(
        accepted: [(value: String, type: EntityType)],
        rejected: [(value: String, type: EntityType)],
        to target: ScopeTarget = .global
    ) -> Bool {
        guard let layer = layer(for: target) else { return false }
        layer.record(accepted: accepted, rejected: rejected)
        return true
    }

    /// The concrete store behind a write target, nil when .matter is
    /// requested without an attached matter layer.
    public func layer(for target: ScopeTarget) -> LearningStore? {
        switch target {
        case .global: return global
        case .matter: return matter
        }
    }
}

/// Union view over the global vocabulary layer and one optional matter layer.
///
/// Custom patterns are add-only rules (each says "always redact this term"),
/// so the two layers cannot contradict each other and the union is the whole
/// story. The only overlap that can exist is identical content in both
/// layers; it is deduplicated with the matter copy kept, so the matter layer
/// wins there too.
@MainActor
public final class ScopedCustomPatternStore: ObservableObject {

    /// The app-wide layer. Writes land here unless .matter is named.
    public let global: CustomPatternStore

    /// The selected matter's layer; nil when no matter is active.
    public let matter: CustomPatternStore?

    private var forwarders: Set<AnyCancellable> = []

    public init(global: CustomPatternStore, matter: CustomPatternStore? = nil) {
        self.global = global
        self.matter = matter
        for layer in [global, matter].compactMap({ $0 }) {
            layer.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &forwarders)
        }
    }

    /// The applied vocabulary: both layers' active patterns, matter first,
    /// duplicates removed by content. Same contract as
    /// CustomPatternStore.activePatterns.
    public var activePatterns: [CustomPattern] {
        guard let matter else { return global.activePatterns }
        var seenKeys = Set<String>()
        var union: [CustomPattern] = []
        for pattern in matter.activePatterns + global.activePatterns {
            guard seenKeys.insert(CustomPatternStore.contentKey(pattern)).inserted else { continue }
            union.append(pattern)
        }
        return union
    }

    /// Merge new patterns into the chosen layer, skipping ones that layer
    /// already holds. Returns how many were added; 0, with nothing written,
    /// when .matter is requested but no matter layer is attached.
    @discardableResult
    public func merge(_ incoming: [CustomPattern], to target: ScopeTarget = .global) -> Int {
        guard let layer = layer(for: target) else { return 0 }
        return layer.merge(incoming)
    }

    /// The concrete store behind a write target, nil when .matter is
    /// requested without an attached matter layer.
    public func layer(for target: ScopeTarget) -> CustomPatternStore? {
        switch target {
        case .global: return global
        case .matter: return matter
        }
    }
}

/// One-call cleanup for the matter-deletion flow the UI step wires.
public enum ScopedStores {

    /// Delete both stores' blobs and vault keys for one matter. The global
    /// layer and every other matter are untouched because each storage key
    /// embeds its own matter id.
    public static func removeMatterScope(id: UUID, defaults: UserDefaults = .standard) {
        LearningStore.removeMatterScope(id: id, defaults: defaults)
        CustomPatternStore.removeMatterScope(id: id, defaults: defaults)
    }

    /// Checked deletion boundary for a user-visible matter erase. Each
    /// matter-scoped store owns a distinct vault key, and either Keychain
    /// failure is returned instead of being reported as successful erasure.
    public static func eraseMatterScope(
        id: UUID,
        defaults: UserDefaults = .standard
    ) throws {
        try LearningStore.eraseMatterScope(id: id, defaults: defaults)
        try CustomPatternStore.eraseMatterScope(id: id, defaults: defaults)
    }
}
