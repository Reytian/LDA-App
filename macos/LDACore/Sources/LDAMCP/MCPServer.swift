//
//  MCPServer.swift
//  LDAMCP
//
//  A Model Context Protocol (MCP) server over LDAService, speaking JSON-RPC 2.0
//  on stdio. This is the edge an MCP client (an agent host) connects to in order
//  to drive anonymize / restore / detect as tools.
//
//  Transport note (LOCAL, not network): this server speaks newline-delimited
//  JSON-RPC 2.0 over stdin/stdout only. It opens no sockets and makes no network
//  calls. The app itself now has an outbound entitlement for model downloads,
//  but this server is not part of that path and must never gain one. An
//  MCP host launches this process and pipes requests to it on stdin; responses
//  come back on stdout. Nothing leaves the machine.
//
//  Structure for testability: the core is a PURE function, handle(_:), that maps
//  one raw JSON-RPC request payload to one raw response payload (or nil for a
//  notification). It performs no stdio of its own, so it is fully unit-testable.
//  runStdioLoop() is the thin imperative shell that wires handle(_:) to stdin and
//  stdout.
//
//  Clock ownership: LDAService is clock-free by contract. This edge stamps the
//  ISO-8601 createdAt with Date() at the tools/call boundary so the facade stays
//  deterministic.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import Security
import LDACore

// MARK: - MCPServer

/// A stdio JSON-RPC MCP server exposing LDAService operations as tools.
///
/// The transport is local only: newline-delimited JSON-RPC 2.0 over stdin and
/// stdout. There is no network listener, which keeps the offline posture intact.
public struct MCPServer {

    // MARK: Protocol constants

    /// The MCP protocol version this server implements.
    public static let protocolVersion = "2024-11-05"

    /// The advertised server name.
    public static let serverName = "lda-mcp"

    /// The advertised server version.
    public static let serverVersion = "1.0.0"

    /// Maximum bytes accepted for a single JSON-RPC line on stdin.
    ///
    /// The stdio loop accumulates bytes until it sees a newline, so a client
    /// that never sends one would otherwise grow the buffer without bound. 10 MB
    /// is far above any legitimate request (paths and options, never document
    /// bytes) and far below a memory problem.
    public static let maxRequestLineBytes = 10 * 1024 * 1024

    public init() {}

    // MARK: - Pure request handler

    /// The pure request handler: maps one raw JSON-RPC request payload to one raw
    /// JSON-RPC response payload. Pure so it can be unit-tested without any stdio.
    /// Returns nil for notifications (requests without an id), which take no
    /// response.
    ///
    /// - Parameter requestJSON: a single JSON-RPC 2.0 request object, encoded.
    /// - Returns: the encoded JSON-RPC 2.0 response, or nil for notifications.
    public func handle(_ requestJSON: Data) -> Data? {
        // A request that does not even parse as a JSON object is a parse error.
        // Per JSON-RPC 2.0 a parse error has a null id.
        guard
            let object = try? JSONSerialization.jsonObject(with: requestJSON),
            let request = object as? [String: Any]
        else {
            return encode(errorWithId: .null, code: parseError, message: "Parse error")
        }

        // Extract the id. Its absence means this is a notification, which takes no
        // response at all. A present id may be a number or a string.
        let hasId = request.keys.contains("id")
        let id = RequestID(jsonValue: request["id"])

        guard let method = request["method"] as? String else {
            if !hasId {
                return nil
            }
            return encode(errorWithId: id, code: invalidRequest, message: "Missing method")
        }

        // Notifications (no id) are dispatched for side effects only and never get
        // a response, regardless of method.
        if !hasId {
            return nil
        }

        let params = request["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            return handleInitialize(id: id)
        case "tools/list":
            return handleToolsList(id: id)
        case "tools/call":
            return handleToolsCall(id: id, params: params)
        case "ping":
            return encode(resultWithId: id, result: [:])
        default:
            return encode(
                errorWithId: id,
                code: methodNotFound,
                message: "Method not found: \(method)"
            )
        }
    }

    // MARK: - Method handlers

