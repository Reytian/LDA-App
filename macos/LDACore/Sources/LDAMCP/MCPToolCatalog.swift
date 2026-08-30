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

    /// The migration message returned for a removed core tool.
    static func removedToolMessage(_ name: String) -> String {
        let replacement = name == "anonymize_document" ? "anonymize" : "restore"
        return "Tool \(name) was removed: core tools now operate on vault handles "
            + "so file paths never enter the model context. Stage documents with "
            + "the CLI (lda vault stage <path>), find them with list_pending, and "
            + "call \(replacement) with a handle."
    }

    // MARK: - Vault tool descriptors

    /// JSON-Schema descriptors for the handle-first surface.
    static let vaultToolDescriptors: [[String: Any]] = [
        [
            "name": "list_pending",
            "description": "List the staged documents and derived artifacts in the vault: opaque handles plus neutral metadata (kind, format, byte count, page count, staged-at). Never returns filenames or paths.",
            "inputSchema": [
                "type": "object",
                "properties": [String: Any](),
                "required": [String]()
            ]
        ],
        [
            "name": "anonymize",
            "description": "Detect and tokenize PII in a staged document (by handle), producing a redacted artifact with its own handle and an encrypted mapping sidecar kept inside the vault. Returns the redacted handle and aggregate counts only.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "handle": ["type": "string", "description": "Handle of a staged original (doc_...)."],
                    "passphrase": ["type": "string", "description": "Optional passphrase to protect the mapping sidecar."],
                    "modelPath": ["type": "string", "description": "Optional path to a GGUF model to also detect PERSON/COMPANY/ADDRESS."]
                ],
                "required": ["handle"]
            ]
        ],
        [
            "name": "anonymize_session",
            "description": "Anonymize several staged documents (by handle) as ONE session sharing ONE mapping: the same value keeps the same placeholder across the set. Each document gets its own redacted handle; the shared encrypted sidecar stays inside the vault.",
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
                    "client": ["type": "string", "description": "Optional client profile label: the session reuses and extends that client's stored identities. The label is never echoed back."]
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
            "description": "Detect PII entities in a staged document (by handle) without writing anything. Returns entity types, counts, and character offsets only; the detected text itself never leaves the machine.",
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
            "description": "Restore placeholder tokens back to their original values using a redacted artifact's encrypted mapping. Pass editedText with the (possibly AI-edited) redacted text to restore that; omit it to restore the stored artifact as-is. The restored artifact STAYS in the vault (it contains real PII); use export to hand it to the human.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "redactedHandle": ["type": "string", "description": "Handle of the redacted artifact whose mapping to use (red_...)."],
                    "editedText": ["type": "string", "description": "Optional edited redacted text to restore; it is written into the vault as its own artifact first."],
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
            "description": "Report the server's current data-boundary posture: whether the vault encrypts at rest, the Keychain ACL mode, byte counters for what this session has returned, and per-tool call counts.",
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
