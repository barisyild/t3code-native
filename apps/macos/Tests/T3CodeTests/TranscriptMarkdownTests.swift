import AppKit
import Testing
@testable import T3Code

@MainActor
struct TranscriptMarkdownTests {
    @Test func tableKeepsEmptyCellsAlignmentAndInlineLinks() throws {
        let text = TranscriptText.markdown(
            """
            | Step | Time | Result |
            | :--- | ---: | :---: |
            | Read | | [Report](https://example.com/report) |
            | Edit | 12 | A \\| B |
            """,
            role: .assistant
        )
        #expect(text.string == "Step\nTime\nResult\nRead\n\nReport\nEdit\n12\nA | B\n")
        let first = try cell(in: text, at: 0)
        let empty = try cell(in: text, at: "Step\nTime\nResult\nRead\n".utf16.count)
        let reportIndex = (text.string as NSString).range(of: "Report").location
        let report = try cell(in: text, at: reportIndex)
        #expect(first.block.table.numberOfColumns == 3)
        #expect(empty.block.table === first.block.table && report.block.table === first.block.table)
        #expect(empty.block.startingRow == 1 && empty.block.startingColumn == 1 && empty.style.alignment == .right)
        #expect(report.block.startingRow == 1 && report.block.startingColumn == 2 && report.style.alignment == .center)
        #expect((text.attribute(.link, at: reportIndex, effectiveRange: nil) as? URL)?.absoluteString == "https://example.com/report")
    }

