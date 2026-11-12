import AppKit

final class TranscriptCode: NSObject {
    static let attribute = NSAttributedString.Key("T3TranscriptCode")

    let text: String
    let artwork: TranscriptArtwork?

    var copyTitle: String {
        switch artwork?.kind {
        case .math: "Copy LaTeX"
        case .mermaid: "Copy Mermaid Source"
        case nil: "Copy Code"
        }
    }

    init(_ text: String, artwork: TranscriptArtwork? = nil) {
        self.text = text
        self.artwork = artwork
    }
}

final class TranscriptCodeBlock: NSTextBlock {
    private static let margin: CGFloat = 5
    private static let copySize = NSSize(width: 26, height: 22)

    init(color: NSColor, showsCopy: Bool) {
        super.init()
        setContentWidth(100, type: .percentage)
        setWidth(Self.margin, type: .absolute, for: .margin, edge: .minY)
        setWidth(Self.margin, type: .absolute, for: .margin, edge: .maxY)
        setWidth(10, type: .absolute, for: .padding)
        if showsCopy { setWidth(29, type: .absolute, for: .padding, edge: .maxY) }
        backgroundColor = color
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    private func surfaceFrame(in frame: NSRect) -> NSRect {
        frame.insetBy(dx: 0, dy: Self.margin)
    }

    func copyButtonFrame(in frame: NSRect) -> NSRect {
        let surface = surfaceFrame(in: frame)
        let size = Self.copySize
        return NSRect(x: surface.maxX - size.width - 5, y: surface.maxY - size.height - 3,
                      width: size.width, height: size.height)
    }

    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView?,
                                 characterRange: NSRange, layoutManager: NSLayoutManager) {
        guard let backgroundColor else { return }
        backgroundColor.setFill()
        NSBezierPath(roundedRect: surfaceFrame(in: frameRect), xRadius: 8, yRadius: 8).fill()
    }
}

@MainActor
enum TranscriptText {
    enum Role { case assistant, user, thought, detail }

    private final class InlineContext {
        let fileRoot: String?
        let math: TranscriptMathMarkup
        let dark: Bool
        let terminalContexts: [String: TerminalContext]
        private var previews: Set<TranscriptArtwork> = []

        init(fileRoot: String?, math: TranscriptMathMarkup, dark: Bool, contextRecords: [Wire]) {
            self.fileRoot = fileRoot
            self.math = math
            self.dark = dark
            terminalContexts = TerminalContext.byID(contextRecords)
        }

        func allowsPreview(_ artwork: TranscriptArtwork) -> Bool {
            if previews.contains(artwork) { return true }
            // Keep one response within the artwork cache so reflow can reuse completed previews.
            guard previews.count < 64 else { return false }
            previews.insert(artwork)
            return true
        }
    }

