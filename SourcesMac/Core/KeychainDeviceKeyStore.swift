import Foundation
import Security

enum DeviceKeyStoreError: LocalizedError {
    case emptyKey
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptyKey: return "Bark Device Key 不能为空"
        case .unexpectedStatus(let status):
            let description = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
            return "Keychain 操作失败：\(description)"
        }
    }
}

protocol DeviceKeyStoring: Sendable {
    func read() throws -> String?
    func save(_ key: String) throws
    func delete() throws
}

enum KeychainAccount {
    static func currentUsername() -> String {
        NSUserName()
    }
}

struct KeychainDeviceKeyStore: DeviceKeyStoring, Sendable {
    static let service = "bark-notify-device-key"
    let account: String

    init(account: String = KeychainAccount.currentUsername()) {
        self.account = account
    }

    func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw DeviceKeyStoreError.unexpectedStatus(status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            return nil
        }
        return key
    }

    func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DeviceKeyStoreError.emptyKey }
        let data = Data(trimmed.utf8)
        let status = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var item = baseQuery
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw DeviceKeyStoreError.unexpectedStatus(addStatus)
            }
        } else if status != errSecSuccess {
            throw DeviceKeyStoreError.unexpectedStatus(status)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeviceKeyStoreError.unexpectedStatus(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account
        ]
    }
}
