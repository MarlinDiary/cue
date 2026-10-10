import OSLog
import StoreKit

/// The points packs, bought with Apple's in-app purchase and credited by Cue's server, which checks Apple's signature
/// and credits each purchase once. A purchase is finished only once the server has credited it, so one cut off on its
/// way is sent again (StoreKit hands unfinished ones back at launch).
///
/// Points are priced a little above what OpenAI charges, after Apple's 15% and the local tax (user, 2026-10-10: "我希望
/// 微微赚钱，这样安全点"): about US$0.042 a point, a new word taking about one. The US$0.99 pack gives 20 rather than
/// 24: at Apple's lowest price in Canada, Singapore, the Philippines, Sweden, Korea and Norway, 24 brought in less than
/// they cost (proceeds at that day's exchange rates; every other pack and storefront made 9% or more).
@Observable
final class PointStore {
    static let shared = PointStore()
    static let products = ["com.chenye.cue.points.20", "com.chenye.cue.points.48",
                           "com.chenye.cue.points.120", "com.chenye.cue.points.240"]

    private let log = Logger(subsystem: "com.chenye.cue", category: "points")
    private var updates: Task<Void, Never>?

    /// Listens for purchases completed outside the app's own flow (approved by a parent, interrupted, made on another
    /// device), and sends on any not yet credited.
    func start() {
        guard updates == nil else { return }
        updates = Task {
            for await result in Transaction.updates { await deliver(result) }
        }
        Task {
            for await result in Transaction.unfinished { await deliver(result) }
        }
    }

    /// Has the server credit a purchase, and finishes it once it has.
    func deliver(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else {
            log.error("A purchase StoreKit couldn’t verify was left unfinished.")
            return
        }
        do {
            let request = try CueServer.request("v1/purchase", json: ["transaction": result.jwsRepresentation],
                                                timeout: 30)
            let (data, response) = try await URLSession.shared.data(for: request)
            try CueServer.check(response)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                log.error("The server didn’t credit a purchase: \(String(decoding: data, as: UTF8.self), privacy: .public)")
                return
            }
            await transaction.finish()
        } catch {
            log.error("A purchase couldn’t reach the server: \(String(describing: error), privacy: .public)")
        }
    }
}
