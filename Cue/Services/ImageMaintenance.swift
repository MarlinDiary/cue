import Foundation
import SwiftData

/// One-off fixes to images and photos already in the store.
enum ImageMaintenance {
    private static let trimmedKey = "imagesTrimmed.v1"
    private static let photosRemovedKey = "unnamedPhotosRemoved.v1"

    /// Images saved before trimming existed keep their uneven margins; trim them once.
    @MainActor
    static func trimStoredImagesOnce(in context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: trimmedKey) else { return }
        let words = (try? context.fetch(FetchDescriptor<Word>())) ?? []
        for word in words {
            if let data = word.imageData, let trimmed = ImageNormalizer.trimmed(data) {
                word.imageData = trimmed
            }
        }
        try? context.save()
        UserDefaults.standard.set(true, forKey: trimmedKey)
    }

    /// Cards could once be added from a photo. One AI never named has no text, and with photos gone nothing can name
    /// it now, so it would only be a blank card: remove those once.
    @MainActor
    static func removeUnnamedPhotosOnce(in context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: photosRemovedKey) else { return }
        let words = (try? context.fetch(FetchDescriptor<Word>())) ?? []
        for word in words where word.text.isEmpty {
            context.delete(word)
        }
        try? context.save()
        UserDefaults.standard.set(true, forKey: photosRemovedKey)
    }
}
