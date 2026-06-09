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
//  calls, so it preserves the app's no-network-entitlement, offline posture. An
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
    public static let serverVersion = "0.1.0"

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
            case "restore_document":
                summary = try callRestore(arguments)
            case "detect_entities":
                summary = try callDetect(arguments)
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
        let protection = protectionMode(from: arguments)

        // The edge owns the clock: stamp createdAt with an ISO-8601 timestamp now.
        let createdAt = MCPServer.iso8601Now()

        let modelPath = (arguments["modelPath"] as? String).flatMap { $0.isEmpty ? nil : $0 }
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
            "imageRedactionCount": result.imageRedactionCount
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
        let protection = protectionMode(from: arguments)

        let report = try LDAService.restore(
            editedRedacted: editedRedacted,
            mapping: mapping,
            protection: protection,
            output: output
        )

        return [
            "output": report.outputURL.path,
            "restoredCount": report.restoredCount,
            "orphanTokens": report.orphanTokens
        ]
    }

    /// detect_entities: run LDAService.detect and summarize the detected spans.
    private func callDetect(_ arguments: [String: Any]) throws -> [String: Any] {
        let input = try requireURL(arguments, key: "input")
        let modelPath = (arguments["modelPath"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let spans = try LDAService.detect(input: input, llmModelPath: modelPath)

        let entities: [[String: Any]] = spans.map { span in
            [
                "type": span.type.rawValue,
                "text": span.text,
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
        return URL(fileURLWithPath: value)
    }

    /// Choose the mapping protection mode from the arguments. A passphrase, when
    /// present and non-empty, selects PBKDF2 passphrase protection; otherwise the
    /// server falls back to a fixed Keychain account so a sidecar is always
    /// encrypted at rest.
    private func protectionMode(from arguments: [String: Any]) -> MappingProtection {
        if let passphrase = arguments["passphrase"] as? String, !passphrase.isEmpty {
            return .passphrase(passphrase)
        }
        return .keychain(account: MCPServer.defaultKeychainAccount)
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

    /// A human-readable description for any error surfaced from LDAService.
    private func describe(_ error: Error) -> String {
        if let toolError = error as? MCPToolError {
            return toolError.message
        }
        if let ioError = error as? DocumentIOError {
            return describe(ioError)
        }
        return String(describing: error)
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

    /// The three advertised tools with JSON-Schema input schemas. Declared once so
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
            "description": "Detect PII entities in a document without writing any files.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "input": ["type": "string", "description": "Path to the source document."],
                    "modelPath": ["type": "string", "description": "Optional path to the v2 GGUF model to also detect PERSON/COMPANY/ADDRESS."]
                ],
                "required": ["input"]
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
        let newline = UInt8(ascii: "\n")

        while true {
            let chunk = input.availableData
            if chunk.isEmpty {
                // EOF on stdin: drain any trailing line without a newline, then stop.
                if !buffer.isEmpty {
                    processLine(buffer, to: output)
                }
                break
            }
            buffer.append(chunk)

            while let newlineIndex = buffer.firstIndex(of: newline) {
                let line = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                // Advance past the consumed line and its newline.
                let nextStart = buffer.index(after: newlineIndex)
                buffer = buffer.subdata(in: nextStart..<buffer.endIndex)
                processLine(line, to: output)
            }
        }
    }

    /// Hand one raw line to handle(_:) and write any non-nil response as a single
    /// newline-terminated line to stdout. Blank lines are ignored.
    private func processLine(_ line: Data, to output: FileHandle) {
        let trimmed = line.filter { $0 != UInt8(ascii: "\r") }
        if trimmed.isEmpty {
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
private enum MCPToolError: Error {
    case missingArgument(String)

    var message: String {
        switch self {
        case .missingArgument(let key):
            return "Missing or empty required argument: \(key)"
        }
    }
}
