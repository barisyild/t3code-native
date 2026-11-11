import Foundation
import Testing
@testable import T3Code

struct HtmlReplyTests {
    @Test func onlyCompletedT3HtmlToolsWithSuccessfulOutputBecomePages() throws {
        let output: Wire = .object(["htmlRender": .object([
            "attachmentId": .string("thread-page-html"), "title": .string(" Run / summary "), "height": .int(310),
        ])])
        for tool in ["html_render", "mcp__t3-code__html_render", "mcp__t3-code-direct__html_render",
                     "t3-code.html_render", "@t3-code/html_render", "t3-code-thread_1_html_render completed"] {
            let page = try #require(HtmlReplyReference(toolItem: item(tool: tool, output: output)))
            #expect(page.title == "Run / summary")
            #expect(page.resource["fileName"].string == "Run summary.html")
        }
        #expect(HtmlReplyReference(toolItem: item(tool: "mcp__external__html_render", output: output)) == nil)
        #expect(HtmlReplyReference(toolItem: item(tool: "html_render", status: "running", output: output)) == nil)
        #expect(HtmlReplyReference(toolItem: item(tool: "html_render", output: .object([
            "isError": .bool(true), "structuredContent": output,
        ]))) == nil)
    }

    @Test func nestedResultAndViewportMeasurementsMatchPublishedPages() throws {
        let output = #"{"htmlRender":{"attachmentId":"id-html","title":"Report","height":310,"heights":[[728,270],[320,590],[640,340]]}}"#
        let page = try #require(HtmlReplyReference(toolItem: item(tool: "t3-code.html_render", output: .object([
            "content": .array([.object(["type": .string("text"), "text": .string(output)])]),
        ]))))
        #expect(page.frameHeight(width: 610, zoom: 1) == 590)
        #expect(page.frameHeight(width: 640, zoom: 1) == 340)
        #expect(page.frameHeight(width: 800, zoom: 1.25) == 425)
        #expect(page.frameHeight(width: 640, zoom: 1.25, liveHeight: 432) == 540)
        #expect(page.frameHeight(width: 640, zoom: 2, liveHeight: 15_000) == 20_000)
    }

    private func item(tool: String, status: String = "completed", output: Wire) -> Wire {
        .object(["type": .string("dynamic_tool"), "status": .string(status), "toolName": .string(tool), "output": output])
    }
}
