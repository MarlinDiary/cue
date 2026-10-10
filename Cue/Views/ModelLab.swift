#if DEBUG
import SwiftUI

/// `-modelLab models` lists the models the key can call, into Documents/lab/models.json. `-modelLab run` has each entry
/// model write the lab words' entries, and draws each word's picture at each quality from the first model's brief, into
/// Documents/lab, with times and token usage, to weigh what each costs against what it gives (user, 2026-10-10: "能不能
/// 对比一下两种质量的结果，包括词条的不同模型"). A run costs real money: about $0.7 with the defaults.
/// `-labWords "a|b"`, `-labModels "model:effort,…"` and `-labQualities "high,medium"` change what is compared.
struct ModelLabView: View {
    @State private var lines: [String] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .task { await ModelLab.run { lines.append($0) } }
    }
}

enum ModelLab {
    static var mode: String? { UserDefaults.standard.string(forKey: "modelLab") }

    static func run(show: @escaping (String) -> Void) async {
        let folder = URL.documentsDirectory.appending(path: "lab")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let log = LabLog(file: folder.appending(path: "log.txt"), show: show)
        switch mode {
        case "models": await listModels(into: folder, log: log)
        case "run": await compare(into: folder, log: log)
        default: log.add("unknown mode \(mode ?? "")")
        }
        log.add("done")
    }

    private static func listModels(into folder: URL, log: LabLog) async {
        guard let key = APIKeyStore.openAIKey else { return log.add("no key") }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            try data.write(to: folder.appending(path: "models.json"))
            let ids = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]])?
                .compactMap { $0["id"] as? String }.sorted() ?? []
            log.add("\(ids.count) models")
            for id in ids { log.add(id) }
        } catch {
            log.add("models failed: \(error)")
        }
    }

    private static func compare(into folder: URL, log: LabLog) async {
        let defaults = UserDefaults.standard
        let words = (defaults.string(forKey: "labWords") ?? "colander|frugal|procrastinate|take for granted|我想委婉地说我再考虑一下")
            .split(separator: "|").map(String.init)
        let models = (defaults.string(forKey: "labModels") ?? "gpt-6.1-sol:low,gpt-6-luna:low,gpt-6-astra:low")
            .split(separator: ",").map { $0.split(separator: ":").map(String.init) }
        let qualities = (defaults.string(forKey: "labQualities") ?? "high,medium").split(separator: ",").map(String.init)
        log.add("words \(words), models \(models), qualities \(qualities)")
        let jobs = words.map { word in
            Task {
                let slug = word.replacingOccurrences(of: " ", with: "-")
                let entries = models.map { pair in
                    Task { () -> String? in
                        let model = pair[0], effort = pair.count > 1 ? pair[1] : "low"
                        let name = "\(slug)--\(model)-\(effort)"
                        do {
                            let result = try await EntryGenerator.labEntry(for: word, model: model, effort: effort)
                            let meta: [String: Any] = ["input": word, "model": model, "effort": effort,
                                                       "seconds": result.seconds, "usage": result.usage,
                                                       "entry": result.json]
                            try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
                                .write(to: folder.appending(path: name + ".json"))
                            log.add(String(format: "%@ %.1f s", name, result.seconds))
                            let entry = try? JSONSerialization.jsonObject(with: Data(result.json.utf8)) as? [String: Any]
                            return entry?["pictureIdea"] as? String
                        } catch {
                            log.add("\(name) failed: \(error)")
                            return nil
                        }
                    }
                }
                // Drawn from the brief of the first model, the app's, as soon as it has one.
                let idea = await entries.first?.value
                let pictures = qualities.map { quality in
                    Task {
                        guard let idea else { return log.add("\(slug) has no brief to draw") }
                        let name = "\(slug)--\(quality)"
                        do {
                            let result = try await ImageGenerator.labIllustration(idea: idea, quality: quality)
                            try result.raw.write(to: folder.appending(path: name + "-raw.png"))
                            try result.kept.write(to: folder.appending(path: name + ".png"))
                            let meta: [String: Any] = ["idea": idea, "quality": quality, "seconds": result.seconds,
                                                       "usage": result.usage]
                            try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
                                .write(to: folder.appending(path: name + ".json"))
                            log.add(String(format: "%@ %.1f s", name, result.seconds))
                        } catch {
                            log.add("\(name) failed: \(error)")
                        }
                    }
                }
                for entry in entries.dropFirst() { _ = await entry.value }
                for picture in pictures { await picture.value }
            }
        }
        for job in jobs { await job.value }
    }
}

/// The lab's progress, on the screen and in Documents/lab/log.txt.
private final class LabLog {
    private let file: URL
    private let show: (String) -> Void
    private var text = ""

    init(file: URL, show: @escaping (String) -> Void) {
        self.file = file
        self.show = show
    }

    func add(_ line: String) {
        show(line)
        text += line + "\n"
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }
}
#endif
