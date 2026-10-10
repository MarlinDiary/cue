import CloudKit
import CoreData
import Foundation
import os

/// The store's syncing with the user's iCloud (the words and the conversations are kept there too, so they come back
/// on their other devices, and after the app is deleted and installed again: user, 2026-10-08). Watched for one thing:
/// whether this launch has seen what iCloud holds, which the sample words wait for, so a wall coming back from iCloud
/// isn't given them again.
@Observable
final class CloudSync {
    static let shared = CloudSync()

    /// The iCloud container the store syncs with.
    static let container = "iCloud.com.chenye.cue"

    /// Whether this launch has seen what iCloud holds, or there is no iCloud account to look in.
    private(set) var looked = false

    @ObservationIgnored private let log = Logger(subsystem: "com.chenye.cue", category: "sync")
    @ObservationIgnored private var observer: NSObjectProtocol?

    /// Starts watching, as the app starts.
    func start() {
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { return }
            MainActor.assumeIsolated { self?.saw(event) }
        }
        #if DEBUG
        // Whether the key saved by the app under its old identifier is found (never the key itself).
        note("key \(APIKeyStore.hasOpenAIKey ? "found" : "missing")")
        #endif
        Task {
            let status = try? await CKContainer(identifier: Self.container).accountStatus()
            note("account \(status.map { String(describing: $0.rawValue) } ?? "unknown")")
            // No account, nothing to wait for: the store is all there is.
            if status != .available { looked = true }
        }
    }

    private func saw(_ event: NSPersistentCloudKitContainer.Event) {
        let kind = switch event.type {
        case .setup: "setup"
        case .import: "import"
        case .export: "export"
        @unknown default: "other"
        }
        guard let end = event.endDate else { return note("\(kind) started") }
        let took = String(format: "%.1f", end.timeIntervalSince(event.startDate))
        note("\(kind) \(event.succeeded ? "done" : "failed") in \(took) s\(event.error.map { ": \($0)" } ?? "")")
        if event.type == .import, event.succeeded { looked = true }
    }

    /// In the log (`log show --predicate 'subsystem == "com.chenye.cue"'`), and while developing also in Documents/sync.txt,
    /// to be read off the phone.
    private func note(_ line: String) {
        log.info("\(line, privacy: .public)")
        #if DEBUG
        let file = URL.documentsDirectory.appending(path: "sync.txt")
        let stamped = "\(Date.now.formatted(.iso8601)) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(stamped.utf8))
            try? handle.close()
        } else {
            try? Data(stamped.utf8).write(to: file)
        }
        #endif
    }
}
