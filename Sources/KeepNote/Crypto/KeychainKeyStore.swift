import CryptoKit
import Foundation
import os
import Security

enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case malformedKey

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "Keychain error \(status): \(message)"
        case .malformedKey:
            return "The stored encryption key is not a valid 256-bit key."
        }
    }
}

/// Owns the single symmetric key that seals note bodies.
///
/// Two attributes carry the whole privacy promise:
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` keeps the key off any
/// backup that could be restored elsewhere, and the absence of
/// `kSecAttrSynchronizable` keeps it out of iCloud Keychain. The key therefore
/// never leaves this Mac — which is also why synced `.hmnote` files carry
/// plaintext bodies: they are readable without the app by design.
enum KeychainKeyStore {
    private static let service = "com.keepnote.KeepNote.bodykey"
    private static let account = "default"

    /// The key as read this run. The Keychain is asked once per process —
    /// at launch — and every later caller gets this copy: reopening the app,
    /// a new window or a sync pass never reaches the Keychain again.
    @MainActor private static var sessionKey: SymmetricKey?

    /// How many times this run actually read the Keychain (0 or 1).
    @MainActor private(set) static var keychainReads = 0

    @MainActor
    static func sessionKeyLoadingOnce() throws -> SymmetricKey {
        if let sessionKey { return sessionKey }
        keychainReads += 1
        Logger(subsystem: "com.keepnote.KeepNote", category: "keychain")
            .notice("reading the body key from the Keychain (read \(keychainReads, privacy: .public) this run)")
        let key = try loadOrCreateKey()
        sessionKey = key
        return key
    }

    static func loadOrCreateKey() throws -> SymmetricKey {
        if let existing = try loadKey() { return existing }
        let key = SymmetricKey(size: .bits256)
        try store(key)
        return key
    }

    static func loadKey() throws -> SymmetricKey? {
        var query: [String: Any] = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, data.count == 32 else { throw KeychainError.malformedKey }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    static func store(_ key: SymmetricKey) throws {
        let data = key.withUnsafeBytes { Data($0) }
        var attributes = baseQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(updateStatus)
            }
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Only used by tests and by "reset all data".
    static func deleteKey() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Deliberately absent: kSecAttrSynchronizable. The key stays local.
        ]
    }
}
