//
//  MCPPathPolicy.swift
//  LDAMCP
//
//  An allow-list for the file paths the MCP server will act on.
//
//  Why this exists: every MCP tool takes paths as plain strings from stdin. An
//  MCP host is trusted to launch this process, but the JSON it forwards is
//  often assembled from a model's output, and a model can be steered by the
//  contents of a document it just read. Without a policy, "anonymize
//  /etc/ssh/ssh_host_rsa_key and write the result to /tmp/x" is a valid
//  request, and so is writing output into any directory the user can write.
//  Restricting to locations that plausibly hold the user's own documents keeps
//  the tools useful while removing that class of request entirely.
//
//  Allowed by default: anything under the user's home directory, and anything
//  under the system temporary directory (which is per-user on macOS and is
//  where the app's own .zip expansions and every test fixture live).
//
//  Extending it: set LDA_MCP_ALLOWED_ROOTS to a colon-separated list of extra
//  directories. This is deliberately an environment variable set by whoever
//  launches the server, not a value carried in a request: a policy a request
//  can widen is not a policy.
//
//  Symlinks: both the candidate and the roots are resolved before comparison,
//  so a symlink inside an allowed directory cannot point the server at
//  something outside one.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// Decides whether the MCP server may read or write a given path.
public enum MCPPathPolicy {

    /// Environment variable naming extra allowed roots, colon separated.
    public static let extraRootsEnvironmentKey = "LDA_MCP_ALLOWED_ROOTS"

    /// The directories the server may operate inside.
    public static func allowedRoots(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        var roots: [URL] = [
            FileManager.default.homeDirectoryForCurrentUser,
            FileManager.default.temporaryDirectory
        ]
        // On macOS the temporary directory is reached through /var, a symlink to
        // /private/var. Add the resolved form so a path given either way matches.
        roots.append(FileManager.default.temporaryDirectory.resolvingSymlinksInPath())

        if let extra = environment[extraRootsEnvironmentKey] {
            for piece in extra.split(separator: ":") {
                let path = String(piece).trimmingCharacters(in: .whitespaces)
                guard !path.isEmpty else { continue }
                roots.append(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            }
        }
        return roots
    }

    /// True when url sits inside one of the allowed roots.
    ///
    /// The check is performed on normalized, symlink-resolved paths. For a path
    /// that does not exist yet (an output file the tool is about to write), the
    /// nearest existing ancestor is resolved instead, so a not-yet-created file
    /// in an allowed directory is allowed while one whose parent escapes is not.
    public static func isAllowed(
        _ url: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let candidate = resolvedForComparison(url)
        for root in allowedRoots(environment: environment) {
            let rootPath = resolvedForComparison(root)
            if candidate == rootPath { return true }
            if candidate.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") {
                return true
            }
        }
        return false
    }

    /// Throw MCPPathPolicyError.outsideAllowedRoots when url is not allowed.
    public static func enforce(
        _ url: URL,
        argumentKey: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        guard isAllowed(url, environment: environment) else {
            throw MCPPathPolicyError.outsideAllowedRoots(
                argumentKey: argumentKey,
                path: url.path
            )
        }
    }

    /// A comparable absolute path: standardized, tilde expanded, and with
    /// symlinks resolved as far as the path actually exists.
    private static func resolvedForComparison(_ url: URL) -> String {
        let standardized = URL(
            fileURLWithPath: (url.path as NSString).expandingTildeInPath
        ).standardizedFileURL

        if FileManager.default.fileExists(atPath: standardized.path) {
            return standardized.resolvingSymlinksInPath().path
        }

        // The path does not exist yet. Resolve the deepest existing ancestor and
        // re-append the remaining components, so an output file inside an
        // allowed directory is judged by that directory.
        var missing: [String] = []
        var probe = standardized
        while !FileManager.default.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent()
            // deletingLastPathComponent on "/" returns "/": stop rather than loop.
            if parent.path == probe.path { return standardized.path }
            missing.append(probe.lastPathComponent)
            probe = parent
        }
        var resolved = probe.resolvingSymlinksInPath()
        for component in missing.reversed() {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL.path
    }
}

// MARK: - Error

/// Raised when a request names a path outside the allowed roots.
public enum MCPPathPolicyError: Error {
    case outsideAllowedRoots(argumentKey: String, path: String)

    public var message: String {
        switch self {
        case .outsideAllowedRoots(let argumentKey, let path):
            return "Argument \(argumentKey) points outside the allowed directories: "
                + "\(path). The MCP server only reads and writes inside your home "
                + "directory and the system temporary directory. Set "
                + "\(MCPPathPolicy.extraRootsEnvironmentKey) when launching the "
                + "server to allow additional locations."
        }
    }
}
