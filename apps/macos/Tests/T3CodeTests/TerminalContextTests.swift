import AppKit
import SwiftTerm
import Testing
@testable import T3Code

struct TerminalContextTests {
    @MainActor
    @Test func selectionUsesBufferRowsAcrossWrapsAndExcludesTheLastBoundary() throws {
        let view = SwiftTerm.TerminalView(frame: NSRect(x: 0, y: 0, width: 160, height: 120))
        let terminal = view.getTerminal()
        terminal.resize(cols: 6, rows: 6)
        terminal.feed(text: "abcdefgh\r\nnext\r\n")
        let start = Position(col: 1, row: 0)
        let end = Position(col: 0, row: 3)
        let capture = try #require(TerminalSelection.capture(from: end, to: start, columns: terminal.cols,
                                                             read: { terminal.getText(start: $0, end: $1) }))
        #expect(capture == TerminalSelection(lineStart: 1, lineEnd: 3, text: "bcdef\ngh\nnext"))
    }

    @Test func retainedRecordsFollowTheMessageAndDeduplicateRepeatedReferences() throws {
        let selection = TerminalSelection(lineStart: 12, lineEnd: 13, text: "  first\nsecond")
        let context = try #require(TerminalContext(terminalID: "term-1", terminalLabel: "[Tests]\\ results", selection: selection))
        let unrelated = try #require(TerminalContext(terminalID: "term-2", terminalLabel: "Other", selection: selection))
        #expect(TerminalContext(context.record) == context)
        #expect(context.label == "Tests results lines 12-13")
        let prompt = "Compare \(context.markdown) to \(context.markdown)."
        #expect(TerminalContext.referencedRecords(in: prompt, records: [unrelated.record, context.record]) == [context.record])
        #expect(TerminalContext.retaining([context.record], in: "Edited") == [])
        #expect(TerminalContext.plainText(prompt, records: [context.record]) == "Compare \(context.label) to \(context.label).")
        let limited = TerminalContext.bounded(String(repeating: "a", count: 63_999) + "😀", to: 64_000)
        #expect(limited.utf16.count == 63_999)
    }

    @MainActor
    @Test func htmlClipboardRestoresOnlyTerminalRecordsInTheSelection() throws {
        let selection = TerminalSelection(lineStart: 8, lineEnd: 8, text: "x < y && y > 0")
        let context = try #require(TerminalContext(terminalID: "term-1", terminalLabel: "Build", selection: selection))
        let copy = CitationTextView()
        copy.enableCitationEditing()
        copy.terminalClipboardSource = .init(environmentID: "source-env", threadID: "source-thread")
        copy.setPromptSource("Review \(context.markdown)", contextRecords: [context.record])
        let chip = (copy.string as NSString).range(of: "\u{fffc}")
        try #require(chip.location != NSNotFound)
        copy.setSelectedRange(chip)
        let clipboard = NSPasteboard(name: .init("T3TerminalTest-\(UUID())"))
        defer { clipboard.releaseGlobally() }
        clipboard.declareTypes([.string, .html], owner: nil)
        #expect(copy.writeSelection(to: clipboard, type: .string))
        #expect(copy.writeSelection(to: clipboard, type: .html))
        #expect(clipboard.string(forType: .string) == context.markdown)
        #expect(TerminalContextClipboard.read(from: clipboard, text: "Other") == [])

        let pasted = CitationTextView()
        pasted.enableCitationEditing()
        #expect(pasted.readSelection(from: clipboard, type: .string))
        #expect(pasted.string == "\u{fffc}")
        #expect(pasted.promptSource == context.markdown)
        #expect(pasted.terminalContextRecords == [context.record])
    }
}
