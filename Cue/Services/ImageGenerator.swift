import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers

/// Draws a word's illustration with GPT Image 2.5 Sunburst at medium quality: one object or small scene on a transparent
/// background. Medium since 2026-10-10: beside high, at the size the app shows a picture, the two looked alike (medium a
/// little softer and grainier only when magnified), for about a quarter of the price ($0.015 a picture against $0.055)
/// and in about 21 s rather than 37 (`ModelLab`'s comparison; user: "改成中等质量吧").
///
/// The app calls OpenAI directly with the user's own API key from Settings.
enum ImageGenerator {
    /// Realistic objects, and people as hyperrealistic 1:6 collectible figures, so each word looks like a
    /// model someone spent days on. No shadows: the glass card has no floor to cast one on. One idea per picture,
    /// never a collage of symbols. Hyperrealism was kept on 2026-10-05 after a side-by-side with a hand-painted resin
    /// figurine style: the user preferred the crisper real materials, accepting that animals, plants and food come out
    /// looking photographed (a physical description of a figurine medium is what would change that).
    private static let style = Prompts.text("picture-style")

    /// Draws the entry's picture idea, as the sample pictures were drawn from a written scene. Only the idea goes into
    /// the prompt, never the user's sentence or the Chinese definition. A blind test on 2026-10-05 chose pictures
    /// drawn this way over pictures drawn from the bare word 8–0, concrete and abstract words alike, so every word
    /// waits for its entry before it is drawn. Only the finished picture is asked for: the rough stages the service
    /// can stream were tried on 2026-10-05/06 and dropped, since a smudge sharpening looked worse than the finished
    /// picture coming up out of a blur, and they cost about $0.007 a picture.
    static func illustration(idea: String) async throws -> Data {
        let access = try AIAccess.require()
        #if DEBUG
        // `-refuseDrawings <n>`: the first n pictures of a run are turned down as the safety system turns one down,
        // without asking the service, to watch a picture drawn again from a safer brief. Relaunch before each check:
        // the count lasts the run.
        if fakeRefusals > 0 {
            fakeRefusals -= 1
            try await Task.sleep(for: .seconds(4))
            throw Refusal(answer: #"{"error":{"code":"moderation_blocked","message":"Your request was rejected by the safety system."}}"#)
        }
        #endif
        let prompt = "\(style) Subject: \(idea.hasSuffix(".") ? String(idea.dropLast()) : idea)."

        // One call, one picture. A picture that still comes out cut off or wrong is redrawn by hand from the page.
        // Through Cue's server, a word someone has added before comes with the picture drawn for them.
        switch access {
        case .ownKey(let key):
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/images/generations")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 120
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": "gpt-image-2.5-sunburst",
                "prompt": prompt,
                "size": "1024x1024",
                "quality": "medium",
                "background": "transparent",
                "output_format": "png",
            ])
            return try await fetch(request)
        case .points:
            return try await fetch(CueServer.request("v1/picture", json: ["idea": idea], timeout: 120))
        }
    }

    #if DEBUG
    private static var fakeRefusals = UserDefaults.standard.integer(forKey: "refuseDrawings")
    #endif

    /// The service's safety system turned the picture down, for what the prompt asked for or for what came out (it
    /// judges the finished picture too). `answer` is all the service said, which names the reason when it can.
    nonisolated struct Refusal: Error {
        var answer: String
    }

    /// The service is busy or down for a moment: worth asking again shortly.
    nonisolated struct Busy: Error {
        var message: String
    }

    /// Fetches and trims the picture away from the main thread: a megabyte or two of base64 to decode.
    @concurrent
    private nonisolated static func fetch(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        try CueServer.check(response)
        // Cue's server sends the picture itself.
        if (response as? HTTPURLResponse)?.statusCode == 200,
           (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("image/") == true {
            return ImageNormalizer.trimmed(data) ?? downscaled(data) ?? data
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let error = json?["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "The image service returned an error."
            if error?["code"] as? String == "moderation_blocked" {
                throw Refusal(answer: String(decoding: data, as: UTF8.self))
            }
            if status >= 500 || error?["code"] as? String == "rate_limit_exceeded" { throw Busy(message: message) }
            throw OpenAIError.server(message)
        }
        guard let first = (json?["data"] as? [[String: Any]])?.first, let base64 = first["b64_json"] as? String,
              let png = Data(base64Encoded: base64) else {
            throw OpenAIError.server("The image service returned an empty picture.")
        }
        return ImageNormalizer.trimmed(png) ?? downscaled(png) ?? png
    }

    /// 768-pixel PNG, keeping the alpha channel.
    private nonisolated static func downscaled(_ png: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 768,
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}

#if DEBUG
extension ImageGenerator {
    /// For `ModelLab`: the picture for `idea` at `quality`, as the service sends it and as the app keeps it, with the
    /// response's token usage and how long it took.
    static func labIllustration(idea: String, quality: String) async throws
        -> (raw: Data, kept: Data, usage: [String: Any], seconds: Double) {
        guard let key = APIKeyStore.openAIKey else { throw OpenAIError.missingKey }
        let prompt = "\(style) Subject: \(idea.hasSuffix(".") ? String(idea.dropLast()) : idea)."
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/images/generations")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-image-2.5-sunburst",
            "prompt": prompt,
            "size": "1024x1024",
            "quality": quality,
            "background": "transparent",
            "output_format": "png",
        ])
        let start = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let seconds = Date().timeIntervalSince(start)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let first = (json?["data"] as? [[String: Any]])?.first, let base64 = first["b64_json"] as? String,
              let raw = Data(base64Encoded: base64) else {
            throw OpenAIError.server(String(decoding: data, as: UTF8.self))
        }
        return (raw, ImageNormalizer.trimmed(raw) ?? downscaled(raw) ?? raw, json?["usage"] as? [String: Any] ?? [:],
                seconds)
    }
}
#endif
