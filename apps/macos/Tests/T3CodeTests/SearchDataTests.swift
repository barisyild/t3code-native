import Foundation
import Testing
@testable import T3Code

struct SearchDataTests {
    @Test func queryLimitsKeepUnicodeIntactAndMatchTheServersMessageThreshold() {
        let prefix = String(repeating: "a", count: 199)
        #expect(SearchText.messageQuery(prefix + "🙂") == prefix)
        #expect(SearchText.limited("  a  ", to: 5) == "  a  ")
        #expect(SearchText.messageWords("ab cd").isEmpty)
        #expect(SearchText.messageWords(" “音楽” ") == ["音楽"])
        #expect(SearchText.messageWords("l’été") == ["l'été"])
    }

    @Test func matchingMessageNeedleUsesTheDisplayedTextAndPrefersAWholeWord() {
        #expect(SearchText.messageNeedle(query: "cafe", snippet: "Cafeteria then Café") == "Café")
        #expect(SearchText.messageNeedle(query: "quick fix", snippet: "A quick fix shipped") == "quick fix")
        #expect(SearchText.messageNeedle(query: "update selector", snippet: "Update the model selector") == "selector")
        #expect(SearchText.ranges(in: "🙂 Café", for: ["cafe"]) == [NSRange(location: 3, length: 4)])
    }

    @Test func aContentHitOpensOnlyWorkspaceFilesAtTheServerReportedPosition() throws {
        let value: Payload = [
            "path": .string("/work/project/Sources/App.swift"), "lineNumber": .int(7), "lineContent": .string("🙂 result"),
            "matchRanges": .array([
                .object(["start": .int(-1), "end": .int(2)]),
                .object(["start": .int(3), "end": .int(9)]),
                .object(["start": .int(5), "end": .int(99)]),
            ]),
        ]
        let hit = try #require(FileSearchHit(.object(value), root: "/work/project", content: true))
        #expect(hit.path == "Sources/App.swift")
        #expect(hit.position?.line == 7)
        #expect(hit.position?.column == 4)
        #expect(hit.ranges == [NSRange(location: 3, length: 6)])
        let other = value.merging(["path": .string("../outside.swift")]) { _, new in new }
        #expect(FileSearchHit(.object(other), root: "/work/project", content: true) == nil)
    }
}
