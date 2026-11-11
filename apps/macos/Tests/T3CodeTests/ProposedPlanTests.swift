import Testing
@testable import T3Code

struct ProposedPlanTests {
    @Test func displayStripsOnlyLeadingHeadingsAndExportsTheOriginal() {
        let source = "# Fix the \"Save\" flow!\r\n\r\n## Summary\r\n\r\nKeep **drafts** intact.\r\n\r\n## Details\r\nUse the active worktree.  \r\n"
        let plan = ProposedPlan(markdown: source)
        #expect(plan.title == "Fix the \"Save\" flow!")
        #expect(plan.displayMarkdown == "Keep **drafts** intact.\n\n## Details\nUse the active worktree.")
        #expect(plan.filename == "fix-the-save-flow.md")
        #expect(plan.exportContents == "# Fix the \"Save\" flow!\r\n\r\n## Summary\r\n\r\nKeep **drafts** intact.\r\n\r\n## Details\r\nUse the active worktree.\n")
        #expect(!plan.canCollapse)
        let untitled = ProposedPlan(markdown: "A paragraph first.\n\n## Details\nKeep the heading.")
        #expect(untitled.displayMarkdown == untitled.markdown)
        #expect(untitled.title == "Details")
        #expect(ProposedPlan(markdown: "A plan without headings.").title == "Proposed plan")
        #expect(ProposedPlan(markdown: "# 🧑🏽‍💻").filename == "plan.md")
    }

    @Test func previewCountsContentLinesAndFindRevealsTheWholePlan() {
        let source = "# Search restoration\n\n## Summary\n\n" + (1...22).map { "Step \($0)\n" }.joined(separator: "\n")
        let plan = ProposedPlan(markdown: source)
        let expected = (1...10).map { "Step \($0)" }.joined(separator: "\n\n") + "\n\n..."
        #expect(plan.canCollapse)
        #expect(plan.body(expanded: false, finding: false) == expected)
        #expect(plan.body(expanded: true, finding: false) == plan.displayMarkdown)
        #expect(plan.body(expanded: false, finding: true) == plan.displayMarkdown)
        #expect(ProposedPlan(markdown: String(repeating: "🟣", count: 451)).canCollapse)
        #expect(!ProposedPlan(markdown: String(repeating: "a", count: 900)).canCollapse)
        #expect(ProposedPlan(markdown: String(repeating: "a", count: 901)).canCollapse)
        #expect(ProposedPlan(markdown: "# Heading only\n" + String(repeating: "\n", count: 21)).body(expanded: false, finding: false) == "Heading only")
    }
}
