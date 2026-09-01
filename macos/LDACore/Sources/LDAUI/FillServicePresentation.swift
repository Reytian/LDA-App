//
//  FillServicePresentation.swift
//  LDAUI
//
//  Localized display copy for stable fill-service values. The service's raw
//  strings remain unchanged because they are used by reports, CLI output, and
//  stored portfolio provenance.
//

import Foundation
import LDACore

struct FillSourceFailure: Equatable, Sendable {
    let name: String
    let reason: String
}

enum FillServicePresentation {
    static func skippedReason(
        _ rawReason: String,
        language: AppLanguage? = nil
    ) -> String {
        let key: String
        switch rawReason {
        case "duplicate location":
            key = "Duplicate field location"
        case "confirmed without a value":
            key = "Confirmed without a value"
        case "rejected by reviewer":
            key = "Rejected during review"
        case "no matching field":
            key = "No matching portfolio field"
        case "not confirmed":
            key = "Not confirmed"
        case "manual widget type":
            key = "Requires manual input"
        default:
            return rawReason
        }
        return L10n.string(key, language: language)
    }

    static func sourceDocumentName(
        for field: ProfileField,
        language: AppLanguage? = nil
    ) -> String {
        let isSyntheticManualEntry = field.sourceDocument == "manual entry"
            && field.sourceSnippet.isEmpty
            && !field.snippetVerified
            && field.userEdited
        guard isSyntheticManualEntry else { return field.sourceDocument }
        return L10n.string("Manual entry", language: language)
    }

    static func sourceFailureReason(
        _ rawReason: String,
        language: AppLanguage? = nil
    ) -> String {
        guard rawReason == "no text content found" else { return rawReason }
        return L10n.string("No text content found", language: language)
    }

    static func sourceWarning(
        _ failure: FillSourceFailure,
        language: AppLanguage? = nil
    ) -> String {
        let reason = sourceFailureReason(failure.reason, language: language)
        return "\(failure.name): \(reason)"
    }

    static func locationDescription(
        _ rawDescription: String,
        language: AppLanguage? = nil
    ) -> String {
        let key: String
        let value: String
        if rawDescription.hasPrefix("field ") {
            key = "Field %@"
            value = String(rawDescription.dropFirst("field ".count))
        } else if rawDescription.hasPrefix("offset ") {
            key = "Offset %@"
            value = String(rawDescription.dropFirst("offset ".count))
        } else {
            return rawDescription
        }

        return String(
            format: L10n.string(key, language: language),
            value as NSString
        )
    }
}

enum FillTargetPresentation {
    static func contextList(
        targetFileName: String?,
        blanks: [Blank],
        language: AppLanguage? = nil
    ) -> String {
        guard let targetFileName else {
            return L10n.string("No target document loaded.", language: language)
        }

        let body: String
        if blanks.isEmpty {
            body = L10n.string(
                "No blanks detected in this document.",
                language: language
            )
        } else {
            body = blanks.map { blank in
                let label = blank.label.isEmpty
                    ? L10n.string("(blank)", language: language)
                    : blank.label
                return "\(label): \(blank.context)"
            }.joined(separator: "\n\n")
        }

        return "\(targetFileName)\n\n\(body)"
    }
}
