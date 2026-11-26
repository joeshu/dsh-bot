import Foundation
import LocalAuthentication
import Security
import CryptoKit

public enum KeychainBridgeError: Error, LocalizedError {
    case authenticationFailed
    case invalidAccount(String)
    case osStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .authenticationFailed: return "Biometric authentication cancelled or failed."
        case .invalidAccount(let name): return "Invalid Keychain credential name: \(name) (#13819 guard)."
        case .osStatus(let status): return "Keychain error (OSStatus \(status))."
        }
    }
}

/// Native iOS Keychain + Face ID bridge for DS-Bot API keys and sensitive secrets.
/// Uses standard app-scoped keychain items (no custom Keychain Sharing entitlement required for sideloading).
public final class KeychainBridge: Sendable {
    private let service: String

    public init(service: String = "io.github.dsbot.ios.standalone.vault") {
        self.service = service
    }

    private func validatedAccount(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = !trimmed.isEmpty && trimmed.count <= 128 && trimmed.unicodeScalars.allSatisfy { s in
            (s.value >= 48 && s.value <= 57) || (s.value >= 65 && s.value <= 90) ||
            (s.value >= 97 && s.value <= 122) || s == "." || s == "_" || s == ":" || s == "-"
        }
        guard ok else { throw KeychainBridgeError.invalidAccount(raw) }
        return trimmed
    }

    public func getSecret(account: String, requireBiometrics: Bool) async throws -> [String: Any] {
        let safeAccount = try validatedAccount(account)
        if requireBiometrics {
            let context = LAContext()
            var authError: NSError?
            if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) {
                let ok = try await context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: "Authenticate to access DS Bot credentials."
                )
                guard ok else { throw KeychainBridgeError.authenticationFailed }
            } else {
                throw KeychainBridgeError.authenticationFailed
            }
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: safeAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return ["value": NSNull()]
        }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainBridgeError.osStatus(status)
        }
        return ["value": value]
    }

    private func insertSecret(query: [String: Any], data: Data) -> OSStatus {
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    private func passwordQuery(account: String) throws -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: try validatedAccount(account)
        ]
    }

    public func setSecret(account: String, value: String) throws -> [String: Any] {
        let query = try passwordQuery(account: account)
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data] as CFDictionary
        var status = SecItemUpdate(query as CFDictionary, update)
        if status == errSecItemNotFound {
            status = insertSecret(query: query, data: data)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(query as CFDictionary, update)
            }
        }
        guard status == errSecSuccess else { throw KeychainBridgeError.osStatus(status) }
        return ["ok": true]
    }

    public func deleteSecret(account: String) throws -> [String: Any] {
        let safeAccount = try validatedAccount(account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: safeAccount
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainBridgeError.osStatus(status)
        }
        return ["ok": true]
    }
}

extension KeychainBridge {
    private func modelAccount(_ provider: ModelProvider) -> String {
        let digest = SHA256.hash(data: Data(provider.baseURL.absoluteString.utf8))
        return "model:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    func saveModelKey(_ value: String, provider: ModelProvider) throws {
        _ = try setSecret(account: modelAccount(provider), value: value)
    }

    func modelKey(provider: ModelProvider, migrateOfficialKey: Bool) async throws -> String {
        if let value = try await getSecret(account: modelAccount(provider), requireBiometrics: false)["value"] as? String,
           !value.isEmpty {
            return value
        }
        if provider.isDeepSeek, migrateOfficialKey,
           let value = try await getSecret(account: "deepseek_api_key", requireBiometrics: false)["value"] as? String,
           !value.isEmpty {
            let account = modelAccount(provider)
            let status = try insertSecret(query: passwordQuery(account: account), data: Data(value.utf8))
            if status == errSecSuccess { return value }
            if status == errSecDuplicateItem {
                if let current = try await getSecret(account: account, requireBiometrics: false)["value"] as? String,
                   !current.isEmpty {
                    return current
                }
                _ = try setSecret(account: account, value: value)
                return value
            }
            throw KeychainBridgeError.osStatus(status)
        }
        throw ModelProviderError.missingKey
    }
}