    /// initialize handshake: advertise protocol version, server info, and the
    /// (empty) tools capability object.
    private func handleInitialize(id: RequestID) -> Data? {
        let result: [String: Any] = [
            "protocolVersion": MCPServer.protocolVersion,
            "serverInfo": [
                "name": MCPServer.serverName,
                "version": MCPServer.serverVersion
            ],
            "capabilities": [
                "tools": [String: Any]()
            ]
        ]
        return encode(resultWithId: id, result: result)
    }

    /// tools/list: advertise the three tools and their JSON-Schema input schemas.
    private func handleToolsList(id: RequestID) -> Data? {
        let result: [String: Any] = ["tools": MCPServer.toolDescriptors]
        return encode(resultWithId: id, result: result)
    }

    /// tools/call: dispatch by tool name to LDAService, returning a content array
    /// holding one text block with a JSON summary. Any thrown error is reported as
    /// an isError result rather than crashing the process.
    private func handleToolsCall(id: RequestID, params: [String: Any]) -> Data? {
        guard let name = params["name"] as? String else {
            return encode(
                errorWithId: id,
                code: invalidParams,
                message: "tools/call requires a tool name"
            )
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]

        do {
            let summary: [String: Any]
            switch name {
            case "anonymize_document":
                summary = try callAnonymize(arguments)
            case "anonymize_session":
                summary = try callAnonymizeSession(arguments)
            case "restore_document":
                summary = try callRestore(arguments)
            case "detect_entities":
                summary = try callDetect(arguments)
            case "extract_profile":
                summary = try callExtractProfile(arguments)
            case "fill":
                summary = try callFill(arguments)
            case "portfolio_list":
                summary = try callPortfolioList(arguments)
            case "portfolio_show":
                summary = try callPortfolioShow(arguments)
            default:
                return toolErrorResult(id: id, message: "Unknown tool: \(name)")
            }
            return toolTextResult(id: id, summary: summary)
        } catch {
            // Never crash the loop on a tool failure; surface it as an isError
            // tools/call result so the client can recover.
            return toolErrorResult(id: id, message: describe(error))
        }
    }

    // MARK: - Tool implementations

    /// anonymize_document: run LDAService.anonymize and summarize the artifacts.
    private func callAnonymize(_ arguments: [String: Any]) throws -> [String: Any] {
        let input = try requireURL(arguments, key: "input")
        let outputDir = try requireURL(arguments, key: "outputDir")
        // The mapping sidecar is keyed by the redacted base name, which the
        // service derives as "<input base>_redacted".
        let mappingBase = input.deletingPathExtension().lastPathComponent + "_redacted"
        let protection = protectionMode(from: arguments, mappingBaseName: mappingBase)

        // The edge owns the clock: stamp createdAt with an ISO-8601 timestamp now.
        let createdAt = MCPServer.iso8601Now()

        let modelPath = try allowedModelPath(arguments, key: "modelPath")
        let result = try LDAService.anonymize(
            input: input,
            outputDir: outputDir,
            protection: protection,
            createdAtISO8601: createdAt,
            llmModelPath: modelPath
        )

        var summary: [String: Any] = [
            "redactedFile": result.redactedFileURL.path,
            "mappingFile": result.mappingFileURL.path,
            "entityCount": result.entityCount,
            "entityTypes": entityTypeStrings(result.entities),
            "imageRedactionCount": result.imageRedactionCount,
            "embeddedMediaCount": result.embeddedMediaCount,
            // Non-zero means the review PDF still SHOWS those values even though
            // the edit surface and mapping have them tokenized. The host must
            // relay this, not drop it.
            "unboxedTokenCount": result.unboxedTokenCount
        ]
        if let visual = result.visualPdfURL {
            summary["visualPdf"] = visual.path
        }
        return summary
    }

