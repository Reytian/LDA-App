//
//  ComplianceReport.swift
//  LDACore
//
//  The exportable compliance processing report: a Markdown deliverable a
//  lawyer can hand over to show what was processed, when, and how it was
//  verified.
//
//  Leak safety BY CONSTRUCTION: the only inputs are a SessionRecord and
//  caller-supplied scalars. A SessionRecord never holds entity plaintext or
//  mapping values (see SessionRecordStore), so the report cannot contain
//  them. Do not widen this surface with mappings, spans, or document text.
//
//  Claims discipline: the boundary section states only facts aligned with
//  docs/positioning-claims.md. Absolute claims ("100 percent", "zero upload",
//  guarantees) are forbidden and enforced by test.
//
//  Pure: no clock reads, no I/O. The caller supplies the generation
//  timestamp, like PdfTextNormalizer and the Mapping constructors.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere, including the generated Markdown.
//

import Foundation

public enum ComplianceReport {

    // MARK: - Named constants

    /// Rendered wherever an optional record field is absent.
    static let notRecordedField = "not recorded"
    /// Rendered when the record predates scan-side verification counts.
    static let scanVerificationAbsentLine = "Not recorded."
    /// Rendered when no restore ran against the session mapping.
    static let noRestoreLine = "No restore has been recorded for this session."
    /// Rendered when the record holds no documents.
    static let noDocumentsLine = "No documents were recorded."

    // MARK: - Entry point

    /// Renders one session record as a Markdown compliance report.
    ///
    /// Pure: the caller supplies the generation timestamp; the function never
    /// reads the clock. The inputs are the record and that scalar only, so
    /// the output can hold nothing but what the record holds.
    public static func markdown(record: SessionRecord, generatedAtISO8601: String) -> String {
        var lines: [String] = []
        lines.append("# Anonymization Processing Report")
        lines.append("")
        lines.append(
            "Generated at \(inlineText(generatedAtISO8601)) by LDA (Legal Document Anonymizer)."
        )
        lines.append("")
        lines.append(contentsOf: sessionLines(record))
        lines.append("")
        lines.append(contentsOf: documentLines(record.documents))
        lines.append("")
        lines.append(contentsOf: verificationLines(record))
        lines.append("")
        lines.append(contentsOf: boundaryLines())
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Sections

    private static func sessionLines(_ record: SessionRecord) -> [String] {
        [
            "## Session",
            "",
            "| Field | Value |",
            "| --- | --- |",
            "| Session ID | \(cell(record.id.uuidString)) |",
            "| Session created | \(cell(record.createdAtISO8601)) |",
            "| Client label | \(cell(record.clientLabel ?? notRecordedField)) |",
            "| App version | \(cell(record.appVersion ?? notRecordedField)) |",
            "| Detection model | \(cell(record.modelName ?? notRecordedField)) |",
            "| Substitution style | \(styleCell(record.substitutionStyle)) |",
            "| Distinct protected identities | \(record.protectedValueCount) |"
        ]
    }

    private static func documentLines(_ documents: [SessionRecordDocument]) -> [String] {
        var lines = ["## Documents", ""]
        guard !documents.isEmpty else {
            lines.append(noDocumentsLine)
            return lines
        }
        lines.append("| Document | Protected entities | Entity types |")
        lines.append("| --- | --- | --- |")
        for document in documents {
            lines.append(
                "| \(cell(document.name)) | \(document.entityCount) | \(typesCell(document)) |"
            )
        }
        return lines
    }

    private static func verificationLines(_ record: SessionRecord) -> [String] {
        var lines = ["## Verification", "", "### Scan verification", ""]
        if let scan = record.scanVerification {
            lines.append("| Check | Count |")
            lines.append("| --- | --- |")
            lines.append("| Literal rescan hits | \(scan.rescanHitCount) |")
            lines.append("| Open cross-document rescan warnings | \(scan.rescanWarningCount) |")
            lines.append("| Placeholder forensics suspects | \(scan.forensicsSuspectCount) |")
        } else {
            lines.append(scanVerificationAbsentLine)
        }
        lines.append("")
        lines.append("### Restore events")
        lines.append("")
        if record.restoreEvents.isEmpty {
            lines.append(noRestoreLine)
        } else {
            lines.append(
                "| Restored at | Restored | Orphan placeholders | Suspect placeholders"
                    + " | Unattributable masks |"
            )
            lines.append("| --- | --- | --- | --- | --- |")
            for event in record.restoreEvents {
                lines.append(
                    "| \(cell(event.atISO8601)) | \(event.restoredCount)"
                        + " | \(event.orphanCount) | \(event.suspectCount)"
                        + " | \(event.ambiguousCount) |"
                )
            }
        }
        return lines
    }

    /// The factual boundary statement. Every sentence tracks a claim from
    /// docs/positioning-claims.md; never add an absolute claim here.
    private static func boundaryLines() -> [String] {
        [
            "## Scope and boundary",
            "",
            "This report was generated from the encrypted session record LDA keeps"
                + " on this Mac. The record stores counts, entity types, document names,"
                + " and timestamps. It does not store the protected values or the"
                + " replacement mapping, so this report cannot reproduce them.",
            "",
            "Documents were processed on this device. The app's document pipeline"
                + " carries no network entitlement; the only network capability in the"
                + " app is the optional model download. Session records and mappings are"
                + " encrypted at rest with keys held in the macOS Keychain.",
            "",
            "Automated detection is fallible and the workflow includes a human"
                + " review step. This report documents what was recorded for this"
                + " session. It is not legal advice and does not replace a lawyer's"
                + " compliance judgment."
        ]
    }

    // MARK: - Cell rendering

    /// Escapes one Markdown table cell: record strings are data, never
    /// markup, so pipes are escaped and line breaks collapse to spaces.
    private static func cell(_ raw: String) -> String {
        inlineText(raw).replacingOccurrences(of: "|", with: "\\|")
    }

    /// Collapses line breaks so a value cannot break out of its line.
    private static func inlineText(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private static func styleCell(_ style: SubstitutionStyle?) -> String {
        guard let style else { return notRecordedField }
        switch style {
        case .token: return "Opaque tokens"
        case .pseudonym: return "Natural language pseudonyms"
        case .asterisk: return "Asterisk masks"
        }
    }

    /// Per-type counts when the record carries them, in the record's own
    /// type order (unknown keys sorted last); the distinct type list
    /// otherwise.
    private static func typesCell(_ document: SessionRecordDocument) -> String {
        guard let counts = document.entityCountsByType else {
            return cell(document.entityTypes.joined(separator: ", "))
        }
        var ordered = document.entityTypes.filter { counts[$0] != nil }
        let extras = counts.keys
            .filter { !document.entityTypes.contains($0) }
            .sorted()
        ordered.append(contentsOf: extras)
        let rendered = ordered
            .compactMap { type in counts[type].map { "\(type): \($0)" } }
            .joined(separator: ", ")
        return cell(rendered)
    }
}
