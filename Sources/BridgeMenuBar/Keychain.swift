import Foundation
import Security
import BridgeCore

enum AccessKey {
    static let service = "com.hyspace.copilot-bridge-menubar"
    static func loadOrCreate() throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "lan-access",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) { return value }
        guard status == errSecItemNotFound else { throw BridgeError.message("无法读取钥匙串访问密钥（\(status)）。") }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw BridgeError.message("无法生成安全访问密钥。") }
        let value = Data(bytes).base64EncodedString()
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "lan-access",
            kSecValueData as String: Data(value.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let saved = SecItemAdd(add as CFDictionary, nil)
        guard saved == errSecSuccess else { throw BridgeError.message("无法保存钥匙串访问密钥（\(saved)）。") }
        return value
    }
}
