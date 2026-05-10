import Foundation
import Security

/// Tiny wrapper around Keychain Generic Password items, scoped to one
/// service identifier. We persist Doubao credentials here so they survive
/// app reinstalls without ending up in iCloud backups.
struct Keychain {
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
        SecItemAdd(attrs as CFDictionary, nil)
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
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }

    func deleteData(forKey key: String) {
        let q: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  key
        ]
        SecItemDelete(q as CFDictionary)
    }

    func setJSON<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) {
            setData(data, forKey: key)
        }
    }

    func getJSON<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = getData(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
