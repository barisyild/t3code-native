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

        timeline.render([try thought("Checking the project", streaming: true)], runModels: [:], providers: [], workspacePath: nil)
        let collapsed = try #require(timeline.tableView(table, viewFor: table.tableColumns.first, row: 0))
        let thinking = try #require(descendants(of: collapsed).compactMap { $0 as? NSButton }.first { $0.title == "Thinking…" })
        #expect(descendants(of: collapsed).allSatisfy { !($0 is NSTextView) })
        thinking.performClick(nil)

        let completed = try thought("Checking the project and running the tests.", streaming: false)
        timeline.render([completed], runModels: [:], providers: [], workspacePath: nil)
        let expanded = try #require(timeline.tableView(table, viewFor: table.tableColumns.first, row: 0))
        let detail = try #require(descendants(of: expanded).compactMap { $0 as? NSTextView }.first)
        #expect(detail.string == "Checking the project and running the tests.")
        #expect(descendants(of: expanded).compactMap { $0 as? NSButton }.contains { $0.title == "Thoughts" })
    }

    private func thought(_ text: String, streaming: Bool) throws -> TimelineEntry {
        try #require(TimelineEntry(item: .object([
            "id": .string("thought"), "threadId": .string("thread"), "runId": .string("run"), "ordinal": .int(1),
            "type": .string("reasoning"), "status": .string(streaming ? "running" : "completed"),
            "text": .string(text), "streaming": .bool(streaming),
        ])))
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
}
