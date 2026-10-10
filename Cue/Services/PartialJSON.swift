import Foundation

/// Makes a JSON text that was cut off mid-stream parseable: it keeps the text up to the last complete value and closes
/// whatever arrays and objects are still open. A string that is still arriving is left out until it is complete, so
/// every field it lets through is final.
nonisolated enum PartialJSON {
    static func completed(_ text: String) -> Data? {
        let bytes = Array(text.utf8)
        let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\")
        let openObject = UInt8(ascii: "{"), openArray = UInt8(ascii: "[")
        let closeObject = UInt8(ascii: "}"), closeArray = UInt8(ascii: "]")
        let colon = UInt8(ascii: ":"), comma = UInt8(ascii: ",")
        let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]

        /// One open array or object, and whether an object is waiting for a key (rather than for a value).
        struct Container {
            var isObject: Bool
            var expectsKey: Bool
        }
        var stack: [Container] = []
        /// Where the text can be cut, and what then closes it.
        var cut: (end: Int, closers: [UInt8])?
        func closers() -> [UInt8] { stack.reversed().map { $0.isObject ? closeObject : closeArray } }
        func valueEnded(at end: Int) { cut = (end, closers()) }

        var i = 0
        scan: while i < bytes.count {
            let byte = bytes[i]
            if whitespace.contains(byte) {
                i += 1
            } else if byte == quote {
                var j = i + 1
                while j < bytes.count, bytes[j] != quote { j += bytes[j] == backslash ? 2 : 1 }
                guard j < bytes.count else { break scan } // The string is still arriving.
                if let last = stack.last, last.isObject, last.expectsKey {
                    stack[stack.count - 1].expectsKey = false
                } else {
                    valueEnded(at: j + 1)
                }
                i = j + 1
            } else if byte == openObject || byte == openArray {
                stack.append(Container(isObject: byte == openObject, expectsKey: byte == openObject))
                cut = (i + 1, closers())
                i += 1
            } else if byte == closeObject || byte == closeArray {
                guard !stack.isEmpty else { break scan }
                stack.removeLast()
                valueEnded(at: i + 1)
                i += 1
            } else if byte == colon {
                i += 1
            } else if byte == comma {
                if let last = stack.last, last.isObject { stack[stack.count - 1].expectsKey = true }
                i += 1
            } else {
                // A literal (null, true, false or a number) is complete only once something follows it.
                var j = i
                while j < bytes.count, !whitespace.contains(bytes[j]),
                      ![comma, closeObject, closeArray].contains(bytes[j]) { j += 1 }
                guard j < bytes.count else { break scan }
                valueEnded(at: j)
                i = j
            }
        }
        guard let cut else { return nil }
        return Data(bytes[..<cut.end] + cut.closers)
    }
}
