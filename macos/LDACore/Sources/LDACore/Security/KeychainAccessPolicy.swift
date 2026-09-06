//
//  KeychainAccessPolicy.swift
//  LDACore
//
//  Process-wide policy for how EncryptedContainer keys are protected in the
//  macOS Keychain.
//
//  When requireUserPresence is true (the GUI app turns it on at launch),
//  container keys are created in the DATA PROTECTION keychain behind a
//  SecAccessControl requiring user presence: retrieval triggers Touch ID,
//  with the login password as the system-provided fallback. A shared
//  LAContext with a reuse window plus a process-lifetime key cache keep the
//  experience to roughly one Touch ID per launch, not one per operation.
//
//  When false (the default: CLI, MCP server, and unit tests), behavior is the
//  original silent file-keychain item. This matters beyond UX: biometry items
//  need the data-protection keychain, which requires a KEYCHAIN ACCESS GROUP.
//  For Developer ID distribution that group comes only from an embedded
//  provisioning profile granting com.apple.application-identifier; a signature
//  without one gets errSecMissingEntitlement (-34018) on every protected add,
//  and a restricted entitlement WITHOUT the profile is SIGKILLed at exec. The
//  measured history is in UserPresenceKeychainAddMatrixTests.
//
//  Two consequences the protected paths must respect:
//  - kSecUseDataProtectionKeychain must be set on the protected add, lookup and
//    delete, and NOT on the legacy silent paths. The entitlement alone is not
//    the fix: without the flag the add and the lookup target different
//    keychains and the second launch cannot open what the first sealed.
//  - Data-protection items are INVISIBLE to processes without the group. Once
//    the app migrates a key and removes the silent original, the CLI, the MCP
//    server and the unsandboxed dev binary miss. They must never mint over a
//    container that already exists; EncryptedContainer refuses instead, and
//    anything that crosses surfaces travels as a passphrase sidecar.
//
//  Migration: keys created before this policy existed live in the login file
//  keychain without access control. Lookup searches the protected item first,
//  then falls back to the legacy silent item and upgrades it: the protected
//  copy is ADDED FIRST and the silent original deleted only after that add
//  succeeds, so a failure mid-way leaves the original intact and a key is
//  never lost. A failed upgrade is surfaced via KeychainProtectionAdvisory.
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
            let changed = _requireUserPresence != newValue
            _requireUserPresence = newValue
            lock.unlock()
            // Keys already in the process cache were obtained under the OLD
            // policy, so they must not satisfy reads under the new one: turning
            // protection ON would otherwise serve pre-policy keys with no
            // prompt. The purge happens AFTER releasing this lock so the two
            // locks are never held at once, whichever order a caller uses.
            if changed {
                EncryptedContainer.purgeKeyCache()
            }
        }
    }

    /// Forget every cached key so the next access re-reads the Keychain, and
    /// under this policy re-prompts for Touch ID. Exposed for a host that wants
    /// to lock its data without quitting (for example on screen lock).
    public static func forgetCachedKeys() {
        EncryptedContainer.purgeKeyCache()
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
