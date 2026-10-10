import Foundation
import Observation
import Security

/// How the app reaches AI: through Cue's server, paid for with points bought in the app (`PointStore`), or straight to
/// OpenAI with the user's own API key, billed by OpenAI (user, 2026-10-10: "也允许用户自己填写key"). Points unless the
/// user chose their own key; a key entered before points came keeps being used.
nonisolated enum AIAccess: Equatable {
    case points
    case ownKey(String)

    enum Mode: String, CaseIterable, Identifiable {
        case points, ownKey
        var id: Self { self }
    }

    private static let modeKey = "aiAccess"

    static var mode: Mode {
        get {
            if let raw = UserDefaults.standard.string(forKey: modeKey), let mode = Mode(rawValue: raw) { return mode }
            return APIKeyStore.hasOpenAIKey ? .ownKey : .points
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    /// The way in now: nil when the user chose their own key and hasn't entered one.
    static var current: AIAccess? {
        switch mode {
        case .points: .points
        case .ownKey: APIKeyStore.openAIKey.map { .ownKey($0) }
        }
    }

    /// Whether anything can be asked of AI: the user agreed, and has a way in.
    static var isAvailable: Bool { AIConsent.given && current != nil }

    /// The way in, or why there is none.
    static func require() throws -> AIAccess {
        guard AIConsent.given else { throw AIError.needsConsent }
        guard let current else { throw OpenAIError.missingKey }
        return current
    }
}

/// Whether the user agreed to what they add and ask being sent to OpenAI, asked once before anything goes (App Review
/// 5.1.2(i): personal data shared with a third-party AI needs the user's explicit permission first).
nonisolated enum AIConsent {
    private static let key = "aiConsent"

    static var given: Bool { UserDefaults.standard.bool(forKey: key) }

    static func give() { UserDefaults.standard.set(true, forKey: key) }
}

/// What stops a request before AI sees it.
nonisolated enum AIError: LocalizedError {
    case needsConsent
    case needsPoints

    var errorDescription: String? {
        switch self {
        case .needsConsent: String(localized: "Turn on AI to write entries, draw pictures and answer questions.")
        case .needsPoints: String(localized: "Not enough points left.")
        }
    }
}

/// The app's account on Cue's server: an id and a secret the app makes up the first time it needs them, kept in iCloud
/// Keychain, so the points follow the user to their other devices and outlast the app being deleted. There is nothing
/// to sign up for. The id is also every purchase's appAccountToken, which ties a purchase to the account it pays for.
nonisolated enum CueAccount {
    private static let service = "com.chenye.cue.account"
    private static let lock = NSLock()

    static var id: UUID { credentials.id }

    static var authorization: String {
        let (id, secret) = credentials
        return "Bearer \(id.uuidString.lowercased()).\(secret)"
    }

    private static var credentials: (id: UUID, secret: String) {
        lock.lock()
        defer { lock.unlock() }
        if let stored = read() { return stored }
        let id = UUID()
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let secret = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let item: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id.uuidString,
            kSecAttrSynchronizable: true, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData: Data(secret.utf8),
        ]
        SecItemAdd(item as CFDictionary, nil)
        // Another device of the user's may have made one first, arriving through iCloud meanwhile: theirs it is.
        return read() ?? (id, secret)
    }

    private static func read() -> (id: UUID, secret: String)? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny, kSecReturnData: true, kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let item = result as? [CFString: Any],
              let account = item[kSecAttrAccount] as? String, let id = UUID(uuidString: account),
              let data = item[kSecValueData] as? Data, let secret = String(data: data, encoding: .utf8) else { return nil }
        return (id, secret)
    }
}

/// Cue's server (server/ in the repository): it holds Cue's own OpenAI key, makes the requests the app makes with
/// points, takes what each cost from the account, and keeps the shared library of words already written and drawn.
/// It answers as OpenAI does, so the app reads both alike.
nonisolated enum CueServer {
    /// DEBUG builds can be pointed at one running on the Mac: `-serverURL http://127.0.0.1:8787`.
    static var base: URL {
        #if DEBUG
        if let override = UserDefaults.standard.string(forKey: "serverURL"), let url = URL(string: override) {
            return url
        }
        #endif
        return production
    }

    /// Deployed 2026-10-10 (server/README.md).
    private static let production = URL(string: "https://cue-api.emblem-push.workers.dev")!

    static func request(_ path: String, json: [String: Any], timeout: TimeInterval) throws -> URLRequest {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(CueAccount.authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        return request
    }

    /// Notes the points a reply tells of, and turns the server's "not enough points" into `AIError.needsPoints`.
    static func check(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { return }
        if let value = response.value(forHTTPHeaderField: "X-Cue-Points"), let points = Double(value) {
            Task { @MainActor in Points.shared.balance = points }
        }
        if response.statusCode == 402 { throw AIError.needsPoints }
    }

    /// Notes the points a streamed reply tells of, in an event of the server's own, whether it was one.
    static func note(_ event: [String: Any]) -> Bool {
        guard event["type"] as? String == "cue.points" else { return false }
        if let points = (event["points"] as? NSNumber)?.doubleValue {
            Task { @MainActor in Points.shared.balance = points }
        }
        return true
    }
}

/// The account's points, as Cue's server last told them.
@Observable
final class Points {
    static let shared = Points()

    /// Nil until the server has said.
    var balance: Double?

    /// What a new word and a question can take at most: below them, the app asks for more points before sending, as
    /// the server would refuse them (server/src/routes.ts, `NEW_WORD`, `CHAT_HOLD`).
    static let newWord = 1.5
    static let question = 1.2

    func refresh() async {
        guard AIAccess.mode == .points, AIConsent.given else { return }
        var request = URLRequest(url: CueServer.base.appending(path: "v1/account"))
        request.timeoutInterval = 15
        request.setValue(CueAccount.authorization, forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let points = (json["points"] as? NSNumber)?.doubleValue else { return }
        balance = points
    }
}

/// What stands between the user and AI before something is sent: their agreement, points enough, or a key.
enum AIGate: String, Identifiable {
    case consent, points, key
    var id: Self { self }

    /// Why a request needing `points` can't go yet, if it can't.
    static func check(needing points: Double) -> AIGate? {
        guard AIConsent.given else { return .consent }
        switch AIAccess.mode {
        case .ownKey: return APIKeyStore.hasOpenAIKey ? nil : .key
        case .points:
            if let balance = Points.shared.balance, balance < points { return .points }
            return nil
        }
    }
}
