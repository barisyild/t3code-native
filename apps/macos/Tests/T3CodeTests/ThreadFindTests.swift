import AppKit
import Testing
@testable import T3Code

struct ThreadFindTests {
    @MainActor @Test func findBarTakesAndRestoresFocusInTheConversationStack() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 530, height: 260),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView()
        let previous = NSTextView()
        let find = ThreadFindBar(workspace: Workspace(persistent: false))
        find.sync(scope: .init(threadID: "thread", connection: UUID(), progressive: true), sequence: 1)
        fill(column([find, previous], alignment: .width), in: container)
        window.contentView = container
        container.layoutSubtreeIfNeeded()
        window.makeFirstResponder(previous)

        find.open()
        #expect((window.firstResponder as? NSTextView)?.isFieldEditor == true)
        find.dismiss()
        #expect(window.firstResponder === previous)
    }

    @Test func neighboringMatchesWrapAndKeepTheirOccurrence() throws {
        let result = try ThreadFindResult(.object([
            "totalMatches": .int(3), "activeIndex": .int(0),
            "match": .object(["entryId": .string("earlier"), "occurrence": .int(0)]),
            "navigation": .array([
                .object(["entryId": .string("earlier"), "startIndex": .int(0), "count": .int(2)]),
                .object(["entryId": .string("latest"), "startIndex": .int(2), "count": .int(1)]),
            ]),
        ]))
        #expect(result.stepping(1)?.match == .init(entryID: "earlier", occurrence: 1))
        #expect(result.stepping(-1)?.match == .init(entryID: "latest", occurrence: 0))
        #expect(result.stepping(-1)?.stepping(1)?.index == 0)
    }

    @Test func progressiveFirstMatchWaitsForTheFullCountBeforeCycling() throws {
        let result = try ThreadFindResult(.object([
            "complete": .bool(false), "totalMatches": .int(1), "activeIndex": .int(0),
            "match": .object(["entryId": .string("early"), "occurrence": .int(0)]),
        ]))
        #expect(result.match?.entryID == "early")
        #expect(result.stepping(1) == nil)
    }

    @Test func highlightsUseServerCaseFoldingAndUTF16Offsets() {
        let text = "👩🏾‍💻 I’m here. I’m also here. İI Σς"
        let ranges = ThreadFindText.ranges(of: "i'm", in: text)
        #expect(ranges.map { (text as NSString).substring(with: $0) } == ["I’m", "I’m"])
        #expect(ThreadFindText.ranges(of: "i", in: "İI") == [NSRange(location: 1, length: 1)])
        #expect(ThreadFindText.ranges(of: "σ", in: "Σς").count == 2)
        #expect(ThreadFindText.ranges(of: "aa", in: "aaa") == [NSRange(location: 0, length: 2)])
    }
}