    @Test func streamingAndFinishedCodeKeepTheSameCopyText() throws {
        let partial = "Intro\n\n~~~swift\n  print(\"value\")  \n\n"
        let open = TranscriptText.markdown(partial, role: .assistant)
        let closed = TranscriptText.markdown(partial + "~~~\n\nAfter", role: .assistant)
        for text in [open, closed] {
            let position = (text.string as NSString).range(of: "print").location
            #expect(position != NSNotFound)
            let code = try #require(position != NSNotFound ? text.attribute(TranscriptCode.attribute, at: position, effectiveRange: nil) as? TranscriptCode : nil)
            #expect(code.text == "  print(\"value\")  \n")
            let style = try #require(text.attribute(.paragraphStyle, at: position, effectiveRange: nil) as? NSParagraphStyle)
            #expect(style.textBlocks.count == 1 && style.lineBreakMode == .byCharWrapping)
        }
        let after = (closed.string as NSString).range(of: "After").location
        #expect(after != NSNotFound)
        if after != NSNotFound { #expect(closed.attribute(TranscriptCode.attribute, at: after, effectiveRange: nil) == nil) }
    }

    @Test func proseStillProvidesFileAndCitationLinksAlongsideBlocks() throws {
        let citation = try #require(AssistantCitation.selection(environmentID: "env", threadID: "thread", messageID: "reply",
                                                                 rendered: "Keep this", range: NSRange(location: 0, length: 9)))
        let text = TranscriptText.markdown("""
            ## Update

            1. Read `Sources/Main.swift:8`
            2. \(citation.markdown)

            Two lines
            stay separate.
            """, role: .assistant, fileRoot: "/tmp/project")
        #expect(text.string == "Update\n1.\tRead Sources/Main.swift:8\n2.\t″ Keep this\nTwo lines\nstay separate.")
        let fileIndex = (text.string as NSString).range(of: "Sources/Main.swift").location
        let citationIndex = (text.string as NSString).range(of: "″ Keep this").location
        let file = try #require(fileIndex != NSNotFound ? text.attribute(.link, at: fileIndex, effectiveRange: nil) as? URL : nil)
        let link = try #require(citationIndex != NSNotFound ? text.attribute(.link, at: citationIndex, effectiveRange: nil) as? URL : nil)
        #expect(WorkspaceFileReference.isFileLink(file))
        #expect(AssistantCitation.parse(link.absoluteString) == citation)
    }

    @Test func onlyClosedArtworkFencesRequestRendering() throws {
        let diagram = "flowchart LR\n  A[Draft] --> B[Send]"
        let fenced = TranscriptText.markdown("```mermaid\n\(diagram)\n```", darkArtwork: false)
        let artwork = try #require(TranscriptArtwork.missing(in: fenced).first)
        #expect(artwork == TranscriptArtwork(kind: .mermaid, source: diagram, dark: false))
        #expect(fenced.string == diagram + "\n")

        let quoted = TranscriptText.markdown("> ~~~math\r\n> \\frac{a}{b}\r\n> ~~~")
        #expect(TranscriptArtwork.missing(in: quoted) == [TranscriptArtwork(kind: .math, source: "\\frac{a}{b}", dark: true)])

        for unfinished in ["```mermaid\n\(diagram)", "````mermaid\n\(diagram)\n```", "~~~math\nx^2\n~~~ still streaming"] {
            let content = TranscriptText.markdown(unfinished)
            #expect(TranscriptArtwork.missing(in: content).isEmpty)
            #expect(content.length > 0)
        }
    }

    @Test func renderedArtworkRetainsSourceForCopyingSearchingAndCitations() throws {
        let equation = "\\frac{a}{b} + β"
        let source = "Before 😀\n" + equation + "\nAfter"
        let preview = NSMutableAttributedString(string: "Before 😀\n")
        let attachment = NSTextAttachment()
        let glyph = NSMutableAttributedString(attachment: attachment)
        glyph.addAttribute(TranscriptCode.attribute, value: TranscriptCode(equation, artwork: .init(kind: .math, source: equation, dark: true)),
                           range: NSRange(location: 0, length: 1))
        let shown = NSRange(location: preview.length, length: glyph.length)
        preview.append(glyph)
        preview.append(NSAttributedString(string: "\nAfter"))

        let selection = TranscriptSelection(preview)
        #expect(selection.text == source)
        #expect(selection.containsInlineContent(shown))
        let selected = selection.sourceRange(for: shown)
        #expect((source as NSString).substring(with: selected) == equation)
        let query = try #require(ThreadFindText.ranges(of: "β", in: selection.text).first)
        #expect(selection.displayedRange(for: query) == shown)
        let citation = try #require(AssistantCitation.selection(environmentID: "env", threadID: "thread", messageID: "reply",
                                                                 rendered: selection.text, range: selected))
        let reopened = try #require(citation.range(in: selection.text))
        #expect(selection.displayedRange(for: reopened) == shown)
    }

    @Test func sharedMathParserUsesAuthoredOffsetsAndPreservesOrdinaryMarkdown() async throws {
        let parser = TranscriptMathParser(asset: mathAsset())
        let source = #"""
        😀 Budget $5-$10. Export $HOME,$PATH.

        Inline $x_2$ and \(a_b\). Here $$a+b$$ is a separate equation.

        \[
        \frac{n}{2}
        \]

        The code sample is `$x_3$`.

        | Term | Formula |
        | --- | --- |
        | Norm | $|x|$ |
        """#
        let waiting = TranscriptText.markdown(source, role: .assistant, renderMath: true, mathParser: parser)
        #expect(waiting.string.hasPrefix("😀 Budget"))
        #expect(TranscriptRenderingRequest.missing(in: waiting) == [.math(source)])
        let formulas = await parser.prepare(source)
        #expect(formulas.map(\.tex) == ["x_2", "a_b", "a+b", "\\frac{n}{2}", "|x|"])
        #expect(formulas.map(\.display) == [false, false, true, true, false])
        #expect(formulas.map { (source as NSString).substring(with: $0.range) } == formulas.map(\.source))

        let content = TranscriptText.markdown(source, role: .assistant, renderMath: true, mathParser: parser)
        let artwork = TranscriptArtwork.missing(in: content)
        #expect(artwork.count == 5)
        #expect(artwork.first { $0.source == "x_2" }?.inlineFontSize == 15)
        let display = try #require(artwork.first { $0.source == "a+b" })
        #expect(display.inlineFontSize == nil)
        #expect(content.string.contains("Here \n$$a+b$$\n is a separate equation."))
        #expect(content.string.contains("Budget $5-$10. Export $HOME,$PATH."))
        #expect(content.string.contains("The code sample is $x_3$."))
        let tableFormula = (content.string as NSString).range(of: "$|x|$")
        #expect(tableFormula.location != NSNotFound)
        if tableFormula.location != NSNotFound {
            let style = content.attribute(.paragraphStyle, at: tableFormula.location, effectiveRange: nil) as? NSParagraphStyle
            #expect(style?.textBlocks.first is NSTextTableBlock)
        }
    }

    @Test func incompleteAndDisabledDelimiterMathKeepsItsText() async {
        let parser = TranscriptMathParser(asset: mathAsset())
        let incomplete = "This is still streaming $$x^2"
        let formulas = await parser.prepare(incomplete)
        #expect(formulas.isEmpty)
        #expect(TranscriptText.markdown(incomplete, renderMath: true, mathParser: parser).string == incomplete)
        let closed = "Compare $x^2$ and $y^2$."
        #expect(TranscriptRenderingRequest.missing(in: TranscriptText.markdown(closed, streaming: true, renderMath: true, mathParser: parser)).isEmpty)
        #expect(TranscriptText.markdown(closed, renderMath: false, mathParser: parser).string == closed)
    }

    private func mathAsset() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Assets/TranscriptRenderer/MathParser/math-parser.js.txt")
    }

    private func cell(in text: NSAttributedString, at index: Int) throws -> (style: NSParagraphStyle, block: NSTextTableBlock) {
        let style = try #require(text.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)
        let block = try #require(style.textBlocks.first as? NSTextTableBlock)
        return (style, block)
    }
}
