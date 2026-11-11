import Foundation
import Testing
@testable import T3Code

@MainActor
struct McpAppTests {
    @Test func referencesMustMatchTheProducingToolAndKeepTheSourceThread() throws {
        let page = try fixture(toolName: "mcp__claude_ai_Weather__daily_report")
        #expect(page.threadID == "source-thread")
        #expect(page.itemID == "page-item")
        #expect(page.resource["renderIntent"].string == "mcp-app")
        #expect(page.allow == "clipboard-write")
        #expect(page.allowsFrame(try #require(URL(string: "https://widgets.example.test/chart"))))
        #expect(!page.allowsFrame(try #require(URL(string: "https://unrelated.example.test/chart"))))
        #expect(McpAppPage(try item(toolName: "mcp__external__daily_report")) == nil)
    }

    @Test func writesRequireConsentAndAreRecheckedAgainstTheActivePage() async throws {
        let page = try fixture()
        var calls: [String] = []
        var connected = true
        var active = true
        var approvals: [String] = []
        let session = McpAppSession(page: page, conversationID: "fork", isConnected: { connected }, request: { method, fields in
            #expect(fields["threadId"]?.string == "source-thread")
            #expect(fields["itemId"]?.string == "page-item")
            calls.append(method)
            return .object(["callable": .bool(true), "readOnly": .bool(false), "title": .string("Save forecast")])
        }, sendMessage: { _ in Issue.record("Unexpected message delivery") })
        let input: Wire = .object(["name": .string("save"), "arguments": .object(["city": .string("Oslo")])])
        await #expect(throws: ClientError.self) {
            try await session.callTool(input, approve: { title, detail in
                approvals.append(title)
                #expect(detail.contains("Oslo"))
                return false
            }, requireActive: {})
        }
        #expect(calls == ["mcpApps.toolInfo"])
        #expect(approvals == ["Allow claude.ai Weather to run Save forecast?"])
        await #expect(throws: ClientError.self) {
            try await session.callTool(input, approve: { _, _ in active = false; return true }, requireActive: {
                if !active { throw ClientError.disconnected }
            })
        }
        #expect(calls == ["mcpApps.toolInfo", "mcpApps.toolInfo"])
        connected = false
        await #expect(throws: ClientError.self) { try await session.readResource(.object(["uri": .string("ui://weather/report")])) }
        #expect(calls.count == 2)
    }

    @Test func readsUseTheSourceScopeWhileModelContextUsesTheViewingConversation() async throws {
        let page = try fixture()
        var calls: [String] = []
        let session = McpAppSession(page: page, conversationID: "fork", isConnected: { true }, request: { method, fields in
            #expect(fields["threadId"]?.string == "source-thread")
            #expect(fields["itemId"]?.string == "page-item")
            calls.append(method)
            switch method {
            case "mcpApps.toolInfo": return .object(["callable": .bool(true), "readOnly": .bool(true)])
            case "mcpApps.callTool":
                #expect(fields["name"]?.string == "daily_report")
                return .object(["content": .array([])])
            case "mcpApps.updateModelContext":
                #expect(fields["conversationThreadId"]?.string == "fork")
                #expect(fields["structuredContent"]?["city"].string == "Oslo")
                return .null
            default: throw ClientError.invalidResponse
            }
        }, sendMessage: { _ in Issue.record("Unexpected message delivery") })
        let input: Wire = .object(["name": .string("daily_report"), "arguments": .object([:])])
        _ = try await session.callTool(input, approve: { _, _ in Issue.record("Read-only tool needed approval"); return false }, requireActive: {})
        _ = try await session.updateModelContext(.object(["structuredContent": .object(["city": .string("Oslo")])]))
        #expect(calls == ["mcpApps.toolInfo", "mcpApps.callTool", "mcpApps.updateModelContext"])
    }

    private func fixture(toolName: String = "claude.ai Weather.daily report") throws -> McpAppPage {
        try #require(McpAppPage(try item(toolName: toolName)))
    }

    private func item(toolName: String) throws -> TimelineEntry {
        try #require(TimelineEntry(item: .object([
            "id": .string("page-item"), "threadId": .string("fork"), "ordinal": .int(1), "type": .string("dynamic_tool"),
            "toolName": .string(toolName), "output": .object(["t3McpApp": .object([
                "attachmentId": .string("app-html"), "server": .string("claude.ai Weather"), "tool": .string("daily report"),
                "resourceUri": .string("ui://weather/report"), "permissions": .object(["clipboardWrite": .object([:]), "camera": .bool(true)]),
                "csp": .object(["frameDomains": .array([.string("https://widgets.example.test"), .string("https://bad.test; default-src *")])]),
            ])]),
        ]), isLocal: false, sourceThreadID: "source-thread"))
    }
}
