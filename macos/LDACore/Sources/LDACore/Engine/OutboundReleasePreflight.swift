//
//  OutboundReleasePreflight.swift
//  LDACore
//
//  One fail-closed release gate for lossy asterisk masks. It asks Restorer to
//  judge the exact bytes about to leave, so copy, export, CLI, and MCP paths
//  cannot drift from the verdict the user would otherwise discover only when
//  the reply came back.
//
//  House rules: English only. No em-dash and no en-dash-as-separator.
//

import Foundation

/// A redacted output that cannot be restored without guessing must not leave
/// the app under the reversible round-trip workflow.
public enum OutboundReleaseError: LocalizedError, Equatable, Sendable {
    case ambiguousAsteriskMasks([String])

    public var errorDescription: String? {
        switch self {
        case .ambiguousAsteriskMasks(let masks):
            return "The asterisk output is ambiguous for these masks: "
                + masks.joined(separator: ", ")
                + ". Switch to Tokens or Pseudonyms before copying or exporting."
        }
    }
}

/// Runs the restore engine over outbound text before any state or artifact is
/// published. Only asterisk style needs this gate: token and pseudonym output
/// have repairable, unique replacements at release time.
public enum OutboundReleasePreflight {

    public static func requireSafe(text: String, mapping: Mapping) throws {
        try requireSafe(texts: [text], mapping: mapping)
    }

    public static func requireSafe(texts: [String], mapping: Mapping) throws {
        guard mapping.style == .asterisk else { return }

        var seen: Set<String> = []
        var ambiguous: [String] = []
        for text in texts {
            let report = Restorer.restore(text: text, mapping: mapping)
            for replacement in report.ambiguousReplacements
            where seen.insert(replacement).inserted {
                ambiguous.append(replacement)
            }
        }
        guard ambiguous.isEmpty else {
            throw OutboundReleaseError.ambiguousAsteriskMasks(ambiguous.sorted())
        }
    }
}
