//
//  EntityTypePresentation.swift
//  LDAUI
//
//  Localized display names for stable entity wire types.
//

import SwiftUI
import LDACore

enum EntityTypePresentation {
    static func key(for type: EntityType) -> String {
        switch type {
        case .person: return "Person"
        case .company: return "Company"
        case .address: return "Address"
        case .email: return "Email"
        case .phone: return "Phone"
        case .bankAccount: return "Bank account"
        case .nationalID: return "National ID"
        case .uscc: return "Unified Social Credit Code"
        case .date: return "Date"
        case .amount: return "Amount"
        case .caseNumber: return "Case number"
        case .licensePlate: return "License plate"
        case .wechatID: return "WeChat ID"
        case .url: return "URL"
        case .seal: return "Seal"
        case .unknown: return "Unknown"
        }
    }

    static func localizedKey(for type: EntityType) -> LocalizedStringKey {
        LocalizedStringKey(key(for: type))
    }

    static func localizedName(
        for type: EntityType,
        language: AppLanguage? = nil
    ) -> String {
        L10n.string(key(for: type), language: language)
    }

    /// The detection source as a short, lawyer-facing label. Deterministic
    /// detections are regex matches; the rest carry their own names. Shared by
    /// the sidebar caption and the document highlight tooltip.
    static func sourceLabel(for source: DetectionSource) -> String {
        switch source {
        case .deterministic:
            return L10n.string("regex")
        case .llm:
            return L10n.string("LLM")
        case .manual:
            return L10n.string("manual")
        }
    }

    static func bulkActionHelp(for type: EntityType) -> String {
        String(
            format: L10n.string("Redact or keep every %@ value at once"),
            localizedName(for: type) as NSString
        )
    }
}
