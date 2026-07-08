import Foundation
import Security

public protocol SecretStore: Sendable {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String)
}

public final class InMemoryStore: SecretStore, @unchecked Sendable {
    private var store: [String: String] = [:]
    private let lock = NSLock()
    public init() {}
    public func get(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return store[key] }
    public func set(_ key: String, _ value: String) { lock.lock(); defer { lock.unlock() }; store[key] = value }
}

public final class KeychainStore: SecretStore {
    public init() {}

    public func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "net.timosci.stallalert",
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ key: String, _ value: String) {
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "net.timosci.stallalert",
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(attrs as CFDictionary)
        var add = attrs
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

public struct Settings {
    public var thresholdKn: Double
    public var serviceURL: URL?

    public static let serviceTokenKey = "service_token"
    public static let wgUsernameKey = "wg_username"
    public static let wgMicroPasswordKey = "wg_micro_password"

    public static func load(defaults: UserDefaults, secrets: SecretStore) -> Settings {
        let threshold = defaults.object(forKey: "threshold_kn") as? Double ?? 12
        let url = defaults.string(forKey: "service_url").flatMap(URL.init(string:))
        _ = secrets // secrets are read directly by callers via keys
        return Settings(thresholdKn: threshold, serviceURL: url)
    }

    public func save(defaults: UserDefaults, secrets: SecretStore) {
        defaults.set(thresholdKn, forKey: "threshold_kn")
        defaults.set(serviceURL?.absoluteString, forKey: "service_url")
        _ = secrets
    }
}
