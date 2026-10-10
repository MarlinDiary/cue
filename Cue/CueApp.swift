import SwiftUI
import SwiftData

@main
struct CueApp: App {
    /// The words and the conversations, kept on the phone and in the user's iCloud (`CloudSync`), so they come back on
    /// their other devices, and after the app is deleted and installed again (user, 2026-10-08: "iCloud上删除软件也不会
    /// 丢的吧？…做 iCloud 同步吧"). A store that doesn't open stops the app rather than being thrown away to start over,
    /// as it used to be when the words changed shape during development: it holds what the user has kept.
    private let container: ModelContainer = {
        let schema = Schema([Word.self, Conversation.self])
        let configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .private(CloudSync.container))
        do {
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            fatalError("The store didn't open: \(error)")
        }
    }()

    init() {
        Chats.shared.attach(container.mainContext)
        CloudSync.shared.start()
        // Points bought and not yet credited, from before or from elsewhere.
        PointStore.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "ringOverlap") {
                // `-ringOverlap YES`: review's ring put through changes on top of each other.
                RingOverlapScript()
            } else if ModelLab.mode != nil {
                // `-modelLab models|run` compares the AI models and the picture qualities (`ModelLab`), at real cost.
                ModelLabView()
            } else {
                HomeView()
            }
            #else
            HomeView()
            #endif
        }
        .modelContainer(container)
    }
}
