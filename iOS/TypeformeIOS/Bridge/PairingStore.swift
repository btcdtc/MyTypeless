import Foundation
import Security

struct PairingStore {
    private let key = "pairing.config.v1"
    private let tokenStore = PairingTokenStore()

    func load() -> PairingConfig {
        if let data = UserDefaults.standard.data(forKey: key),
           var config = try? JSONDecoder().decode(PairingConfig.self, from: data) {
            let persistedToken = config.token.trimmingCharacters(in: .whitespacesAndNewlines)
            if let token = tokenStore.load(), !token.isEmpty {
                config.token = token
            } else {
                config.token = ""
            }
            if !persistedToken.isEmpty {
                persistConfigPayloadWithoutToken(config)
            }
            return config
        }
        return .empty
    }

    func save(_ config: PairingConfig) {
        let token = config.token.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty {
            tokenStore.delete()
        } else {
            tokenStore.save(token)
        }
        persistConfigPayloadWithoutToken(config)
    }

    private func persistConfigPayloadWithoutToken(_ config: PairingConfig) {
        var persisted = config
        persisted.token = ""
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

private struct PairingTokenStore {
    private let service = "com.typeforme.ios.bridge"
    private let account = "pairing-token"

    func load() -> String? {
        load(service: service)
    }

    private func load(service: String) -> String? {
        var query = baseQuery(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func save(_ token: String) {
        let data = Data(token.utf8)
        var query = baseQuery(service: service)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus != errSecSuccess && addStatus != errSecDuplicateItem {
            NSLog("Typeforme PairingTokenStore save failed: \(addStatus)")
        }
    }

    func delete() {
        let status = SecItemDelete(baseQuery(service: service) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            NSLog("Typeforme PairingTokenStore delete failed: \(status)")
        }
    }

    private func baseQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
