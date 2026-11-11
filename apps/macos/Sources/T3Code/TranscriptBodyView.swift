import AppKit

@MainActor
final class TranscriptBodyView: NSTextView {
    var onFileLink: ((WorkspaceFileReference) -> Void)?
    var onQuoteSelection: ((String, NSRange) -> Void)?
    var onCitation: ((AssistantCitation, NSRect) -> Void)?
    var onAppearanceChange: (() -> Void)?
    var terminalClipboardSource: TerminalContextClipboard.Source?
    private var terminalPopup: NSPopover?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    override func clicked(onLink link: Any, at charIndex: Int) {
        if let url = link as? URL, TerminalContext.referenceID(url) != nil {
            if let (context, frame) = terminalContext(at: charIndex) { showTerminalContext(context, frame: frame) }
        } else if let url = link as? URL, url.scheme == "t3-citation" {
            if let citation = AssistantCitation.parse(url.absoluteString), let layoutManager, let textContainer,
               let textStorage, charIndex < textStorage.length {
                var range = NSRange(location: charIndex, length: 1)
                _ = textStorage.attribute(.link, at: charIndex, effectiveRange: &range)
                let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let frame = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
                    .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
                onCitation?(citation, frame)
            }
        } else if let url = link as? URL, WorkspaceFileReference.isFileLink(url) {
            if let reference = WorkspaceFileReference(internalLink: url) { onFileLink?(reference) }
        } else { super.clicked(onLink: link, at: charIndex) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let range = selectedRange()
        let menu = super.menu(for: event) ?? NSMenu()
        if let (code, image) = codeBlock(at: convert(event.locationInWindow, from: nil)), !code.text.isEmpty {
            let title = switch code.artwork?.kind {
            case .math: "Copy LaTeX"
            case .mermaid: "Copy Mermaid Source"
            case nil: "Copy Code"
            }
            let action = menuItem(title, target: self, action: #selector(copyCode(_:)))
            action.representedObject = code
            menu.insertItem(action, at: 0)
            if code.artwork?.kind == .mermaid, let image {
                let preview = menuItem("Open Diagram…", target: self, action: #selector(openDiagram(_:)))
                preview.representedObject = image
                menu.insertItem(preview, at: 0)
            }
        }
        guard onQuoteSelection != nil, range.length > 0, NSMaxRange(range) <= attributedString().length else { return menu }
        let selection = TranscriptSelection(attributedString())
        let sourceRange = selection.sourceRange(for: range)
        guard sourceRange.length <= AssistantCitation.maximumText,
              !(selection.text as NSString).substring(with: sourceRange).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return menu }
        let action = menuItem("Cite in Composer", target: self, action: #selector(quoteSelection(_:)))
        action.representedObject = (selection.text, sourceRange)
        menu.insertItem(action, at: 0)
        return menu
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        var types = super.writablePasteboardTypes
        for type in [.html, TerminalContextClipboard.fragment] where !types.contains(type) { types.append(type) }
        return types
    }

    override func writeSelection(to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let content = attributedString()
        let ranges = selectedRanges.map(\.rangeValue).filter { $0.length > 0 && NSMaxRange($0) <= content.length }
        let selection = TranscriptSelection(content)
        guard ranges.contains(where: selection.containsInlineContent) else { return super.writeSelection(to: pasteboard, type: type) }
        let source = selection.text as NSString
        let pieces = ranges.map { source.substring(with: selection.sourceRange(for: $0)) }
        let contexts = ranges.flatMap { TerminalContextClipboard.contexts(in: content.attributedSubstring(from: $0)) }
        return TerminalContextClipboard.write(text: pieces.joined(separator: "\n"), contexts: contexts,
                                              source: terminalClipboardSource, to: pasteboard, type: type)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty {
            let index = characterIndexForInsertion(at: point)
            for candidate in [index, index - 1] {
                if let (context, frame) = terminalContext(at: candidate), frame.contains(point) {
                    showTerminalContext(context, frame: frame)
                    return
                }
            }
        }
        if event.clickCount == 2,
           let (code, preview) = codeBlock(at: point),
           let image = preview, code.artwork?.kind == .mermaid {
            presentDiagram(image)
        } else {
            super.mouseDown(with: event)
        }
    }

    private func terminalContext(at index: Int) -> (TerminalContext, NSRect)? {
        guard let textStorage, index >= 0, index < textStorage.length, let layoutManager, let textContainer,
              let chip = textStorage.attribute(.attachment, at: index, effectiveRange: nil) as? TerminalContextAttachment else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        let frame = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        return (chip.context, frame)
    }

    private func showTerminalContext(_ context: TerminalContext, frame: NSRect) {
        guard window != nil else { return }
        terminalPopup?.close()
        let popup = NSPopover()
        popup.behavior = .transient
        popup.contentViewController = TerminalContextView(context)
        terminalPopup = popup
        popup.show(relativeTo: frame, of: self, preferredEdge: .minY)
    }

    private func codeBlock(at point: NSPoint) -> (TranscriptCode, NSImage?)? {
        guard let layoutManager, let textContainer, let textStorage, textStorage.length > 0 else { return nil }
        let position = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: position, in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs,
              layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).contains(position) else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard index < textStorage.length,
              let code = textStorage.attribute(TranscriptCode.attribute, at: index, effectiveRange: nil) as? TranscriptCode else { return nil }
        let attachment = textStorage.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment
        return (code, (attachment?.attachmentCell as? NSTextAttachmentCell)?.image)
    }

    @objc private func copyCode(_ item: NSMenuItem) {
        guard let code = item.representedObject as? TranscriptCode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code.artwork?.source ?? code.text, forType: .string)
    }

    @objc private func openDiagram(_ item: NSMenuItem) {
        guard let image = item.representedObject as? NSImage else { return }
        presentDiagram(image)
    }

    private func presentDiagram(_ image: NSImage) {
        guard let parent = window, parent.attachedSheet == nil else { return }
        let size = NSSize(width: min(920, max(520, image.size.width + 48)), height: min(740, max(310, image.size.height + 72)))
        let sheet = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        sheet.title = "Mermaid Diagram"
        sheet.contentMinSize = NSSize(width: 400, height: 245)
        let surface = Surface(WorkspaceStyle.navigation)
        let diagram = NSImageView(image: image)
        diagram.imageScaling = .scaleProportionallyUpOrDown
        diagram.setAccessibilityLabel("Mermaid Diagram")
        diagram.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        diagram.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let done = ActionButton("Done") { [weak parent, weak sheet] in
            if let parent, let sheet { parent.endSheet(sheet) }
        }
        done.keyEquivalent = "\u{1b}"
        let footer = row([NSView(), done])
        footer.heightAnchor.constraint(equalToConstant: 28).isActive = true
        sheet.contentView = surface
        fill(column([diagram, footer], spacing: 10, alignment: .width), in: surface, inset: 12)
        parent.beginSheet(sheet)
    }

    @objc private func quoteSelection(_ item: NSMenuItem) {
        if let (text, range) = item.representedObject as? (String, NSRange) { onQuoteSelection?(text, range) }
    }
}
