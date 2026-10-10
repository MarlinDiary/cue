import Foundation

/// The prompts AI is given, kept as text files (Resources/Prompts) that Cue's server reads too (server/src/prompts.ts),
/// so a word written through the server and one written with the user's own key are asked for in the same words.
/// `{{name}}` marks where something is filled in.
nonisolated enum Prompts {
    static func text(_ name: String, _ values: [String: String] = [:]) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt")
                ?? Bundle.main.url(forResource: name, withExtension: "txt", subdirectory: "Prompts"),
              var text = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("The prompt “\(name)” isn’t in the app.")
        }
        for (name, value) in values { text = text.replacingOccurrences(of: "{{\(name)}}", with: value) }
        return text
    }
}
