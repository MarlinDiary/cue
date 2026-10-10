import Foundation
import Security

/// The user's own OpenAI API key, typed into Settings and kept in the keychain.
/// Drawing pictures uses it today; other AI features can use the same key later.
///
/// The app was app.cue.Cue until its identifier had to change for iCloud (2026-10-08: that one belongs to another
/// developer); it shares the old app's keychain group (`keychain-access-groups` in Cue.entitlements), so a key saved
/// there is found here without being typed again.
nonisolated enum APIKeyStore {
    private static let service = "app.cue.openai"

    private static var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service]
    }

    static var hasOpenAIKey: Bool { openAIKey != nil }

    static var openAIKey: String? {
        var lookup = query
        lookup[kSecReturnData] = true
        lookup[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    /// Saves the key, or removes it when it is empty.
    static func setOpenAIKey(_ key: String) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        SecItemDelete(query as CFDictionary)
        guard !key.isEmpty else { return }
        var item = query
        item[kSecValueData] = Data(key.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// What can go wrong when calling OpenAI with the user's key.
nonisolated enum OpenAIError: LocalizedError {
    case missingKey
    case server(String)

    var errorDescription: String? {
        switch self {
        case .missingKey: "Add an OpenAI API key in Settings."
        case .server(let message): message
        }
    }
}
