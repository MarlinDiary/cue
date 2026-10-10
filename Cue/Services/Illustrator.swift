import OSLog
import SwiftData
import SwiftUI

/// Draws word pictures in the background, so a drawing keeps going after the user leaves the word's page.
/// The page and the wall both read from here to show that a word is being drawn, and what it will show.
@Observable
final class Illustrator {
    static let shared = Illustrator()

    private(set) var drawing: Set<UUID> = []
    /// What each picture still to come shows in its place, typed out where it will be, and when the typing began. Both
    /// stay from the first try until the picture is in, however many tries that takes, so the words never leave or start
    /// over before it comes (user, 2026-10-07: "在图片出来之前，任何情况之下，这个波浪的文字都不能丢").
    private(set) var ideas: [UUID: String] = [:]
    private(set) var startedAt: [UUID: Date] = [:]
    /// When each picture arrived, and its subject's edge and colours, for the moment it comes up in place of the
    /// words, which lean into its shape and take its colours as they go; forgotten once that is over.
    private(set) var finishedAt: [UUID: Date] = [:]
    private(set) var traces: [UUID: Silhouette.Trace] = [:]

    private let log = Logger(subsystem: "com.chenye.cue", category: "drawing")

    func isDrawing(_ word: Word) -> Bool { drawing.contains(word.id) }
    func idea(for word: Word) -> String? { ideas[word.id] }
    func started(for word: Word) -> Date? { startedAt[word.id] }
    func finished(for word: Word) -> Date? { finishedAt[word.id] }
    func trace(for word: Word) -> Silhouette.Trace? { traces[word.id] }

    /// Starts drawing the word's picture, unless it is already being drawn. The picture shows `idea`, or else the idea
    /// in the word's entry; a word with neither waits: `Lexicographer` calls back here as soon as the idea arrives,
    /// while the rest of the entry is still being written.
    ///
    /// Nothing that goes wrong is shown: the picture's words stay in its place. A picture the safety system turns down
    /// is drawn again from a brief written to pass, the same meaning shown another way, up to twice (user, 2026-10-07:
    /// "不能直接给用户报错，而是去找到更不会出问题的提示词"); one cut off by the network, or by a service busy for a moment,
    /// is asked for again once the app is back, up to twice. One that still doesn't come is drawn again when its page
    /// opens or the app starts.
    func draw(_ word: Word, idea: String? = nil) {
        guard AIAccess.isAvailable, let context = word.modelContext, let idea = idea ?? word.entry?.pictureIdea,
              !drawing.contains(word.id) else { return }
        let id = word.id
        // The words come in now, unless they are in place already: a picture still owed from before keeps its words.
        begin(id, idea: idea, typing: word.imageData != nil || word.entry?.pictureIdea == nil)
        Task {
            defer { drawing.remove(id) }
            // The drawing goes on for a while if the user leaves the app.
            let keepAlive = KeepAlive("Drawing a picture")
            defer { keepAlive.end() }
            var brief = idea
            var rewrites = 0, retries = 0
            while true {
                do {
                    let data = try await ImageGenerator.illustration(idea: brief)
                    guard let word = Self.word(id, in: context) else { return }
                    word.imageData = data
                    if rewrites > 0 { keep(brief, for: word) }
                    try? context.save()
                    arrived(id, picture: data)
                    return
                } catch let refusal as ImageGenerator.Refusal where rewrites < 2 {
                    log.notice("Turned down: \(brief, privacy: .public) — \(refusal.answer, privacy: .public)")
                    guard let word = Self.word(id, in: context) else { return }
                    let draft = Lexicographer.shared.draft(for: word)
                    do {
                        brief = try await EntryGenerator.saferPictureIdea(
                            brief, for: draft?.headword ?? word.text, meaning: draft?.summary ?? word.entry?.summary,
                            refusal: refusal.answer)
                        rewrites += 1
                        log.notice("Drawing again from: \(brief, privacy: .public)")
                    } catch {
                        stop(id, brief: rewrites > 0 ? brief : nil, in: context, after: error)
                        return
                    }
                } catch where retries < 2 && Self.worthAskingAgain(error) {
                    retries += 1
                    await Self.untilActive()
                    try? await Task.sleep(for: .seconds(5 * retries))
                } catch {
                    stop(id, brief: rewrites > 0 ? brief : nil, in: context, after: error)
                    return
                }
            }
        }
    }