    /// restore_document: run LDAService.restore and summarize the output.
    private func callRestore(_ arguments: [String: Any]) throws -> [String: Any] {
        let editedRedacted = try requireURL(arguments, key: "editedRedacted")
        let mapping = try requireURL(arguments, key: "mapping")
        let output = try requireURL(arguments, key: "output")
        let mappingBase = mapping.deletingPathExtension().lastPathComponent
        let protection = protectionMode(from: arguments, mappingBaseName: mappingBase)

        let report: RestoreReport
        do {
            report = try LDAService.restore(
                editedRedacted: editedRedacted,
                mapping: mapping,
                protection: protection,
                output: output
            )
        } catch {
            // Sidecars written by older builds were all encrypted under one
            // shared Keychain account, so a MISSING per-document key is worth
            // one retry against the legacy account.
            //
            // Only that case. The retry used to fire on any error, which meant a
            // genuine decryptionFailed (wrong passphrase, tampered sidecar) was
            // re-attempted and then reported as whatever the second attempt
            // happened to fail with, hiding the real cause from the user. A
            // tampered mapping must surface as tampering.
            guard case .keychain = protection,
                  case DocumentIOError.keychainError(errSecItemNotFound) = error
            else {
                throw error
            }
            do {
                report = try LDAService.restore(
                    editedRedacted: editedRedacted,
                    mapping: mapping,
                    protection: .keychain(account: MCPServer.defaultKeychainAccount),
                    output: output
                )
            } catch let legacyError {
                // Report both: the per-document key was absent AND the legacy
                // account did not work either.
                throw MCPToolError.restoreFailedAfterLegacyRetry(
                    original: describe(error),
                    retry: describe(legacyError)
                )
            }
        }

        return [
            "output": report.outputURL.path,
            "restoredCount": report.restoredCount,
            "orphanTokens": report.orphanTokens,
            "suspectPlaceholders": report.suspectPlaceholders
        ]
    }

    /// detect_entities: run LDAService.detect and summarize the detected spans.
    ///
    /// Context boundary rule: the response carries entity TYPES and OFFSETS
    /// only, never span.text. Everything a tool returns enters the model
    /// context of whatever agent host launched this server, so returning the
    /// detected surface text (a name, an ID number, an account number) would
    /// upload the exact bytes this product exists to keep on the machine. A
    /// local caller can slice the document with the offsets; a remote model
    /// has no legitimate use for the plaintext.
    private func callDetect(_ arguments: [String: Any]) throws -> [String: Any] {
        let input = try requireURL(arguments, key: "input")
        let modelPath = try allowedModelPath(arguments, key: "modelPath")
        let spans = try LDAService.detect(input: input, llmModelPath: modelPath)

        let entities: [[String: Any]] = spans.map { span in
            [
                "type": span.type.rawValue,
                "start": span.start,
                "end": span.end
            ]
        }

        return [
            "entityCount": spans.count,
            "entityTypes": entityTypeStrings(spans),
            "entities": entities
        ]
    }

    // MARK: - Argument helpers

    /// Require a string argument and turn it into a file URL, throwing a readable
    /// error when it is missing or empty.
    private func requireURL(_ arguments: [String: Any], key: String) throws -> URL {
        guard let value = arguments[key] as? String, !value.isEmpty else {
            throw MCPToolError.missingArgument(key)
        }
        return try allowedURL(value, key: key)
    }

    /// Build a file URL from a path argument and enforce the path allow-list.
    ///
    /// Every path a REQUEST supplies for a document, a mapping, a profile, or an
    /// output goes through here. GGUF model paths go through allowedModelPath
    /// instead, whose allow-list adds the app bundle's Resources directory for
    /// distributed builds that read the model from inside the .app.
    ///
    /// Internal so the fill, session, and portfolio tool extensions use the same
    /// gate instead of constructing URLs directly.
    func allowedURL(_ path: String, key: String) throws -> URL {
        let url = URL(fileURLWithPath: path)
        try MCPPathPolicy.enforce(url, argumentKey: key)
        return url
    }

