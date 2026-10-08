import Foundation

public enum VaultStagingPhase: Sendable {
    case reading, waitingForVault, encrypting, registering

    public var message: String {
        switch self {
        case .reading: return "Reading the selected document locally..."
        case .waitingForVault: return "Waiting for local vault access (up to 10 seconds)..."
        case .encrypting: return "Encrypting the document on this Mac..."
        case .registering: return "Registering the edited document and its source mapping..."
        }
    }
}
