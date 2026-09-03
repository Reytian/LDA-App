//
//  MCPToolCatalog.swift
//  LDAMCP
//
//  The advertised tool surface, declared once so tools/list and the dispatcher
//  cannot drift.
//
//  Three tiers:
//
//   - Vault tools: the handle-first surface, always advertised. No filesystem
//     path enters or leaves them except modelPath (a GGUF the human
//     configured, still gated by MCPPathPolicy).
//   - Legacy gated tools (extract_profile, fill, portfolio_list,
//     portfolio_show): they take paths and their results cross the context
//     boundary (fill plans carry client field labels, portfolio summaries
//     carry client labels). They are hidden from tools/list and refused by
//     dispatch unless the server was LAUNCHED with LDA_MCP_LEGACY_PATH_TOOLS=1.
//     The gate is an environment variable set by whoever starts the process,
//     never a request parameter: a boundary a request can widen is not a
//     boundary.
//   - Removed tools (anonymize_document, restore_document): the old path-based
//     core tools. Their replacements are the handle-based anonymize and
//     restore; calling the old names returns a migration message.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import LDACore

extension MCPServer {

    // MARK: - Tool name tiers

    /// The handle-first tools, in advertisement order.
    static let vaultToolNames: [String] = [
        "list_pending",
        "anonymize",
        "anonymize_session",
        "read_redacted",
        "detect_entities",
        "restore",
        "export",
        "attest"
    ]

    /// Path-taking tools that survive only behind the launch-time opt-in.
    static let legacyGatedToolNames: Set<String> = [
        "extract_profile",
        "fill",
        "portfolio_list",
        "portfolio_show"
    ]

    /// Old core tools whose signatures were replaced by the handle flow.
    static let removedToolNames: Set<String> = [
        "anonymize_document",
        "restore_document"
    ]

    /// The environment variable that re-enables the legacy path tools.
    public static let legacyPathToolsEnvironmentKey = "LDA_MCP_LEGACY_PATH_TOOLS"

    /// The refusal returned for a legacy tool while the gate is closed.
    static func legacyGatedToolMessage(_ name: String) -> String {
        "Tool \(name) is disabled pending a handle-based redesign: its arguments "
            + "or results cross the context boundary (file paths, client labels, "
            + "or field values). Launch the server with "
            + "\(legacyPathToolsEnvironmentKey)=1 to temporarily re-enable the "
            + "legacy path tools."
    }

    /// The migration message returned for a removed core tool. Staging is
    /// phrased as the USER's action on purpose: an agent that runs the CLI
    /// itself would be handling the path this design keeps out of context.
    static func removedToolMessage(_ name: String) -> String {
        let replacement = name == "anonymize_document" ? "anonymize" : "restore"
        return "Tool \(name) was removed: core tools now operate on vault handles "
            + "so file paths never enter the model context. Ask the user to stage "
            + "documents with the CLI (lda vault stage <path>), find them with "
            + "list_pending, and call \(replacement) with a handle."
    }

    // MARK: - Vault tool descriptors