    /// Read an optional GGUF model path argument and enforce the model
    /// allow-list on it. Returns nil when the argument is absent or empty; a
    /// tool that requires the argument keeps its own missing-argument error.
    ///
    /// A model path is handed to llama.cpp rather than read back into a
    /// response, but a prompt-steered host could still stage a malicious GGUF
    /// in any writable location and point the engine at it, so model paths are
    /// enforced like every other path (with the bundle Resources directory as
    /// the one extra root).
    func allowedModelPath(_ arguments: [String: Any], key: String) throws -> String? {
        guard let value = arguments[key] as? String, !value.isEmpty else {
            return nil
        }
        try MCPPathPolicy.enforceModelPath(URL(fileURLWithPath: value), argumentKey: key)
        return value
    }

    /// Choose the mapping protection mode from the arguments. A passphrase, when
    /// present and non-empty, selects PBKDF2 passphrase protection; otherwise the
    /// server uses a Keychain account derived from the mapping base name, so a
    /// sidecar is always encrypted at rest and every document gets its OWN key
    /// (one shared key would be a single point of failure for every sidecar
    /// ever produced through this server).
    private func protectionMode(
        from arguments: [String: Any],
        mappingBaseName: String
    ) -> MappingProtection {
        if let passphrase = arguments["passphrase"] as? String, !passphrase.isEmpty {
            return .passphrase(passphrase)
        }
        return .keychain(account: MCPServer.keychainAccount(forMappingBaseName: mappingBaseName))
    }

    /// The per-document Keychain account for a mapping sidecar, derived from
    /// the sidecar's base file name.
    static func keychainAccount(forMappingBaseName base: String) -> String {
        "\(MCPServer.defaultKeychainAccount).\(base)"
    }

    /// The distinct entity-type wire strings present in a set of spans, in stable
    /// first-seen document order.
    private func entityTypeStrings(_ spans: [Span]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for span in spans {
            let raw = span.type.rawValue
            if seen.insert(raw).inserted {
                ordered.append(raw)
            }
        }
        return ordered
    }

    /// A human-readable description for any error surfaced from LDAService or
    /// the fill/portfolio tool argument validators.
    func describe(_ error: Error) -> String {
        if let toolError = error as? MCPToolError {
            return toolError.message
        }
        if let fillToolError = error as? MCPFillToolError {
            return fillToolError.message
        }
        if let portfolioToolError = error as? MCPPortfolioToolError {
            return portfolioToolError.message
        }
        if let pathError = error as? MCPPathPolicyError {
            return pathError.message
        }
        if let resolutionError = error as? PortfolioResolutionError {
            return describe(resolutionError)
        }
        if let serviceError = error as? LDAServiceError {
            return describe(serviceError)
        }
        if let ioError = error as? DocumentIOError {
            return describe(ioError)
        }
        return String(describing: error)
    }

    /// A readable message for each LDAServiceError case.
    private func describe(_ error: LDAServiceError) -> String {
        switch error {
        case .incompleteExtraction(let count):
            return "The document could not be fully scanned: \(count) segment(s) were truncated. " +
                   "The output has NOT been written to avoid presenting a partial result as clean."
        case .unanchoredEntities(let count):
            return "The document was fully scanned, but \(count) detected " +
                   "value(s) are present in the text in a form that could not be " +
                   "matched exactly, so they could not be removed. The output " +
                   "has NOT been written, because it would still contain them."
        case .outputEqualsInput:
            return "Output path must differ from the input path."
        case .noReadableSources:
            return "None of the source documents could be read as text. " +
                   "Check that the files are valid DOCX, PDF, or TXT."
        case .staleTarget(let detail):
            return "The target document changed since the plan was produced (\(detail)). " +
                   "Re-run fill with mode plan before applying."
        }
    }

    /// A readable message for each DocumentIOError case.
    private func describe(_ error: DocumentIOError) -> String {
        switch error {
        case .unreadable(let detail):
            return "Unreadable: \(detail)"
        case .unsupportedFormat(let detail):
            return "Unsupported format: \(detail)"
        case .corrupt(let detail):
            return "Corrupt document: \(detail)"
        case .ocrUnavailable:
            return "OCR is unavailable on this system"
        case .decryptionFailed:
            return "Decryption failed (wrong passphrase or tampered mapping)"
        case .keychainError(let status):
            return "Keychain error with status \(status)"
        case .tooLarge(let detail):
            return "Input too large: \(detail)"
        }
    }

