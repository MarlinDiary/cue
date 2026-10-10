import QuartzCore
import Foundation

/// Temporary: lines about the wall's scrolling and the keyboard, appended to Documents/wall.txt on the phone, to be read
/// off it (`devicectl device copy from … --source Documents/wall.txt`). DEBUG only.
enum WallLog {
    nonisolated(unsafe) private static var handle: FileHandle?

    static func note(_ line: String) {
        #if DEBUG
        let stamped = String(format: "%.3f ", CACurrentMediaTime()) + line + "\n"
        if handle == nil {
            let file = URL.documentsDirectory.appending(path: "wall.txt")
            if !FileManager.default.fileExists(atPath: file.path) { try? Data().write(to: file) }
            handle = try? FileHandle(forWritingTo: file)
            handle?.seekToEndOfFile()
        }
        handle?.write(Data(stamped.utf8))
        #endif
    }
}
