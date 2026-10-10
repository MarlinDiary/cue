import UIKit

/// Keeps the app running for a while after the user leaves it, so a request under way can finish: leaving the app while
/// a picture was being drawn used to cut the request off, and the card lost its description until the word's page drew
/// it again (2026-10-07). iOS gives about half a minute.
final class KeepAlive {
    private var task: UIBackgroundTaskIdentifier = .invalid

    init(_ name: String) {
        task = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in self?.end() }
    }

    func end() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}