    /// JSON-Schema descriptors for the handle-first surface.
    static let vaultToolDescriptors: [[String: Any]] = [
        [
            "name": "list_pending",
            "description": "List the staged documents and derived artifacts in the vault: opaque handles plus neutral metadata (kind, format, byte count, page count, staged-at, source handle, and for redacted artifacts excludedEntityCount: how many detected occurrences the review step left visible, on every channel; 0 means fully redacted). Never returns filenames or paths.",
            "inputSchema": [
                "type": "object",
                "properties": [String: Any](),
                "required": [String]()
            ]
        ],
        [
            "name": "anonymize",
            "description": "Detect and tokenize PII in a staged document (by handle), producing a redacted artifact with its own handle and an encrypted mapping sidecar kept inside the vault. Returns the redacted handle and aggregate counts only. Coverage: entityCount, entityTypes and perTypeCounts describe EVERYTHING replaced. For a .docx that includes the parts outside the main body (headers, footers, footnotes, endnotes, comments), which are always redacted; supplementaryEntityCount and supplementaryPerTypeCounts say how much of the total came from there. Those hits have no offsets and no ids, so they cannot be excluded. Review step: to leave chosen values visible, run detect_entities once, then pass its ids as excludeEntityIds together with its detectionId, and/or pass excludeTypes for whole types. Exclusion works by VALUE: whatever you leave visible stays visible at every occurrence in the document, headers, footers, notes and comments included, and is therefore not protected anywhere in it. The response reports excludedCount (occurrences now in clear, on every channel; expect it to exceed the number of ids you passed), excludedValueCount (how many distinct values those occurrences are), and detectionChanged (true when this run's detection differs from the reviewed one; the run still proceeds when every excluded id is present, since over-redaction is the safe direction).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "handle": ["type": "string", "description": "Handle of a staged original (doc_...)."],
                    "passphrase": ["type": "string", "description": "Optional passphrase to protect the mapping sidecar."],
                    "modelPath": ["type": "string", "description": "Optional path to a GGUF model to also detect PERSON/COMPANY/ADDRESS."],
                    "style": ["type": "string", "enum": ["token", "pseudonym", "asterisk"], "description": "Replacement style: token ({PERSON_1}, default), pseudonym (natural-language stand-ins that survive AI rewriting), or asterisk (masking for human recipients; restore refuses ambiguous masks)."],
                    "excludeEntityIds": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Ids from detect_entities for THIS handle whose VALUES must stay visible. Excluding one id keeps EVERY occurrence of that value visible in the whole document, headers, footers, notes, and comments included, not only the occurrence the id names: a value left in clear beside its own placeholder tells any reader what that placeholder stands for, at every other site. So a value you leave visible is NOT protected anywhere in that document. Other values, including other values of the same type, are unaffected. The response reports excludedCount, the number of occurrences now in clear, which is usually larger than the number of ids you passed. Requires detectionId. An id the fresh detection does not know, including any id from another document, is refused (unknown_entity_id) and nothing is written."
                    ],
                    "excludeTypes": [
                        "type": "array",
                        "items": ["type": "string", "enum": EntityType.allCases.map(\.rawValue)],
                        "description": "Entity types to leave visible everywhere (body, headers, footers, notes, comments, and the image channel), for example [\"DATE\", \"AMOUNT\"]. An unknown type is refused."
                    ],
                    "detectionId": [
                        "type": "string",
                        "description": "The detectionId returned by detect_entities together with the ids in excludeEntityIds. Required when excludeEntityIds is non-empty; optional otherwise (when given, detectionChanged reports whether this run saw a different set)."
                    ]
                ],
                "required": ["handle"]
            ]
        ],
        [
            "name": "anonymize_session",
            "description": "Anonymize several staged documents (by handle) as ONE session sharing ONE mapping: the same value keeps the same placeholder across the set. Each document gets its own redacted handle; the shared encrypted sidecar stays inside the vault. supplementaryEntityCount is always 0 here, unlike anonymize: this tool hands over redacted Markdown of each document's body, so a .docx header, footer, note, or comment is not carried over and not redacted; use anonymize per document when those parts matter. Optional excludeTypes leaves whole entity types visible in every document, at every occurrence (excludedCount reports how many occurrences that is). CHECK unresolvedSeams in the response: when it is non-empty, restoring puts a DIFFERENT party's real name at the listed sites, and the redacted output looks completely ordinary, so nothing later in the round trip will catch it.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "handles": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Handles of the session's staged originals (doc_...)."
                    ],
                    "passphrase": ["type": "string", "description": "Optional passphrase to protect the session mapping sidecar."],
                    "modelPath": ["type": "string", "description": "Optional path to a GGUF model to also detect PERSON/COMPANY/ADDRESS."],
                    "client": ["type": "string", "description": "Optional client profile label: the session reuses and extends that client's stored identities. The label is never echoed back."],
                    "style": ["type": "string", "enum": ["token", "pseudonym", "asterisk"], "description": "Replacement style: token ({PERSON_1}, default), pseudonym (natural-language stand-ins that survive AI rewriting), or asterisk (masking for human recipients; restore refuses ambiguous masks)."],
                    "excludeTypes": [
                        "type": "array",
                        "items": ["type": "string", "enum": EntityType.allCases.map(\.rawValue)],
                        "description": "Entity types to leave visible in every document of the session, for example [\"DATE\"]: every occurrence of those types, in every part of every document, stays in clear and is protected nowhere in the session. Per-entity ids are single-document by construction, so excludeEntityIds is not accepted here: call anonymize per document to exclude by id."
                    ]
                ],
                "required": ["handles"]
            ]
        ],
        [
            "name": "read_redacted",
            "description": "Return the redacted TEXT of a redacted artifact. This is the only tool that returns body text, and it refuses originals and restored artifacts (both contain real PII).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "handle": ["type": "string", "description": "Handle of a redacted artifact (red_...)."]
                ],
                "required": ["handle"]
            ]
        ],
        [
            "name": "detect_entities",
            "description": "Detect PII entities in a staged document (by handle) without writing anything. Returns entity types, counts, character offsets, a per-entity id (derived from the handle, type, and offsets, so it is never valid for another document), and a detectionId for the whole set; the detected text itself never leaves the machine. Read entityCount and the entities list as two different things: the list is the BODY, while entityCount also covers what a run would redact in a .docx header, footer, footnote, endnote, or comment, reported as supplementaryEntityCount and supplementaryPerTypeCounts. Those hits have no body offsets, so they get no ids and cannot be excluded; entityCount larger than entities.length means those parts carry PII and it WILL be redacted, not that anything leaked. This is the review step: read the list, then call anonymize with excludeEntityIds plus this detectionId (and/or excludeTypes) to leave chosen values visible. One id names ONE occurrence, but excluding it leaves every occurrence of that same value visible in the document, so repeated values need only one of their ids. Run it once per document; anonymize detects again on its own and reports detectionChanged if the set moved.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "handle": ["type": "string", "description": "Handle of a vault document."],
                    "modelPath": ["type": "string", "description": "Optional path to a GGUF model to also detect PERSON/COMPANY/ADDRESS."]
                ],
                "required": ["handle"]
            ]
        ],
        [
            "name": "restore",
            "description": "Restore placeholders back to their original values using a redacted artifact's encrypted mapping. Three shapes: (1) omit editedText and editedHandle to restore the stored redacted artifact as-is (a .docx keeps its formatting); (2) pass editedText with the (possibly AI-edited) redacted TEXT to restore that: the result is TEXT (format txt) even when the redacted artifact was a .docx, so Word formatting is NOT kept on this path; (3) pass editedHandle, the handle of the EDITED redacted document that came back, to restore it with redactedHandle's mapping: a .docx keeps its formatting. To keep Word formatting end to end: export the redacted .docx, have the human edit that file itself (accept all tracked changes before staging), stage it with `lda vault stage <file>`, and pass its doc_... handle as editedHandle. Every response reports format (docx, txt, or md), restoredCount, orphanTokens, suspectPlaceholderCount, ambiguousReplacements, and suspectPlaceholders (the strings only when the restored surface's text is already known to you: the stored artifact, editedText, or a redacted artifact of this mapping; a human-staged file reports the count only). The restored artifact STAYS in the vault (it contains real PII); use export to hand it to the human.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "redactedHandle": ["type": "string", "description": "Handle of the redacted artifact whose mapping to use (red_...)."],
                    "editedText": ["type": "string", "description": "Optional edited redacted TEXT to restore; it is written into the vault as its own artifact first. Restores to text (format txt): formatting is not kept on this path. Mutually exclusive with editedHandle."],
                    "editedHandle": ["type": "string", "description": "Optional handle of the EDITED redacted document that came back (a doc_... the human staged with `lda vault stage <file>`, or a red_... artifact). Restored with redactedHandle's mapping; a .docx keeps its formatting, text and Markdown restore as text. Restored artifacts (res_...), images, and PDFs are refused; so is an original that holds no placeholder of this mapping (no_placeholders_found, nothing is written) and a redacted artifact of another mapping (mapping_mismatch). Mutually exclusive with editedText."],
                    "passphrase": ["type": "string", "description": "Optional passphrase that protects the mapping sidecar."]
                ],
                "required": ["redactedHandle"]
            ]
        ],
        [
            "name": "export",
            "description": "Copy a redacted or restored artifact to the vault's outbox, a fixed location the human knows. Originals are refused. The response contains no path.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "handle": ["type": "string", "description": "Handle of a redacted or restored artifact."]
                ],
                "required": ["handle"]
            ]
        ],
        [
            "name": "attest",
            "description": "Report the server's current data-boundary posture: whether the vault encrypts at rest, how the vault master key is protected, the Keychain ACL mode, byte counters for what this session has returned (plaintext, always zero; redacted; and the subset of redacted bytes that came from partially redacted artifacts, which carry values the caller chose to leave visible), and per-tool call counts.",
            "inputSchema": [
                "type": "object",
                "properties": [String: Any](),
                "required": [String]()
            ]
        ]
    ]

    // MARK: - Legacy gated tool descriptors

    /// Descriptors for the gated tools, advertised only when the launch
    /// environment opted in.
    static let legacyToolDescriptors: [[String: Any]] = [
        [
            "name": "extract_profile",
            "description": "LEGACY (path-based, gated by LDA_MCP_LEGACY_PATH_TOOLS): build an encrypted ClientPortfolio from source documents and save it to disk. Returns a value-free summary (field count, keys, conflicts); no field values are included in the response.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "sources": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "One or more source document paths (DOCX, PDF, or TXT) to extract profile fields from."
                    ],
                    "label": ["type": "string", "description": "Short human label for the resulting profile."],
                    "out": ["type": "string", "description": "Destination path for the encrypted .ldaprofile file."],
                    "model": ["type": "string", "description": "Absolute path to the v2 GGUF model. Required for profile extraction."],
                    "passphrase": ["type": "string", "description": "Optional passphrase to protect the profile. Omit to use a per-profile Keychain key."],
                    "kind": ["type": "string", "enum": ["company", "individual", "general"], "description": "Portfolio kind: company (default), individual, or general. Controls which keys the model is prompted to extract."]
                ],
                "required": ["sources", "label", "out", "model"]
            ]
        ],
        [
            "name": "fill",
            "description": "LEGACY (path-based, gated by LDA_MCP_LEGACY_PATH_TOOLS): fill blanks in a document from a ClientPortfolio. Exactly one of profile (path to a .ldaprofile file) or portfolio (library entry by name or UUID) must be supplied; they are mutually exclusive. passphrase is only valid with profile; portfolio always uses the library Keychain key. mode=plan returns the fill plan for review. mode=apply writes the filled document and returns a value-free report.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "profile": ["type": "string", "description": "Path to an encrypted .ldaprofile file. Mutually exclusive with portfolio."],
                    "portfolio": ["type": "string", "description": "Portfolio library entry by label or UUID. Mutually exclusive with profile. Cannot be combined with passphrase."],
                    "input": ["type": "string", "description": "Path to the fill target (.docx or .pdf)."],
                    "mode": [
                        "type": "string",
                        "enum": ["plan", "apply"],
                        "description": "plan: return the fill plan for review. apply: promote proposed blanks and write the filled document."
                    ],
                    "model": ["type": "string", "description": "Optional path to the v2 GGUF model for unmatched blanks."],
                    "passphrase": ["type": "string", "description": "Optional passphrase protecting the profile. Only valid when using the profile parameter."],
                    "output_dir": ["type": "string", "description": "Directory to write the filled document. Required when mode is apply."]
                ],
                "required": ["input", "mode"]
            ]
        ],
        [
            "name": "portfolio_list",
            "description": "LEGACY (gated by LDA_MCP_LEGACY_PATH_TOOLS): list all portfolios in the library. Returns a value-free sorted array of summaries (id, label, kind, dates, fieldCount, conflicted). No field values are included.",
            "inputSchema": [
                "type": "object",
                "properties": [String: Any](),
                "required": [String]()
            ]
        ],
        [
            "name": "portfolio_show",
            "description": "LEGACY (gated by LDA_MCP_LEGACY_PATH_TOOLS): show one portfolio's value-free detail: summary fields plus rawKeys and conflictedKeys. No field values are included. Identified by UUID or label (case-insensitive, must be unique).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "portfolio": ["type": "string", "description": "Portfolio UUID or label (case-insensitive, must be unique)."]
                ],
                "required": ["portfolio"]
            ]
        ]
    ]
}