    // MARK: - Response encoders

    /// Encode a tools/call success result whose content is one text block holding
    /// the JSON summary.
    private func toolTextResult(id: RequestID, summary: [String: Any]) -> Data? {
        let text = jsonString(from: summary)
        let result: [String: Any] = [
            "content": [
                ["type": "text", "text": text]
            ],
            "isError": false
        ]
        return encode(resultWithId: id, result: result)
    }

    /// Encode a tools/call result flagged isError with a single text message. This
    /// keeps tool failures inside the JSON-RPC result envelope rather than mapping
    /// them to a transport-level error, which is the MCP convention for tool
    /// execution failures.
    private func toolErrorResult(id: RequestID, message: String) -> Data? {
        let result: [String: Any] = [
            "content": [
                ["type": "text", "text": message]
            ],
            "isError": true
        ]
        return encode(resultWithId: id, result: result)
    }

    /// Encode a JSON-RPC 2.0 success response.
    private func encode(resultWithId id: RequestID, result: [String: Any]) -> Data? {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "result": result
        ]
        response["id"] = id.jsonValue
        return serialize(response)
    }

    /// Encode a JSON-RPC 2.0 error response.
    private func encode(errorWithId id: RequestID, code: Int, message: String) -> Data? {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "error": [
                "code": code,
                "message": message
            ]
        ]
        response["id"] = id.jsonValue
        return serialize(response)
    }

    /// Serialize a JSON object to Data. Returns nil only if the object is not
    /// JSON-serializable, which the constructed responses never are in practice.
    private func serialize(_ object: [String: Any]) -> Data? {
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Render an arbitrary JSON object as a compact UTF-8 string for embedding in a
    /// text content block. Falls back to an empty object string on failure.
    private func jsonString(from object: [String: Any]) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }

    // MARK: - JSON-RPC error codes

    private let parseError = -32700
    private let invalidRequest = -32600
    private let methodNotFound = -32601
    private let invalidParams = -32602

    // MARK: - Defaults

    /// The Keychain account used to protect mapping sidecars when no passphrase is
    /// supplied through a tool call.
    static let defaultKeychainAccount = "ai.openclaw.lda.mcp"

    /// The current time as an ISO-8601 string. This is the only place the MCP edge
    /// reads the clock, keeping LDAService deterministic.
    static func iso8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    // MARK: - Tool descriptors

    /// The seven advertised tools with JSON-Schema input schemas. Declared once so
    /// tools/list and the dispatcher cannot drift.
    static let toolDescriptors: [[String: Any]] = [
        [
            "name": "anonymize_document",
            "description": "Detect and tokenize PII in a document, writing a redacted edit surface and an encrypted mapping sidecar.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "input": ["type": "string", "description": "Path to the source document."],
                    "outputDir": ["type": "string", "description": "Directory for the redacted file and sidecar."],
                    "passphrase": ["type": "string", "description": "Optional passphrase to protect the mapping sidecar."],
                    "modelPath": ["type": "string", "description": "Optional path to the v2 GGUF model to also detect PERSON/COMPANY/ADDRESS."]
                ],
                "required": ["input", "outputDir"]
            ]
        ],
        [
            "name": "anonymize_session",
            "description": "Anonymize several documents as ONE session sharing ONE mapping: the same value keeps the same placeholder across the set. Writes per-document redacted Markdown intermediates and a single encrypted session sidecar. A .zip input expands into the session.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "inputs": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Paths of the session's documents (DOCX, PDF, TXT, MD, or a .zip of them)."
                    ],
                    "outputDir": ["type": "string", "description": "Directory for the redacted intermediates and the session sidecar."],
                    "passphrase": ["type": "string", "description": "Optional passphrase to protect the session mapping sidecar."],
                    "modelPath": ["type": "string", "description": "Optional path to the v2 GGUF model to also detect PERSON/COMPANY/ADDRESS."],
                    "client": ["type": "string", "description": "Optional client profile label: the session reuses and extends that client's stored identities (same value, same placeholder, across sessions)."]
                ],
                "required": ["inputs", "outputDir"]
            ]
        ],
        [
            "name": "restore_document",
            "description": "Restore tokens in an edited redacted file back to their original values using an encrypted mapping.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "editedRedacted": ["type": "string", "description": "Path to the edited redacted file."],
                    "mapping": ["type": "string", "description": "Path to the encrypted .ldamap sidecar."],
                    "output": ["type": "string", "description": "Path to write the restored document."],
                    "passphrase": ["type": "string", "description": "Optional passphrase that protects the mapping sidecar."]
                ],
                "required": ["editedRedacted", "mapping", "output"]
            ]
        ],
        [
            "name": "detect_entities",
            "description": "Detect PII entities in a document without writing any files. Returns entity types, counts, and character offsets only; the detected text itself never leaves the machine.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "input": ["type": "string", "description": "Path to the source document."],
                    "modelPath": ["type": "string", "description": "Optional path to the v2 GGUF model to also detect PERSON/COMPANY/ADDRESS."]
                ],
                "required": ["input"]
            ]
        ],
        [
            "name": "extract_profile",
            "description": "Build an encrypted ClientPortfolio from source documents and save it to disk. Returns a value-free summary (field count, keys, conflicts); no field values are included in the response.",
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
            "description": "Fill blanks in a document from a ClientPortfolio. Exactly one of profile (path to a .ldaprofile file) or portfolio (library entry by name or UUID) must be supplied; they are mutually exclusive. passphrase is only valid with profile; portfolio always uses the library Keychain key. mode=plan returns the fill plan for review. mode=apply writes the filled document and returns a value-free report.",
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
            "description": "List all portfolios in the library. Returns a value-free sorted array of summaries (id, label, kind, dates, fieldCount, conflicted). No field values are included.",
            "inputSchema": [
                "type": "object",
                "properties": [String: Any](),
                "required": [String]()
            ]
        ],
        [
            "name": "portfolio_show",
            "description": "Show one portfolio's value-free detail: summary fields plus rawKeys and conflictedKeys. No field values are included. Identified by UUID or label (case-insensitive, must be unique).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "portfolio": ["type": "string", "description": "Portfolio UUID or label (case-insensitive, must be unique)."]
                ],
                "required": ["portfolio"]
            ]
        ]
    ]

    // MARK: - Stdio loop

    /// Run the blocking stdio read/dispatch/write loop until EOF on stdin.
    ///
    /// Reads newline-delimited JSON from stdin, passes each line's UTF-8 bytes to
    /// the pure handle(_:), writes any non-nil response as a single line to
    /// stdout, and flushes. This is the local transport shell; all logic lives in
    /// handle(_:). No sockets, no network: stdin and stdout only.
    public func runStdioLoop() {
        let input = FileHandle.standardInput
        let output = FileHandle.standardOutput

        // Accumulate bytes and split on newlines so a request may arrive in
        // several read chunks. The handler runs once per complete line.
        var buffer = Data()

        while true {
            let chunk = input.availableData
            if chunk.isEmpty {
                // EOF on stdin: drain any trailing line without a newline, then stop.
                if !buffer.isEmpty {
                    processLine(buffer, to: output)
                }
                break
            }

            let step = MCPServer.consume(buffer: buffer, appending: chunk)
            buffer = step.buffer
            if step.oversizeDiscarded {
                writeOversizeLineError(to: output)
            }
            for line in step.lines {
                processLine(line, to: output)
            }
        }
    }

    // MARK: Buffer framing

    /// What one read chunk produced: the complete lines to dispatch, whatever
    /// remains buffered, and whether an oversize partial line was discarded.
    struct StdioBufferStep {
        var lines: [Data]
        var buffer: Data
        var oversizeDiscarded: Bool
    }

    /// Append a chunk to the accumulation buffer and split out complete lines.
    ///
    /// Pure, and internal rather than private, so the framing rules (including
    /// the size cap) are unit-testable without driving real file handles.
    ///
    /// The cap exists because this loop accumulates until it sees a newline: a
    /// client that never sends one would otherwise grow the buffer until the
    /// process is killed. When the buffer passes the cap with no newline in it,
    /// the accumulated bytes are dropped and the caller reports a parse error.
    /// Resynchronizing at the next newline is the only sane recovery for a
    /// line-delimited protocol.
    static func consume(buffer: Data, appending chunk: Data) -> StdioBufferStep {
        let newline = UInt8(ascii: "\n")
        var working = buffer
        working.append(chunk)

        if working.count > maxRequestLineBytes, !working.contains(newline) {
            return StdioBufferStep(lines: [], buffer: Data(), oversizeDiscarded: true)
        }

        var lines: [Data] = []
        while let newlineIndex = working.firstIndex(of: newline) {
            lines.append(working.subdata(in: working.startIndex..<newlineIndex))
            // Advance past the consumed line and its newline.
            let nextStart = working.index(after: newlineIndex)
            working = working.subdata(in: nextStart..<working.endIndex)
        }
        return StdioBufferStep(lines: lines, buffer: working, oversizeDiscarded: false)
    }

    /// Emit a JSON-RPC parse error for a line that exceeded the size cap. The
    /// id is null because the request was never parsed, so its id is unknown.
    private func writeOversizeLineError(to output: FileHandle) {
        let message = "Request line exceeded "
            + "\(MCPServer.maxRequestLineBytes) bytes and was discarded."
        guard let data = encode(
            errorWithId: .null,
            code: parseError,
            message: message
        ) else { return }
        var out = data
        out.append(UInt8(ascii: "\n"))
        output.write(out)
    }

    /// Hand one raw line to handle(_:) and write any non-nil response as a single
    /// newline-terminated line to stdout. Blank lines are ignored.
    ///
    /// A single complete line over the cap is rejected too: the cap has to hold
    /// whether the oversize payload arrives with a newline or without one.
    private func processLine(_ line: Data, to output: FileHandle) {
        let trimmed = line.filter { $0 != UInt8(ascii: "\r") }
        if trimmed.isEmpty {
            return
        }
        if trimmed.count > MCPServer.maxRequestLineBytes {
            writeOversizeLineError(to: output)
            return
        }
        guard let response = handle(trimmed) else {
            return
        }
        var out = response
        out.append(UInt8(ascii: "\n"))
        output.write(out)
    }
}

