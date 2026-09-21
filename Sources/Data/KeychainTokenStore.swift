import Foundation
import Security

/// Session token storage. Guardrail 6.5: Keychain with a justified accessibility class,
/// never `UserDefaults` or a plist.
///
/// **Accessibility: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.**
///
/// `WhenUnlocked` because the app has no background work: the token is needed only while
/// someone is looking at the screen, so there is no reason to leave it readable while the
/// device is locked and in someone else's hands.
///
/// `ThisDeviceOnly` because it excludes the item from encrypted backups and from iCloud
/// Keychain sync. A bearer token for a paid reservation should not survive a restore onto
/// a different handset; the cost is that the user signs in again after a device migration,
/// which is the right trade in a banking context.
///
/// Not `AfterFirstUnlock`, which would keep the token readable from the moment of first
/// unlock until reboot — convenient for background refresh this app does not do.
struct KeychainTokenStore: TokenStoring {
    enum KeychainError: Error, Equatable {
        case unexpectedStatus(OSStatus)
        case dataCorrupted
    }

    let service: String
    let account: String

    init(service: String = "com.vncdc.parking.session", account: String = "jwt") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    func save(_ token: String) throws {
        guard let data = token.data(using: .utf8) else { throw KeychainError.dataCorrupted }

        // Delete-then-add rather than update, so a change of accessibility class actually
        // takes effect instead of silently retaining the old one.
        SecItemDelete(baseQuery as CFDictionary)

        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
                throw KeychainError.dataCorrupted
            }
            return token
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

/// In-memory store for tests and SwiftUI previews. Never used in the app target's
/// composition root — see `AppEnvironment`.
final class InMemoryTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    init(token: String? = nil) { self.token = token }

    func save(_ token: String) throws {
        lock.withLock { self.token = token }
    }

    func read() throws -> String? {
        lock.withLock { token }
    }

    func clear() throws {
        lock.withLock { token = nil }
    }
}
