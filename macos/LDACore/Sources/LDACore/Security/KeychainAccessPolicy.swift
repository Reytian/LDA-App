//
//  KeychainAccessPolicy.swift
//  LDACore
//
//  Process-wide policy for how EncryptedContainer keys are protected in the
//  macOS Keychain.
//
//  When requireUserPresence is true (the GUI app turns it on at launch),
//  container keys first use SecAccessControl requiring user presence:
//  retrieval triggers Touch ID, with the login password as the system-provided
//  fallback. A shared LAContext with a reuse window plus a process-lifetime key
//  cache keep the experience to roughly one Touch ID per launch.
//
//  When false (the default: CLI, MCP server, and unit tests), behavior is the
//  original silent file-keychain item. Direct Developer ID sandbox builds do
//  not have a provisioned application identifier, so macOS may reject the
//  user-presence item with errSecMissingEntitlement. In that case the GUI
//  falls back to the traditional login Keychain while keeping the app sandbox.
//
//  Migration: keys created before this policy existed live in the login file
//  keychain without access control. Lookup searches the user-presence item
//  first, then falls back to the legacy item and upgrades it in
//  place (delete + re-add behind user presence, with a best-effort restore
//  if the re-add fails, so a key is never lost).
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import LocalAuthentication

// MARK: - KeychainAccessPolicy

/// Process-wide switch for user-presence (Touch ID) protection of container
/// keys. Set once at app launch, before any store is used.
public enum KeychainAccessPolicy {

    private static let lock = NSLock()
    private static var _requireUserPresence = false
    private static var _sharedContext: LAContext?

    /// When true, keys are created behind a user-presence access control and
    /// retrieved with Touch ID (login password as fallback). Set it exactly
    /// once, at launch, from the GUI app; leave false everywhere headless.
    public static var requireUserPresence: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _requireUserPresence
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _requireUserPresence = newValue
        }
    }

    /// A shared authentication context so one successful Touch ID covers the
    /// burst of keychain reads a single user action can trigger (mapping key,
    /// session record key, client key). The reuse window is capped by the
    /// system; the context is recreated when invalidated.
    static var sharedAuthenticationContext: LAContext {
        lock.lock()
        defer { lock.unlock() }
        if let context = _sharedContext, context.canEvaluatePolicy(
            .deviceOwnerAuthentication, error: nil
        ) {
            return context
        }
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration =
            LATouchIDAuthenticationMaximumAllowableReuseDuration
        context.localizedReason = "unlock your encrypted LDA data"
        _sharedContext = context
        return context
    }
}
