import Foundation
import Testing
@testable import T3Code

struct BrowserTabsTests {
    @Test func lateListDoesNotResurrectAClosedTab() throws {
        var state = BrowserTabs()
        let older = list(revision: 4, tabs: [tab("closed"), tab("kept")])
        #expect(try state.reconcile(older))
        #expect(state.apply(event("closed", id: "closed", revision: 5), threadId: "thread") == .changed(reveal: nil))
        #expect(try !state.reconcile(older))
        #expect(state.tabs.map(\.id) == ["kept"])
        #expect(try state.reconcile(list(revision: 5, tabs: [tab("kept")])))
    }

    @Test func agentRevealUsesNewRequestRatherThanEveryNavigation() throws {
        var state = BrowserTabs()
        #expect(try state.reconcile(list(revision: 1, tabs: [tab("existing", reveal: true, request: "old")])))
        let repeated = event("navigated", id: "existing", revision: 2, snapshot: tab("existing", reveal: true, request: "old"))
        let request = event("navigated", id: "existing", revision: 3, snapshot: tab("existing", reveal: true, request: "new"))
        #expect(state.apply(repeated, threadId: "thread") == .changed(reveal: nil))
        #expect(state.apply(request, threadId: "thread") == .changed(reveal: "existing"))
        #expect(state.apply(request, threadId: "thread") == .ignored)
    }

    @Test func desktopOnlyTabsAreNotOfferedAsServerStreams() throws {
        var state = BrowserTabs()
        let desktop = Wire.object(["tabId": .string("desktop"), "runtime": .string("desktop")])
        #expect(try state.reconcile(list(revision: 2, tabs: [desktop, tab("server")])))
        #expect(state.tabs.map(\.id) == ["server"])
    }

    @Test func tabSnapshotsCarryTheirProfileAndDistinguishUnprofiledAgentSessions() throws {
        let named = BrowserTab(.object(["tabId": .string("named"), "runtime": .string("server"), "profileId": .string("profile-one")]))
        #expect(named?.profileID == "profile-one")
        #expect(named?.isolatedAgent == false)
        let agent = BrowserTab(.object(["tabId": .string("agent"), "runtime": .string("server"), "automationOwner": .string("agent-owner")]))
        #expect(agent?.profileID == nil)
        #expect(agent?.isolatedAgent == true)
    }

    @Test func resizeEventsUpdateTabDisplayWithoutChangingTheProfile() throws {
        var state = BrowserTabs()
        let base: Payload = ["tabId": .string("named"), "runtime": .string("server"), "profileId": .string("profile-one")]
        #expect(try state.reconcile(list(revision: 1, tabs: [.object(base)])))
        let changes: Payload = ["zoomFactor": .double(1.25), "colorScheme": .string("dark"),
                                "viewport": .object(["_tag": .string("freeform"), "width": .int(600), "height": .int(900)])]
        let updated = Wire.object(base.merging(changes) { _, new in new })
        #expect(state.apply(event("resized", id: "named", revision: 2, snapshot: updated), threadId: "thread") == .changed(reveal: nil))
        let tab = try #require(state.tabs.first)
        #expect(tab.profileID == "profile-one")
        #expect(tab.display.zoom.factor == 1.25 && tab.display.appearance == .dark)
        #expect(tab.display.viewport.size?.width == 600)
    }

    @Test func inputUsesPageCoordinatesAndIgnoresLetterboxing() {
        let viewport = CGSize(width: 800, height: 400)
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 400)
        #expect(BrowserViewport.pagePoint(CGPoint(x: 200, y: 200), viewport: viewport, bounds: bounds, clamp: false) == CGPoint(x: 400, y: 200))
        #expect(BrowserViewport.pagePoint(CGPoint(x: 200, y: 50), viewport: viewport, bounds: bounds, clamp: false) == nil)
        #expect(BrowserViewport.pagePoint(CGPoint(x: 200, y: 50), viewport: viewport, bounds: bounds, clamp: true) == CGPoint(x: 400, y: 0))
    }

    @Test func addressKeepsLoopbackOnTheHostAndRejectsNonWebSchemes() throws {
        #expect(try BrowserAddress.resolve(" localhost:4321/hello ") == "http://localhost:4321/hello")
        #expect(try BrowserAddress.resolve("example.org") == "https://example.org")
        #expect(try BrowserAddress.resolve("hello world") == "https://duckduckgo.com/?q=hello%20world")
        #expect(throws: ClientError.self) { try BrowserAddress.resolve("javascript:alert(1)") }
        #expect(throws: ClientError.self) { try BrowserAddress.resolve("file:///Users/example") }
    }

    private func tab(_ id: String, reveal: Bool = false, request: String? = nil) -> Wire {
        .object(["tabId": .string(id), "runtime": .string("server"), "reveal": .bool(reveal),
                 "revealRequest": request.map { .object(["id": .string($0)]) } ?? .null])
    }

    private func list(revision: Int, tabs: [Wire]) -> Wire {
        .object(["serverEpoch": .string("epoch"), "revision": .int(revision), "sessions": .array(tabs)])
    }

    private func event(_ type: String, id: String, revision: Int, snapshot: Wire = .null) -> Wire {
        .object(["type": .string(type), "threadId": .string("thread"), "tabId": .string(id),
                 "serverEpoch": .string("epoch"), "revision": .int(revision), "snapshot": snapshot])
    }
}
