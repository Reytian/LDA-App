import Foundation
import Security

/// Actionable, value-free diagnostics. Never infer authentication from elapsed time.
public enum LocalOperationFailure {
    public static func message(for error: Error) -> String? {
        if let error = error as? DocumentVaultError { return error.message }
        if case DocumentIOError.keychainError(let status) = error {
            switch status {
            case errSecInteractionNotAllowed, errSecAuthFailed:
                return "authentication_required: macOS refused access to a local key; unlock this Mac, complete its local authentication prompt, then retry"
            case errSecUserCanceled:
                return "authentication_cancelled: local authentication was cancelled; retry and confirm on this Mac"
            default: return "keychain_error: status \(status); check local key access in LDA and retry"
            }
        }
        let ns = error as NSError
        if (ns.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(ns.code))
            || (ns.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(ns.code)) {
            return DocumentVaultError.filesystemPermissionDenied.message
        }
        return nil
    }
}