// MARK: - Request id

/// A JSON-RPC request id, which may be a number, a string, or null. Stored in a
/// form that round-trips back into a JSON value for the response.
private enum RequestID {
    case number(Int)
    case string(String)
    case null

    /// Interpret a raw JSON id value. A missing id is represented elsewhere; here
    /// nil collapses to null so an error response always carries an id field.
    init(jsonValue: Any?) {
        switch jsonValue {
        case let intValue as Int:
            self = .number(intValue)
        case let numberValue as NSNumber:
            self = .number(numberValue.intValue)
        case let stringValue as String:
            self = .string(stringValue)
        default:
            self = .null
        }
    }

    /// The value to place under the response's "id" key. NSNull keeps the key
    /// present with a JSON null, as JSON-RPC 2.0 error responses require.
    var jsonValue: Any {
        switch self {
        case .number(let value):
            return value
        case .string(let value):
            return value
        case .null:
            return NSNull()
        }
    }
}

// MARK: - Tool errors

/// Errors raised while validating tool-call arguments at the MCP edge.
enum MCPToolError: Error {
    case missingArgument(String)
    /// The per-document key was absent and the legacy shared account did not
    /// work either. Carries both descriptions so the user sees the real cause
    /// rather than only the second failure.
    case restoreFailedAfterLegacyRetry(original: String, retry: String)

    var message: String {
        switch self {
        case .missingArgument(let key):
            return "Missing or empty required argument: \(key)"
        case .restoreFailedAfterLegacyRetry(let original, let retry):
            return "Restore failed. Per-document key: \(original). "
                + "Legacy shared key: \(retry)."
        }
    }
}
