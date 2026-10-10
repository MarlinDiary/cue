import SwiftUI

/// Chinese running text with English inside it, as in usage notes and answers. The English is set in the page's serif,
/// like the examples and phrases, and reads itself aloud when tapped, lighting up while it plays (`Reading`): on a word
/// page, English in serif can always be heard.
struct MixedText: View {
    let text: String
    var font: Font
    var englishFont: Font

    private let speech = Speech.shared
    @Environment(\.readingColor) private var readingColor
    /// This text, as what was tapped while a piece of its English is read (with the piece's place in it).
    @State private var reader = UUID()

    init(_ text: String, font: Font = .body, englishFont: Font = .system(.body, design: .serif)) {
        self.text = text
        self.font = font
        self.englishFont = englishFont
    }

    var body: some View {
        // Which piece of this text's English is being read, if any.
        let reading = (speech.reader?.base as? Piece.Reader).flatMap { $0.text == reader ? $0.piece : nil }
        Self.pieces(of: text).enumerated()
            .reduce(Text(verbatim: "")) { text, piece in Text("\(text)\(styled(piece.element, at: piece.offset))") }
            .font(font)
            .lineSpacing(4)
            .animation(.reading(reading != nil), value: reading)
            // Text has no tappable runs short of links, which would turn the English blue; so find the run under the
            // finger in the laid-out text instead.
            .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
                GeometryReader { proxy in
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture { location in
                            if let english = Self.english(at: location, in: layouts, proxy: proxy) {
                                speech.speak(english.text, from: Piece.Reader(text: reader, piece: english.piece))
                            }
                        }
                }
            }
    }

    private func styled(_ piece: Piece, at index: Int) -> Text {
        guard piece.isEnglish else { return Text(verbatim: piece.text) }
        let reading = speech.isReading(Piece.Reader(text: reader, piece: index))
        return Text(verbatim: piece.text)
            .font(englishFont)
            .foregroundStyle(reading ? Reading.lit(readingColor) : AnyShapeStyle(.primary))
            .customAttribute(English(text: piece.text, piece: index))
    }

    /// Marks a run of English in the laid-out text, with what to say when it is tapped and which piece it is.
    private struct English: TextAttribute {
        var text: String
        var piece: Int
    }

    private static func english(at location: CGPoint, in layouts: [Text.LayoutKey.AnchoredLayout],
                                proxy: GeometryProxy) -> English? {
        for anchored in layouts {
            let origin = proxy[anchored.origin]
            for line in anchored.layout {
                for run in line {
                    guard let english = run[English.self] else { continue }
                    // A little slack around the glyphs, so a word is easy to hit.
                    let bounds = run.typographicBounds.rect
                        .offsetBy(dx: origin.x, dy: origin.y)
                        .insetBy(dx: -4, dy: -6)
                    if bounds.contains(location) { return english }
                }
            }
        }
        return nil
    }

    struct Piece: Equatable {
        var text: String
        var isEnglish: Bool

        /// A piece of English in one text, as what was tapped while it is read.
        struct Reader: Hashable {
            var text: UUID
            var piece: Int
        }
    }

    /// Splits text into Chinese and English. A stretch of English starts at a Latin letter and runs on through
    /// letters, digits, spaces and an English sentence's own punctuation; Chinese characters and full-width
    /// punctuation end it, and a trailing space, comma, colon or semicolon goes back to the Chinese around it.
    static func pieces(of text: String) -> [Piece] {
        var pieces: [Piece] = []
        var index = text.startIndex
        for match in text.matches(of: /[A-Za-z][A-Za-z0-9'’\-\s,.;:!?…\/&]*/) {
            var end = match.range.upperBound
            while end > match.range.lowerBound {
                let last = text[text.index(before: end)]
                guard last.isWhitespace || ",;:".contains(last) else { break }
                end = text.index(before: end)
            }
            if index < match.range.lowerBound {
                pieces.append(Piece(text: String(text[index..<match.range.lowerBound]), isEnglish: false))
            }
            pieces.append(Piece(text: String(text[match.range.lowerBound..<end]), isEnglish: true))
            index = end
        }
        if index < text.endIndex { pieces.append(Piece(text: String(text[index...]), isEnglish: false)) }
        return pieces
    }
}
