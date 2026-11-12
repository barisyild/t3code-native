import AppKit
import Testing
@testable import T3Code

@MainActor
struct TimelineThoughtsTests {
    @Test func expandedThoughtsStayOpenThroughStreamingAndCompletion() throws {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: 520, height: 260)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let timeline = TimelineView(frame: frame)
        window.contentView = timeline
        let table = try #require((timeline.subviews.first as? NSScrollView)?.documentView as? NSTableView)

        timeline.render([try thought("Checking the project", streaming: true)], runModels: [:], activeRunIDs: ["run"],
                        providers: [], workspacePath: nil)
        let collapsed = try #require(timeline.tableView(table, viewFor: table.tableColumns.first, row: 0))
        let thinking = try #require(descendants(of: collapsed).compactMap { $0 as? NSButton }.first { $0.title == "Thinking…" })
        #expect(descendants(of: collapsed).allSatisfy { !($0 is NSTextView) })
        thinking.performClick(nil)

        let completed = try thought("Checking the project and running the tests.", streaming: false)
        timeline.render([completed], runModels: [:], activeRunIDs: [], providers: [], workspacePath: nil)
        let expanded = try #require(timeline.tableView(table, viewFor: table.tableColumns.first, row: 0))
        let detail = try #require(descendants(of: expanded).compactMap { $0 as? NSTextView }.first)
        #expect(detail.string == "Checking the project and running the tests.")
        #expect(descendants(of: expanded).compactMap { $0 as? NSButton }.contains { $0.title == "Thoughts" })
    }

    @Test func replyFooterWaitsForTheTurnToEnd() throws {
        _ = NSApplication.shared
        let timeline = TimelineView(frame: NSRect(x: 0, y: 0, width: 520, height: 260))
        let table = try #require((timeline.subviews.first as? NSScrollView)?.documentView as? NSTableView)
        timeline.setForkEnabled(true)

        let earlier = try reply("Earlier response", runID: "previous", ordinal: 0)
        let progress = try reply("I’ll run the tests now.", runID: "run", ordinal: 1)
        let activeThought = try thought("Checking the tests", streaming: true, ordinal: 2)
        let finishedThought = try thought("Checked the tests", streaming: false, ordinal: 2)
        let finalReply = try reply("The tests passed.", runID: "run", ordinal: 3)

        func countButtons(_ name: String) -> Int {
            (0..<timeline.numberOfRows(in: table)).compactMap {
                timeline.tableView(table, viewFor: table.tableColumns.first, row: $0)
            }.flatMap { descendants(of: $0) }
                .compactMap { $0 as? NSButton }
                .filter { $0.accessibilityLabel() == name }.count
        }

        timeline.render([earlier, progress, activeThought], runModels: [:], activeRunIDs: ["run"], providers: [], workspacePath: nil)
        #expect(countButtons("Copy reply") == 1)
        #expect(countButtons("Fork from This Response") == 1)

        let entries = [earlier, progress, finishedThought, finalReply]
        timeline.render(entries, runModels: [:], activeRunIDs: ["run"], providers: [], workspacePath: nil)
        #expect(countButtons("Copy reply") == 1)
        #expect(countButtons("Fork from This Response") == 1)

        timeline.render(entries, runModels: [:], activeRunIDs: [], providers: [], workspacePath: nil)
        #expect(countButtons("Copy reply") == 2)
        #expect(countButtons("Fork from This Response") == 2)
    }

    @Test func growingReplyFollowsTheBottomOnlyWhenAlreadyThere() throws {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: 490, height: 220)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let timeline = TimelineView(frame: frame)
        window.contentView = timeline
        let scroll = try #require(timeline.subviews.first as? NSScrollView)
        let table = try #require(scroll.documentView as? NSTableView)
        let history = try (0..<22).map { try reply("Earlier response \($0)", runID: "run", ordinal: $0) }
        let start = try reply("A new answer", runID: "run", ordinal: 22, streaming: true)

        func render(_ entries: [TimelineEntry]) {
            timeline.render(entries, runModels: [:], activeRunIDs: ["run"], providers: [], workspacePath: nil)
            timeline.layoutSubtreeIfNeeded()
        }

        render(history)
        let older = table.rect(ofRow: 5).minY + 2
        scroll.contentView.scroll(to: NSPoint(x: 0, y: older))
        scroll.reflectScrolledClipView(scroll.contentView)
        render(history + [start])
        #expect(abs(scroll.contentView.bounds.minY - older) <= 1)

        scroll.contentView.scroll(to: NSPoint(x: 0, y: table.bounds.maxY - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        let lines = Array(repeating: "trace(\"line\");", count: 44).joined(separator: "\n")
        let grown = try reply("A new answer\n\n~~~haxe\n\(lines)\n~~~", runID: "run", ordinal: 22, streaming: true)
        render(history + [grown])
        #expect(table.bounds.maxY - scroll.contentView.bounds.maxY <= 1)
        window.setContentSize(NSSize(width: 430, height: 160))
        timeline.layoutSubtreeIfNeeded()
        #expect(table.bounds.maxY - scroll.contentView.bounds.maxY <= 1)
    }

    private func reply(_ text: String, runID: String, ordinal: Int, streaming: Bool = false) throws -> TimelineEntry {
        try #require(TimelineEntry(item: .object([
            "id": .string("reply-\(ordinal)"), "threadId": .string("thread"), "runId": .string(runID), "ordinal": .int(ordinal),
            "type": .string("assistant_message"), "status": .string(streaming ? "running" : "completed"), "text": .string(text),
            "streaming": .bool(streaming),
        ])))
    }

    private func thought(_ text: String, streaming: Bool, ordinal: Int = 1) throws -> TimelineEntry {
        try #require(TimelineEntry(item: .object([
            "id": .string("thought"), "threadId": .string("thread"), "runId": .string("run"), "ordinal": .int(ordinal),
            "type": .string("reasoning"), "status": .string(streaming ? "running" : "completed"),
            "text": .string(text), "streaming": .bool(streaming),
        ])))
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
}
