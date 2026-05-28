import Foundation
import Security
import OSLog

/// Tiny wrapper around Keychain Generic Password items, scoped to one
/// service identifier. Used by `MotifServerStore` to keep motifd bearer
/// tokens out of iCloud backups.
struct Keychain {
    private static let log = Logger(subsystem: "io.allsunday.motif", category: "Keychain")
    let service: String

    func setData(_ data: Data, forKey key: String) {
        deleteData(forKey: key)
        let attrs: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      key,
            kSecValueData as String:        data,
            kSecAttrAccessible as String:   kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status != errSecSuccess {
            Self.log.error("SecItemAdd \(key, privacy: .public): OSStatus \(status)")
        }
    }

    func getData(forKey key: String) -> Data? {
        let q: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  key,
            kSecMatchLimit as String:   kSecMatchLimitOne,
            kSecReturnData as String:   true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        if status != errSecSuccess {
            Self.log.error("SecItemCopyMatching \(key, privacy: .public): OSStatus \(status)")
            return nil
        }
        return item as? Data
    }

    func deleteData(forKey key: String) {
        let q: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  key
        ]
        let status = SecItemDelete(q as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Self.log.error("SecItemDelete \(key, privacy: .public): OSStatus \(status)")
        }
    }

    func setJSON<T: Encodable>(_ value: T, forKey key: String) {
        do {
            let data = try JSONEncoder().encode(value)
            setData(data, forKey: key)
        } catch {
            Self.log.error("encode \(key, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    func getJSON<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = getData(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            Self.log.error("decode \(key, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
