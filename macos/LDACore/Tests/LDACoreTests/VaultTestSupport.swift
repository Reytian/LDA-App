//
//  VaultTestSupport.swift
//  LDACoreTests
//
//  Shared helpers for suites that touch the (encrypted) staging vault. The
//  vault master key defaults to a Keychain account, and tests must never
//  create real Keychain items, so every suite injects the same passphrase:
//  into DocumentVault through its protection initializer parameter, and into
//  MCPServer through the LDA_VAULT_PASSPHRASE launch environment key. The two
//  MUST match, because a server decrypts what the test staged directly.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
@testable import LDACore

enum VaultTestSupport {

    /// The one passphrase every vault-touching test uses.
    static let passphrase = "unit-test-vault-passphrase"

    /// Vault protection for direct DocumentVault construction in tests.
    static var protection: MappingProtection { .passphrase(passphrase) }

    /// A vault over root, protected by the shared test passphrase.
    static func vault(root: URL) -> DocumentVault {
        DocumentVault(rootDirectory: root, protection: protection)
    }

    /// An MCPServer launch environment pointing at vaultDir and carrying the
    /// shared test passphrase, plus any extra launch keys the test needs.
    static func serverEnvironment(
        vaultDir: URL,
        extra: [String: String] = [:]
    ) -> [String: String] {
        var environment = extra
        environment[DocumentVault.environmentKey] = vaultDir.path
        environment[DocumentVault.passphraseEnvironmentKey] = passphrase
        return environment
    }
}
