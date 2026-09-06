//
//  MCPServer.swift
//  LDAMCP
//
//  A Model Context Protocol (MCP) server over LDAService, speaking JSON-RPC 2.0
//  on stdio. This is the edge an MCP client (an agent host) connects to.
//
//  Context boundary: "the MCP server runs locally" does NOT mean data stays
//  local. Everything a tool returns enters the model context of the agent host
//  and leaves the machine, and file paths are themselves PII (legal folders
//  are named after the parties). The advertised surface is therefore
//  handle-first: documents are staged into a DocumentVault by the human (lda
//  vault stage), tools accept and return opaque handles, and only read_redacted
//  may return body text (redacted text only). See MCPVaultTools.swift and
//  MCPToolCatalog.swift. The old path-taking core tools are removed; the
//  path-taking fill and portfolio tools are refused unless the process was
//  launched with LDA_MCP_LEGACY_PATH_TOOLS=1.
//
//  Transport note (LOCAL, not network): this server speaks newline-delimited
//  JSON-RPC 2.0 over stdin/stdout only. It opens no sockets and makes no network
//  calls. The app itself now has an outbound entitlement for model downloads,
//  but this server is not part of that path and must never gain one. An
//  MCP host launches this process and pipes requests to it on stdin; responses
//  come back on stdout.
//
//  Structure for testability: the core is a PURE function, handle(_:), that maps
//  one raw JSON-RPC request payload to one raw response payload (or nil for a
//  notification). It performs no stdio of its own, so it is fully unit-testable.
//  The one piece of per-instance state is MCPSessionMetrics, the counters the
//  attest tool reports; it hangs off the server by reference and never affects
//  a response other than attest's. runStdioLoop() is the thin imperative shell
//  that wires handle(_:) to stdin and stdout.
//
//  Clock ownership: LDAService is clock-free by contract. This edge stamps the
//  ISO-8601 createdAt with Date() at the tools/call boundary so the facade stays
//  deterministic.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
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

    /// The launch environment: the legacy-tool gate and the vault root
    /// override are read from here, never from a request. Injected so tests
    /// can open the gate and point the vault at a temporary directory without
    /// mutating the process environment.
    let environment: [String: String]

    /// Counters for the attest tool: bytes returned and per-tool call counts.
    /// A reference type held by this value-typed server, so handle(_:) stays
    /// non-mutating and one server instance accumulates across calls.
    let metrics = MCPSessionMetrics()

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    /// Whether the path-taking legacy tools are enabled for this process.
    var legacyPathToolsEnabled: Bool {
        environment[MCPServer.legacyPathToolsEnvironmentKey] == "1"
    }

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

    /// tools/list: advertise the handle-first surface, plus the legacy path
    /// tools only when the launch environment opted in.
    private func handleToolsList(id: RequestID) -> Data? {
        var tools = MCPServer.vaultToolDescriptors
        if legacyPathToolsEnabled {
            tools += MCPServer.legacyToolDescriptors
        }
        let result: [String: Any] = ["tools": tools]
        return encode(resultWithId: id, result: result)
    }

    /// tools/call: dispatch by tool name, returning a content array holding one
    /// text block with a JSON summary. Any thrown error is reported as an
    /// isError result rather than crashing the process.
    ///
    /// Three tiers: the handle-first vault tools (errors rendered boundary-safe,
    /// never a path), the removed old core tools (a migration message), and the
    /// legacy path tools (refused unless LDA_MCP_LEGACY_PATH_TOOLS=1 was set at
    /// launch; their errors keep the older, more detailed wording since the
    /// operator explicitly accepted the legacy surface).
    private func handleToolsCall(id: RequestID, params: [String: Any]) -> Data? {
        guard let name = params["name"] as? String else {
            return encode(
                errorWithId: id,
                code: invalidParams,
                message: "tools/call requires a tool name"
            )
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]

        if MCPServer.vaultToolNames.contains(name) {
            metrics.noteToolCall(name)
            do {
                let summary: [String: Any]
                switch name {
                case "list_pending":
                    summary = try callListPending()
                case "anonymize":
                    summary = try callAnonymizeHandle(arguments)
                case "anonymize_session":
                    summary = try callAnonymizeSessionHandles(arguments)
                case "read_redacted":
                    summary = try callReadRedacted(arguments)
                case "detect_entities":
                    summary = try callDetectHandle(arguments)
                case "restore":
                    summary = try callRestoreHandle(arguments)
                case "export":
                    summary = try callExport(arguments)
                case "attest":
                    summary = callAttest()
                default:
                    return toolErrorResult(id: id, message: "Unknown tool: \(name)")
                }
                return toolTextResult(id: id, summary: summary)
            } catch {
                return toolErrorResult(id: id, message: describeBoundarySafe(error))
            }
        }

        if MCPServer.removedToolNames.contains(name) {
            return toolErrorResult(id: id, message: MCPServer.removedToolMessage(name))
        }

        if MCPServer.legacyGatedToolNames.contains(name) {
            guard legacyPathToolsEnabled else {
                return toolErrorResult(id: id, message: MCPServer.legacyGatedToolMessage(name))
            }
            metrics.noteToolCall(name)
            do {
                let summary: [String: Any]
                switch name {
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
                return toolErrorResult(id: id, message: describe(error))
            }
        }

        return toolErrorResult(id: id, message: "Unknown tool: \(name)")
    }

    // MARK: - Argument helpers

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

    /// Parse the optional "style" argument shared by the anonymize tools.
    /// Absent or empty means .token (the historical behavior); an unknown
    /// value is an explicit error rather than a silent default.
    func styleArgument(from arguments: [String: Any]) throws -> SubstitutionStyle {
        guard let raw = arguments["style"] as? String, !raw.isEmpty else {
            return .token
        }
        guard let style = SubstitutionStyle(rawValue: raw) else {
            throw MCPToolError.invalidArgument(
                key: "style",
                value: raw,
                allowed: SubstitutionStyle.allCases.map { $0.rawValue }
            )
        }
        return style
    }

    /// The per-document Keychain account for a mapping sidecar, derived from
    /// the sidecar's base name. The vault tools pass an opaque handle as the
    /// base, so the account never embeds a document name.
    static func keychainAccount(forMappingBaseName base: String) -> String {
        "\(MCPServer.defaultKeychainAccount).\(base)"
    }

    /// The distinct entity-type wire strings present in a set of spans, in stable
    /// first-seen document order. Internal so MCPVaultTools reuses it.
    func entityTypeStrings(_ spans: [Span]) -> [String] {
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
            return "The document could not be fully scanned: the model gave no usable answer for " +
                   "\(count) segment(s) (the reply was cut off, failed, or was not an entity list). " +
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
    case invalidArgument(key: String, value: String, allowed: [String])
    /// Two arguments that select different shapes of one tool were both given.
    case mutuallyExclusiveArguments([String])

    var message: String {
        switch self {
        case .missingArgument(let key):
            return "Missing or empty required argument: \(key)"
        case .invalidArgument(let key, let value, let allowed):
            return "Invalid value \"\(value)\" for argument \(key). Allowed: \(allowed.joined(separator: ", "))"
        case .mutuallyExclusiveArguments(let keys):
            return "Arguments \(keys.joined(separator: " and ")) are mutually exclusive; pass only one of them."
        }
    }
}
