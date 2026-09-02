//
//  MCPDetectionIdentity.swift
//  LDAMCP
//
//  The review step on the handle-first surface: how detected entities are
//  named on the wire, how the review arguments of anonymize and
//  anonymize_session are validated, and how anonymize checks the caller's
//  exclusions against the detection it actually runs.
//
//  Identity without content: an entity id is derived from its TYPE and its
//  OFFSETS only, both of which detect_entities already discloses, so an id
//  adds no information to the wire. The detectionId fingerprints the whole set
//  (plus the handle and whether a model was used) so anonymize can tell the
//  caller when the detection it ran differs from the one they reviewed.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import CryptoKit
import Foundation
import LDACore

// MARK: - Ids

enum MCPDetectionIdentity {

    /// Hex characters of an entity id: SHA-256 over "TYPE|start|end".
    static let entityIdLength = 12

    /// Hex characters of a detection id: SHA-256 over "handle|model|ids".
    static let detectionIdLength = 16

    /// The wire id of one detected span. Type and offsets only, never text.
    static func entityId(for span: Span) -> String {
        hexDigest(of: "\(span.type.rawValue)|\(span.start)|\(span.end)", length: entityIdLength)
    }

    /// The fingerprint of one detection: the handle it ran on, whether a model
    /// took part (0 or 1), and the SORTED entity ids, so two detections of the
    /// same set compare equal whatever order they were produced in.
    static func detectionId(handle: String, modelPathPresent: Bool, ids: [String]) -> String {
        let material = "\(handle)|\(modelPathPresent ? 1 : 0)|" + ids.sorted().joined(separator: ",")
        return hexDigest(of: material, length: detectionIdLength)
    }

    private static func hexDigest(of material: String, length: Int) -> String {
        let digest = SHA256.hash(data: Data(material.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(length))
    }
}

// MARK: - Review arguments

/// The validated exclusion arguments of the anonymize tools. Parsed and
/// checked before any vault work so a bad argument costs no detection pass.
struct MCPReviewArguments {

    /// Entity types left visible on every channel.
    let excludedTypes: Set<EntityType>
    /// Entity ids (from detect_entities) left visible in the body.
    let excludedIds: Set<String>
    /// The detectionId the ids came with, when given.
    let detectionId: String?

    static let excludeTypesKey = "excludeTypes"
    static let excludeEntityIdsKey = "excludeEntityIds"
    static let detectionIdKey = "detectionId"

    /// Parse the review arguments of a tool call.
    ///
    /// - Parameter allowsEntityIds: false for anonymize_session, where
    ///   per-entity ids are refused explicitly: they are single-document by
    ///   construction, and silently ignoring them would leave the caller
    ///   believing a value stayed visible.
    static func parse(_ arguments: [String: Any], allowsEntityIds: Bool) throws -> MCPReviewArguments {
        let types = try stringArray(arguments, key: excludeTypesKey)
        var excludedTypes = Set<EntityType>()
        for raw in types {
            guard let type = EntityType(rawValue: raw) else {
                throw MCPToolError.invalidArgument(
                    key: excludeTypesKey,
                    value: raw,
                    allowed: EntityType.allCases.map(\.rawValue)
                )
            }
            excludedTypes.insert(type)
        }

        let ids = try stringArray(arguments, key: excludeEntityIdsKey)
        let detectionId = (arguments[detectionIdKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if !ids.isEmpty {
            guard allowsEntityIds else {
                throw MCPVaultToolError.entityIdsNotSupportedForSessions
            }
            guard detectionId != nil else {
                throw MCPVaultToolError.detectionIdRequired
            }
        }
        return MCPReviewArguments(
            excludedTypes: excludedTypes,
            excludedIds: Set(ids),
            detectionId: detectionId
        )
    }

    /// An optional array-of-strings argument. Absent means empty; present in
    /// any other shape is an explicit error rather than a silent no-op.
    private static func stringArray(_ arguments: [String: Any], key: String) throws -> [String] {
        guard let raw = arguments[key] else { return [] }
        guard let values = raw as? [String] else {
            throw MCPToolError.invalidArgument(
                key: key,
                value: "not an array of strings",
                allowed: ["an array of strings"]
            )
        }
        return values
    }
}

// MARK: - Detection observer

/// Watches the body detection anonymize actually runs, through LDAService's
/// spanFilter seam: it records every fresh entity id and excludes the ids the
/// caller named. Spans (with their surface text) stay inside this process;
/// only ids are kept. A reference type because the seam is an escaping
/// closure and one instance must accumulate across every span.
final class MCPDetectionObserver {

    /// What the run showed once it finished.
    struct Verdict {
        /// Supplied ids absent from the fresh detection. Non-zero means the
        /// caller reviewed a different detection and nothing may be written.
        let unknownIdCount: Int
        /// The fresh detectionId differs from the one supplied (soft: every
        /// excluded id was still present, so the run proceeded).
        let detectionChanged: Bool
    }

    private let excludedIds: Set<String>
    private var freshIds: [String] = []

    init(excludedIds: Set<String>) {
        self.excludedIds = excludedIds
    }

    /// The spanFilter verdict for one body span: record it, keep it unless the
    /// caller excluded its id.
    func keep(_ span: Span) -> Bool {
        let id = MCPDetectionIdentity.entityId(for: span)
        freshIds.append(id)
        return !excludedIds.contains(id)
    }

    /// Compare what ran against what the caller reviewed.
    func verdict(handle: String, modelPathPresent: Bool, review: MCPReviewArguments) -> Verdict {
        let fresh = Set(freshIds)
        let unknown = excludedIds.subtracting(fresh).count
        let freshDetectionId = MCPDetectionIdentity.detectionId(
            handle: handle,
            modelPathPresent: modelPathPresent,
            ids: freshIds
        )
        let changed = review.detectionId.map { $0 != freshDetectionId } ?? false
        return Verdict(unknownIdCount: unknown, detectionChanged: changed)
    }
}