    /// Whether a request failed for want of a connection (the app was left, the network dropped) or because the
    /// service was busy, rather than being turned down: worth asking again.
    private static func worthAskingAgain(_ error: Error) -> Bool {
        if error is ImageGenerator.Busy { return true }
        guard let error = error as? URLError else { return false }
        return [.networkConnectionLost, .notConnectedToInternet, .timedOut, .cannotConnectToHost, .cannotFindHost,
                .dnsLookupFailed, .dataNotAllowed, .backgroundSessionWasDisconnected].contains(error.code)
    }

    /// Returns once the app is in front again.
    private static func untilActive() async {
        while UIApplication.shared.applicationState != .active {
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// The word as it is now: it may have been deleted while its picture was being drawn.
    private static func word(_ id: UUID, in context: ModelContext) -> Word? {
        try? context.fetch(FetchDescriptor<Word>(predicate: #Predicate { $0.id == id })).first
    }

    private func begin(_ id: UUID, idea: String?, typing: Bool) {
        drawing.insert(id)
        if ideas[id] == nil { ideas[id] = idea }
        if typing, startedAt[id] == nil { startedAt[id] = .now }
    }

    /// The brief written to pass becomes the entry's, so the entry describes the picture as it was drawn and the next
    /// try starts from it.
    private func keep(_ brief: String, for word: Word) {
        guard var entry = word.entry, entry.pictureIdea != brief else { return }
        entry.pictureIdea = brief
        word.entry = entry
    }

    /// A picture that didn't come this time. Its words stay in its place, as for a picture on its way, until it is
    /// drawn again; a redraw that didn't come leaves the old picture, with nothing waiting in its place.
    private func stop(_ id: UUID, brief: String?, in context: ModelContext, after error: Error) {
        log.error("Not drawn this time: \(String(describing: error), privacy: .public)")
        guard let word = Self.word(id, in: context) else { return }
        if let brief {
            keep(brief, for: word)
            try? context.save()
        }
        if word.imageData != nil {
            ideas[id] = nil
            startedAt[id] = nil
        }
    }

    /// Marks the picture's arrival, for the two seconds its coming up takes; then nothing more moves, and nothing
    /// waits in its place.
    private func arrived(_ id: UUID, picture: Data) {
        finishedAt[id] = .now
        traces[id] = Silhouette.trace(picture)
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            finishedAt[id] = nil
            traces[id] = nil
            ideas[id] = nil
            startedAt[id] = nil
            Lexicographer.shared.forgetGeneration(for: id)
        }
    }

    /// Plays the picture coming in for a word that has it already, as for one being drawn: its description in its
    /// place, then at `time` the picture forming from it (`Lexicographer.replay`).
    func replay(_ word: Word, at time: Date) {
        guard let data = word.imageData, !drawing.contains(word.id) else { return }
        let id = word.id
        begin(id, idea: word.entry?.pictureIdea, typing: false)
        Task {
            try? await Task.sleep(for: .seconds(max(time.timeIntervalSinceNow, 0)))
            drawing.remove(id)
            arrived(id, picture: data)
        }
    }

    #if DEBUG
    /// Plays the drawing of a word that already has its picture, so how drawing looks can be checked without paying
    /// for one: launch with `-rehearseDrawing <word>`. Nothing is saved.
    func rehearse(_ word: Word, ideaAfter: Duration = .seconds(3), taking wait: Duration = .seconds(12)) {
        guard let data = word.imageData, !drawing.contains(word.id) else { return }
        let id = word.id
        // As for a new word: first nothing, then the idea arrives and comes in, then the picture.
        begin(id, idea: nil, typing: false)
        Task {
            try? await Task.sleep(for: ideaAfter)
            ideas[id] = word.entry?.pictureIdea
            startedAt[id] = .now
            try? await Task.sleep(for: wait)
            drawing.remove(id)
            arrived(id, picture: data)
        }
    }
    #endif
}