    static func markdown(_ source: String, role: Role = .detail, fileRoot: String? = nil, darkArtwork: Bool = true,
                         streaming: Bool = false, renderMath: Bool = TranscriptMathRendering.enabled,
                         mathParser: TranscriptMathParser = .shared, contextRecords: [Wire] = []) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: role == .assistant ? 15 : 13.5)
        let color = role == .thought ? WorkspaceStyle.secondary : WorkspaceStyle.ink
        // Streamed deltas reparse the whole message. Parse delimiters once the reply settles.
        let needsMath = renderMath && !streaming && mathParser.accepts(source)
        let formulas = needsMath ? mathParser.cachedFormulas(in: source) : []
        let math = TranscriptMathMarkup(source: source, formulas: formulas ?? [])
        let context = InlineContext(fileRoot: fileRoot, math: math, dark: darkArtwork, contextRecords: contextRecords)
        let hasArtwork = (math.markdown.contains("```") || math.markdown.contains("~~~")) &&
            (math.markdown.localizedCaseInsensitiveContains("mermaid") || (renderMath && math.markdown.localizedCaseInsensitiveContains("math")))
        let sourceLines = hasArtwork ? math.markdown.split(omittingEmptySubsequences: false, whereSeparator: isMarkdownLineBreak) : []
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full,
                                                               failurePolicy: .returnPartiallyParsedIfPossible,
                                                               appliesSourcePositionAttributes: hasArtwork)
        guard let parsed = try? AttributedString(markdown: math.markdown, options: options), !parsed.characters.isEmpty else {
            return NSAttributedString(string: source, attributes: [.font: font, .foregroundColor: color])
        }

        let output = NSMutableAttributedString()
        let runs = parsed.runs
        var listItems: Set<Int> = []
        var cursor = runs.startIndex
        while cursor != runs.endIndex {
            let start = cursor
            let components = runs[start].presentationIntent?.components ?? []
            let block = blockIntent(components)
            repeat { runs.formIndex(after: &cursor) }
            while cursor != runs.endIndex && blockIntent(runs[cursor].presentationIntent?.components ?? [])?.identity == block?.identity

            if output.length > 0, output.mutableString.character(at: output.length - 1) != 10 {
                let attributes = output.attributes(at: output.length - 1, effectiveRange: nil)
                output.append(NSAttributedString(string: "\n", attributes: attributes.filter { $0.key != .link }))
            }
            let members = runs[start..<cursor]
            switch block?.kind {
            case .table(let columns):
                appendTable(members, in: parsed, columns: columns, color: color, context: context, to: output)
            case .codeBlock(let language):
                let last = runs.index(before: cursor)
                let blockText = String(parsed[runs[start].range.lowerBound..<runs[last].range.upperBound].characters)
                let text = blockText.hasSuffix("\n") ? String(blockText.dropLast()) : blockText
                var artwork: TranscriptArtwork?
                if let language, let kind = TranscriptArtwork.Kind(rawValue: language.lowercased()),
                   kind != .math || renderMath,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   isClosedFence(in: sourceLines, position: runs[start].markdownSourcePosition, text: text) {
                    let requested = TranscriptArtwork(kind: kind, source: text, dark: darkArtwork)
                    if context.allowsPreview(requested) { artwork = requested }
                }
                let syntax = streaming || artwork != nil ? nil : TranscriptSyntax(text, language: language, dark: darkArtwork)
                appendCode(TranscriptCode(text, artwork: artwork), language: language, syntax: syntax, color: color, to: output)
            default:
                appendParagraph(members, in: parsed, components: components, role: role, font: font, color: color,
                                context: context, listItems: &listItems, to: output)
            }
        }
        if needsMath, formulas == nil, output.length > 0 {
            let first = output.mutableString.rangeOfComposedCharacterSequence(at: 0)
            output.addAttribute(TranscriptRenderingRequest.mathSource, value: source, range: first)
        }
        return output
    }

    private static func blockIntent(_ components: [PresentationIntent.IntentType]) -> PresentationIntent.IntentType? {
        components.first {
            if case .table = $0.kind { return true }
            return false
        } ?? components.first
    }

    private static func appendParagraph(_ runs: Slice<AttributedString.Runs>, in parsed: AttributedString,
                                        components: [PresentationIntent.IntentType], role: Role, font: NSFont, color: NSColor,
                                        context: InlineContext, listItems: inout Set<Int>, to output: NSMutableAttributedString) {
        let paragraph = NSMutableAttributedString()
        let style = NSMutableParagraphStyle()
        style.lineSpacing = role == .assistant ? 4 : role == .thought ? 3 : 2
        let quoteDepth = components.count { $0.kind == .blockQuote }
        let ink = quoteDepth == 0 ? color : WorkspaceStyle.secondary
        let inset = CGFloat(min(quoteDepth, 6)) * 14
        style.headIndent = inset
        style.firstLineHeadIndent = inset
        let textFont: NSFont
        if case .header(let level) = components.first?.kind {
            let size = role == .assistant ? max(15, 19 - CGFloat(level)) : max(16, 22 - CGFloat(level))
            textFont = .systemFont(ofSize: size, weight: .semibold)
        } else {
            textFont = font
        }

        let items = components.indices.filter {
            if case .listItem = components[$0].kind { return true }
            return false
        }
        if let index = items.first, case .listItem(let ordinal) = components[index].kind {
            let list = components.dropFirst(index + 1).first { $0.kind == .orderedList || $0.kind == .unorderedList }
            let mark = list?.kind == .orderedList ? "\(ordinal)." : "•"
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
            let leading = inset + CGFloat(min(items.count - 1, 6)) * 16
            let textStart = leading + max(17, ceil((mark as NSString).size(withAttributes: attributes).width) + 6)
            style.headIndent = textStart
            style.firstLineHeadIndent = textStart
            if listItems.insert(components[index].identity).inserted {
                style.firstLineHeadIndent = leading
                style.tabStops = [NSTextTab(textAlignment: .left, location: textStart)]
                paragraph.append(NSAttributedString(string: mark + "\t", attributes: attributes))
            }
        }

        for run in runs {
            paragraph.append(inline(run, in: parsed, font: textFont, color: ink, context: context))
        }
        guard paragraph.length > 0 else { return }
        let displayMath = context.math.hasFormulas ? isolateDisplayMath(in: paragraph) : []
        let range = NSRange(location: 0, length: paragraph.length)
        paragraph.addAttribute(.paragraphStyle, value: style, range: range)
        let lastLine = paragraph.mutableString.paragraphRange(for: NSRange(location: paragraph.length - 1, length: 1))
        let endStyle = style.mutableCopy() as! NSMutableParagraphStyle
        endStyle.paragraphSpacing = items.isEmpty ? (role == .user ? 4 : 7) : 2
        paragraph.addAttribute(.paragraphStyle, value: endStyle, range: lastLine)
        for display in displayMath {
            let mathStyle = endStyle.mutableCopy() as! NSMutableParagraphStyle
            mathStyle.firstLineHeadIndent = style.headIndent
            mathStyle.paragraphSpacingBefore = 4
            if paragraph.attribute(.attachment, at: display.location, effectiveRange: nil) != nil { mathStyle.alignment = .center }
            paragraph.addAttribute(.paragraphStyle, value: mathStyle, range: paragraph.mutableString.paragraphRange(for: display))
        }
        output.append(paragraph)
    }

    private static func isolateDisplayMath(in paragraph: NSMutableAttributedString) -> [NSRange] {
        var displays: [NSRange] = []
        paragraph.enumerateAttribute(TranscriptCode.attribute, in: NSRange(location: 0, length: paragraph.length)) { value, range, _ in
            if let artwork = (value as? TranscriptCode)?.artwork, artwork.kind == .math, artwork.inlineFontSize == nil {
                displays.append(range)
            }
        }
        var inserted = 0
        return displays.map { range in
            var start = range.location + inserted
            if start > 0 && paragraph.mutableString.character(at: start - 1) != 10 {
                paragraph.insert(NSAttributedString(string: "\n"), at: start)
                start += 1
                inserted += 1
            }
            let end = start + range.length
            if end < paragraph.length && paragraph.mutableString.character(at: end) != 10 {
                paragraph.insert(NSAttributedString(string: "\n"), at: end)
                inserted += 1
            }
            return NSRange(location: start, length: range.length)
        }
    }

    private static func appendTable(_ runs: Slice<AttributedString.Runs>, in parsed: AttributedString,
                                    columns: [PresentationIntent.TableColumn], color: NSColor, context: InlineContext,
                                    to output: NSMutableAttributedString) {
        var rows: [Int: [Int: NSMutableAttributedString]] = [:]
        let headerFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        let font = NSFont.systemFont(ofSize: 12.5)
        for run in runs {
            let components = run.presentationIntent?.components ?? []
            guard components.count >= 2, case .tableCell(let column) = components[0].kind else { continue }
            let row: Int
            switch components[1].kind {
            case .tableHeaderRow: row = 0
            case .tableRow(let rowIndex): row = rowIndex
            default: continue
            }
            let cell = rows[row]?[column] ?? NSMutableAttributedString()
            cell.append(inline(run, in: parsed, font: row == 0 ? headerFont : font, color: color, context: context))
            rows[row, default: [:]][column] = cell
        }
        guard let lastRow = rows.keys.max(), !columns.isEmpty else { return }

        // A sparse table can otherwise materialize thousands of empty TextKit cells.
        guard columns.count <= 16, lastRow < 2_048 / columns.count else {
            for row in rows.keys.sorted() {
                for (index, column) in rows[row, default: [:]].keys.sorted().enumerated() {
                    if index > 0 { output.append(NSAttributedString(string: "  |  ", attributes: [.font: font, .foregroundColor: color])) }
                    if let content = rows[row]?[column] { output.append(content) }
                }
                output.append(NSAttributedString(string: "\n", attributes: [.font: font, .foregroundColor: color]))
            }
            return
        }

        let table = NSTextTable()
        table.numberOfColumns = columns.count
        table.layoutAlgorithm = .fixed
        table.collapsesBorders = true
        table.setContentWidth(100, type: .percentage)
        table.setWidth(3, type: .absolute, for: .margin)
        let cellWidth = 100 / CGFloat(columns.count)
        let padding = min(7, 30 / CGFloat(columns.count))
        for row in 0...lastRow {
            for (column, format) in columns.enumerated() {
                let cell = rows[row]?[column] ?? NSMutableAttributedString()
                let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                block.setContentWidth(cellWidth, type: .percentage)
                block.setWidth(padding, type: .absolute, for: .padding)
                block.setWidth(1, type: .absolute, for: .border)
                block.setBorderColor(WorkspaceStyle.outline)
                block.backgroundColor = row == 0 ? WorkspaceStyle.composer : WorkspaceStyle.canvas
                let style = NSMutableParagraphStyle()
                style.textBlocks = [block]
                style.alignment = switch format.alignment {
                case .left: .left
                case .center: .center
                case .right: .right
                @unknown default: .left
                }
                cell.append(NSAttributedString(string: "\n", attributes: [.font: font, .foregroundColor: color]))
                cell.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: cell.length))
                output.append(cell)
            }
        }
    }

    private static func isMarkdownLineBreak(_ value: Character) -> Bool {
        value == "\n" || value == "\r" || value == "\r\n"
    }

    private static func isClosedFence(in lines: [Substring], position: AttributedString.MarkdownSourcePosition?, text: String) -> Bool {
        guard let position, position.startLine > 0, position.startColumn > 0, position.endLine <= lines.count,
              position.endLine - position.startLine > text.split(omittingEmptySubsequences: false, whereSeparator: isMarkdownLineBreak).count else { return false }
        let first = lines[position.startLine - 1]
        let opening = String(decoding: first.utf8.dropFirst(position.startColumn - 1), as: UTF8.self).drop(while: \.isWhitespace)
        guard let marker = opening.first, marker == "`" || marker == "~" else { return false }
        let openingCount = opening.prefix(while: { $0 == marker }).count
        let closing = lines[position.endLine - 1].drop(while: { $0.isWhitespace || $0 == ">" })
        let closingCount = closing.prefix(while: { $0 == marker }).count
        return openingCount >= 3 && closingCount >= openingCount && closing.dropFirst(closingCount).allSatisfy(\.isWhitespace)
    }

    private static func appendCode(_ code: TranscriptCode, language: String?, syntax: TranscriptSyntax?,
                                   color: NSColor, to output: NSMutableAttributedString) {
        let block = TranscriptCodeBlock(color: WorkspaceStyle.commandPreview, showsCopy: !code.text.isEmpty)
        let style = NSMutableParagraphStyle()
        style.textBlocks = [block]
        style.lineBreakMode = .byCharWrapping
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: style, TranscriptCode.attribute: code,
        ]
        if let preview = artworkAttachment(for: code) {
            style.alignment = .center
            preview.addAttributes(attributes, range: NSRange(location: 0, length: preview.length))
            output.append(preview)
            output.append(NSAttributedString(string: "\n", attributes: attributes))
        } else if language?.lowercased() == "diff" {
            let lines = code.text.components(separatedBy: "\n")
            for line in lines {
                var lineAttributes = attributes
                lineAttributes[.foregroundColor] = diffColor(line)
                output.append(NSAttributedString(string: line + "\n", attributes: lineAttributes))
            }
        } else {
            let blockText = NSMutableAttributedString(string: code.text + "\n", attributes: attributes)
            if let syntax, TranscriptSyntaxRenderer.shared.isAvailable, !TranscriptSyntaxRenderer.shared.apply(syntax, to: blockText) {
                let start = blockText.mutableString.rangeOfComposedCharacterSequence(at: 0)
                blockText.addAttribute(TranscriptSyntax.attribute, value: syntax, range: start)
            }
            output.append(blockText)
        }
    }

    private static func artworkAttachment(for code: TranscriptCode) -> NSMutableAttributedString? {
        guard let artwork = code.artwork, let image = TranscriptArtworkRenderer.shared.preview(for: artwork) else { return nil }
        let attachment = NSTextAttachment()
        attachment.attachmentCell = TranscriptArtworkCell(image)
        return NSMutableAttributedString(attachment: attachment)
    }

    private static func inline(_ run: AttributedString.Runs.Run, in parsed: AttributedString,
                               font: NSFont, color: NSColor, context: InlineContext) -> NSAttributedString {
        let intent = run.inlinePresentationIntent ?? []
        let content = intent.contains(.softBreak) || intent.contains(.lineBreak) ? "\n" : String(parsed[run.range].characters)
        if let href = run.link, let citation = AssistantCitation.parse(href.absoluteString) {
            return NSAttributedString(string: "″ \(citation.label)", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: WorkspaceStyle.accent,
                .backgroundColor: WorkspaceStyle.selection, .link: href,
            ])
        }
        if let href = run.link, let id = TerminalContext.referenceID(href), let terminal = context.terminalContexts[id] {
            let chip = NSMutableAttributedString(attachment: TerminalContextAttachment(terminal))
            chip.addAttribute(.link, value: href, range: NSRange(location: 0, length: chip.length))
            return chip
        }
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if intent.contains(.code) {
            attributes[.font] = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .medium)
            attributes[.backgroundColor] = WorkspaceStyle.bubble
        } else {
            var traits: NSFontTraitMask = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
            if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
            if !traits.isEmpty { attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: traits) }
        }
        if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let link = run.link {
            if ["http", "https"].contains(link.scheme?.lowercased()) { attributes[.link] = link }
            else if let fileRoot = context.fileRoot { attributes[.link] = WorkspaceFileReference(markdown: link, root: fileRoot)?.link }
        } else if let fileRoot = context.fileRoot, intent.contains(.code) {
            attributes[.link] = WorkspaceFileReference(inlineCode: content, root: fileRoot)?.link
        }
        guard context.math.hasFormulas else { return NSAttributedString(string: content, attributes: attributes) }
        let parts = context.math.parts(in: content)
        if parts.count == 1, case .text(let text) = parts[0] { return NSAttributedString(string: text, attributes: attributes) }
        let output = NSMutableAttributedString()
        for part in parts {
            switch part {
            case .text(let text):
                output.append(NSAttributedString(string: text, attributes: attributes))
            case .formula(let formula):
                let artwork = TranscriptArtwork(kind: .math, source: formula.tex, dark: context.dark,
                                                 inlineFontSize: formula.display ? nil : font.pointSize)
                guard context.allowsPreview(artwork) else {
                    output.append(NSAttributedString(string: formula.source, attributes: attributes))
                    continue
                }
                let code = TranscriptCode(formula.source, artwork: artwork)
                var mathAttributes = attributes
                mathAttributes[TranscriptCode.attribute] = code
                if let preview = artworkAttachment(for: code) {
                    preview.addAttributes(mathAttributes, range: NSRange(location: 0, length: preview.length))
                    output.append(preview)
                } else {
                    output.append(NSAttributedString(string: formula.source, attributes: mathAttributes))
                }
            }
        }
        return output
    }

    static func bounds(_ text: NSAttributedString, width: CGFloat) -> NSRect {
        text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    static func monospace(_ text: String, diff: Bool = false) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        guard diff else { return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: WorkspaceStyle.ink]) }
        let output = NSMutableAttributedString()
        text.enumerateLines { line, _ in
            output.append(NSAttributedString(string: line + "\n", attributes: [.font: font, .foregroundColor: diffColor(line)]))
        }
        return output
    }

    private static func diffColor(_ line: String) -> NSColor {
        switch line.first {
        case "+" where !line.hasPrefix("+++"): WorkspaceStyle.positive
        case "-" where !line.hasPrefix("---"): WorkspaceStyle.negative
        case "@": .systemBlue
        default: WorkspaceStyle.ink
        }
    }
}
