//
//  EntityTypePresentation.swift
//  LDAUI
//
//  Localized display names for stable entity wire types.
//

import AppKit
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

    /// A small filled circle in the type hue, for menu rows (menus render
    /// images, not shapes). The color resolves at draw time, so the image
    /// follows the appearance.
    static func dotImage(for type: EntityType) -> NSImage {
        if let cached = dotImages[type] { return cached }
        let color = CounselTheme.entityNSColor(for: type)
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        dotImages[type] = image
        return image
    }

    private static var dotImages: [EntityType: NSImage] = [:]
}

/// The two bulk decisions for a type ("Redact All Person" / "Keep All Person
/// Visible"), shared by the sidebar section header and the pane legend.
struct EntityTypeBulkActions: View {
    let type: EntityType
    let onSetAllAccepted: (Bool) -> Void

    var body: some View {
        Button(String(
            format: L10n.string("Redact All %@"),
            EntityTypePresentation.localizedName(for: type) as NSString
        )) { onSetAllAccepted(true) }
        Button(String(
            format: L10n.string("Keep All %@ Visible"),
            EntityTypePresentation.localizedName(for: type) as NSString
        )) { onSetAllAccepted(false) }
    }
}
