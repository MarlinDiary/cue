import AVFoundation
import CryptoKit
import Observation

/// Reads words and sentences aloud in a natural American voice: OpenAI's gpt-4o-mini-tts, each text asked for once and
/// kept on the phone, so from then on it plays at once, offline too. The user found the system's British voice
/// unnatural and chose American English, voice and IPA alike (2026-10-06). No system voice stands in when a fetch
/// fails: nothing plays, so the failure shows (no fallbacks while the app is being built, user, 2026-10-06).
@MainActor
@Observable
final class Speech {
    static let shared = Speech()

    /// The tapped thing being read right now, so the page can light it up: from the tap, while its voice is fetched.
    /// The thing, not its text: the same text can be on a page twice (a sentence's headword and its line in the
    /// exchange), and both lit up together (user, 2026-10-07: "两边会跟着一块高亮，这个很不舒服").
    private(set) var reader: AnyHashable?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private let playerDelegate = PlayerDelegate()
    /// Fetches under way, so a text asked for twice, by a tap and by `prepare`, is fetched once.
    @ObservationIgnored private var fetches: [String: Task<URL?, Never>] = [:]

    private static let model = "gpt-4o-mini-tts"
    /// One of the two voices OpenAI recommends for the best quality.
    private static let voice = "marin"
    private static let instructions = Prompts.text("speech-instructions")

    /// Where the voices are kept: one file per text, named by everything that shapes its sound. Kept for good (not in
    /// Caches, which the system may empty), but out of backups, since they can always be fetched again.
    private static let directory: URL = {
        var url = URL.applicationSupportDirectory.appending(path: "Speech", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }()

    private init() {
        playerDelegate.onEnd = { [weak self] finished in
            guard let self, finished === self.player else { return }
            self.player = nil
            self.reader = nil
        }
    }

    /// Reads `text` aloud for the thing tapped, `reader`, which lights up meanwhile. `unasked` is for reading nobody
    /// tapped for, as review does when English comes into view: it stays silent while the phone is silenced, so it
    /// never speaks up somewhere quiet; a tap always plays.
    func speak(_ text: String, from reader: AnyHashable, unasked: Bool = false) {
        stop()
        self.reader = reader
        Task {
            let file = await audio(for: text)
            // Another tap since, or this one stopped: say nothing.
            guard self.reader == reader, player == nil else { return }
            if let file, play(file, unasked: unasked) { return }
            self.reader = nil
        }
    }

    /// Whether what `reader` showed is being read.
    func isReading(_ reader: AnyHashable) -> Bool { self.reader == reader }

    /// Fetches a text's voice ahead of a tap, as a page does for its headword, so the first tap plays at once.
    func prepare(_ text: String) {
        Task { _ = await audio(for: text) }
    }

    /// Fetches the voices of many texts ahead of any tap, one after another, so a wall of words doesn't send them all
    /// at once: every card's headword, at launch (user, 2026-10-06: "单词的提前获取/存储好吧"). Texts already kept
    /// cost nothing.
    func prepare(all texts: [String]) {
        Task {
            for text in texts { _ = await audio(for: text) }
        }
    }

    private func stop() {
        player?.stop()
        player = nil
        reader = nil
    }

    private static func file(for text: String) -> URL {
        let key = [model, voice, instructions, text].joined(separator: "\u{1F}")
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(name).mp3")
    }

    /// The text's voice on the phone, fetched the first time; nil without a key or a connection.
    private func audio(for text: String) async -> URL? {
        let file = Self.file(for: text)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        if let fetch = fetches[text] { return await fetch.value }
        guard let access = try? AIAccess.require() else { return nil }
        let fetch = Task<URL?, Never> {
            // Through Cue's server, a text anyone has heard before plays at no cost.
            var request: URLRequest
            switch access {
            case .ownKey(let key):
                request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
                request.httpMethod = "POST"
                request.timeoutInterval = 30
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let body: [String: Any] = ["model": Self.model, "voice": Self.voice, "input": text,
                                           "instructions": Self.instructions, "response_format": "mp3"]
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            case .points:
                guard let toServer = try? CueServer.request("v1/speech", json: ["text": text], timeout: 30) else {
                    return nil
                }
                request = toServer
            }
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (try? CueServer.check(response)) != nil,
                  (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty,
                  (try? data.write(to: file, options: .atomic)) != nil else { return nil }
            return file
        }
        fetches[text] = fetch
        let fetched = await fetch.value
        fetches[text] = nil
        return fetched
    }

    /// Ambient audio is silenced by the phone's silent mode and plays along with whatever else is playing; playback
    /// plays regardless, over other audio turned down.
    private func activateSession(unasked: Bool) {
        let session = AVAudioSession.sharedInstance()
        if unasked {
            try? session.setCategory(.ambient)
        } else {
            try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        }
        try? session.setActive(true)
    }

    private func play(_ file: URL, unasked: Bool) -> Bool {
        activateSession(unasked: unasked)
        guard let player = try? AVAudioPlayer(contentsOf: file) else { return false }
        player.delegate = playerDelegate
        self.player = player
        return player.play()
    }

    /// Tells `Speech` when a voice has finished playing. Separate, because an observable model can't also be an
    /// `NSObject` delegate and still be observed.
    private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
        var onEnd: (@MainActor (AVAudioPlayer) -> Void)?

        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            Task { @MainActor [onEnd] in onEnd?(player) }
        }

        func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
            Task { @MainActor [onEnd] in onEnd?(player) }
        }
    }
}
