//
//  MatterWorkspacePresentation.swift
//  LDAUI
//
//  Value-free aggregation for the Matters workspace. The workspace derives
//  its contents from existing client mappings and encrypted session records,
//  so it does not create a second store for confidential matter metadata.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import LDACore

struct MatterSummary: Identifiable, Equatable {
    let id: String
    var label: String
    var sessionCount: Int
    var documentCount: Int
    var protectedValueCount: Int
    var restoreCount: Int
    var flaggedCount: Int
    var lastActivityISO8601: String?
    var isArchived: Bool
}

enum MatterWorkspaceScope: String, CaseIterable {
    case active = "Active"
    case archived = "Archived"
}

enum MatterWorkspaceDestination: Equatable {
    case anonymize
    case restore

    var appMode: AppMode {
        switch self {
        case .anonymize: return .anonymize
        case .restore: return .deanonymize
        }
    }
}

enum MatterWorkspacePresentation {
    static func summaries(
        clientLabels: [String],
        records: [SessionRecord],
        metadata: [MatterMetadata] = []
    ) -> [MatterSummary] {
        var byIdentity: [String: MatterSummary] = [:]

        for item in metadata {
            guard let label = storedLabel(item.label) else { continue }
            byIdentity[label] = emptySummary(
                label: label,
                isArchived: item.isArchived
            )
        }

        for candidate in clientLabels {
            guard let label = canonicalLabel(candidate, metadata: metadata) else { continue }
            if byIdentity[label] == nil {
                byIdentity[label] = emptySummary(
                    label: label,
                    isArchived: isArchived(label, metadata: metadata)
                )
            }
        }

        for record in records {
            guard let candidate = record.clientLabel,
                  let label = canonicalLabel(candidate, metadata: metadata) else { continue }
            var summary = byIdentity[label] ?? emptySummary(
                label: label,
                isArchived: isArchived(label, metadata: metadata)
            )

            summary.label = label
            summary.sessionCount += 1
            summary.documentCount += record.documents.count
            summary.protectedValueCount = max(
                summary.protectedValueCount,
                record.protectedValueCount
            )
            summary.restoreCount += record.restoreEvents.count
            summary.flaggedCount += record.restoreEvents.reduce(0) {
                $0 + $1.orphanCount + $1.suspectCount
            }
            summary.lastActivityISO8601 = maxISO8601(
                summary.lastActivityISO8601,
                recordActivityISO8601(record)
            )
            byIdentity[label] = summary
        }

        return byIdentity.values.sorted { lhs, rhs in
            switch (lhs.lastActivityISO8601, rhs.lastActivityISO8601) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
            }
        }
    }

    static func records(
        for label: String,
        from records: [SessionRecord],
        metadata: [MatterMetadata] = []
    ) -> [SessionRecord] {
        guard let selectedLabel = canonicalLabel(label, metadata: metadata) else { return [] }
        return records
            .filter { record in
                guard let candidate = record.clientLabel else { return false }
                return canonicalLabel(candidate, metadata: metadata) == selectedLabel
            }
            .sorted {
                let left = recordActivityISO8601($0)
                let right = recordActivityISO8601($1)
                return (left, $0.id.uuidString) > (right, $1.id.uuidString)
            }
    }

    static func summaries(
        _ summaries: [MatterSummary],
        in scope: MatterWorkspaceScope
    ) -> [MatterSummary] {
        summaries.filter { summary in
            summary.isArchived == (scope == .archived)
        }
    }

    static func cleanedLabel(_ candidate: String) -> String? {
        let cleaned = candidate
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return cleaned.isEmpty ? nil : cleaned
    }

    static func recordActivityISO8601(_ record: SessionRecord) -> String {
        record.restoreEvents.reduce(record.createdAtISO8601) {
            max($0, $1.atISO8601)
        }
    }

    private static func storedLabel(_ candidate: String) -> String? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func canonicalLabel(
        _ candidate: String,
        metadata: [MatterMetadata]
    ) -> String? {
        guard let label = storedLabel(candidate) else { return nil }
        guard let item = metadata.first(where: { item in
            storedLabel(item.label) == label
                || item.aliases.contains { storedLabel($0) == label }
        }) else {
            return label
        }
        return storedLabel(item.label)
    }

    private static func isArchived(
        _ label: String,
        metadata: [MatterMetadata]
    ) -> Bool {
        metadata.first {
            storedLabel($0.label) == label
        }?.isArchived ?? false
    }

    private static func emptySummary(
        label: String,
        isArchived: Bool
    ) -> MatterSummary {
        MatterSummary(
            id: label,
            label: label,
            sessionCount: 0,
            documentCount: 0,
            protectedValueCount: 0,
            restoreCount: 0,
            flaggedCount: 0,
            lastActivityISO8601: nil,
            isArchived: isArchived
        )
    }

    private static func maxISO8601(_ lhs: String?, _ rhs: String) -> String {
        guard let lhs else { return rhs }
        return max(lhs, rhs)
    }
}
