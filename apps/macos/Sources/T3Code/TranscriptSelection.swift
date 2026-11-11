import AppKit

struct TranscriptSelection {
    private struct Replacement {
        let shown: NSRange
        let source: NSRange
    }

    let text: String
    private let replacements: [Replacement]

    init(_ attributed: NSAttributedString) {
        let text = NSMutableString(string: attributed.string)
        var replacements: [Replacement] = []
        var shift = 0
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            let source: String
            if let terminal = value as? TerminalContextAttachment {
                source = terminal.context.markdown
            } else if value is NSTextAttachment,
                      let code = attributed.attribute(TranscriptCode.attribute, at: range.location, effectiveRange: nil) as? TranscriptCode,
                      code.artwork != nil {
                source = code.text
            } else { return }
            text.replaceCharacters(in: NSRange(location: range.location + shift, length: range.length), with: source)
            let replacement = NSRange(location: range.location + shift, length: source.utf16.count)
            replacements.append(Replacement(shown: range, source: replacement))
            shift += replacement.length - range.length
        }
        self.text = text as String
        self.replacements = replacements
    }

    func containsInlineContent(_ shown: NSRange) -> Bool {
        replacements.contains { NSIntersectionRange(shown, $0.shown).length > 0 }
    }

    func sourceRange(for shown: NSRange) -> NSRange {
        let start = sourceOffset(shown.location)
        let end = sourceOffset(NSMaxRange(shown))
        return NSRange(location: start, length: end - start)
    }

    func displayedRange(for source: NSRange) -> NSRange {
        let start = displayedOffset(source.location, isEnd: false)
        let end = displayedOffset(NSMaxRange(source), isEnd: source.length > 0)
        return NSRange(location: start, length: end - start)
    }

    private func sourceOffset(_ offset: Int) -> Int {
        guard let previous = replacements.last(where: { NSMaxRange($0.shown) <= offset }) else { return offset }
        return NSMaxRange(previous.source) + offset - NSMaxRange(previous.shown)
    }

    private func displayedOffset(_ offset: Int, isEnd: Bool) -> Int {
        var shift = 0
        for replacement in replacements {
            if offset <= replacement.source.location { break }
            if offset < NSMaxRange(replacement.source) {
                return isEnd ? NSMaxRange(replacement.shown) : replacement.shown.location
            }
            shift = NSMaxRange(replacement.shown) - NSMaxRange(replacement.source)
        }
        return offset + shift
    }
}
