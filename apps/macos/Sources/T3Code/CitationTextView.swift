import AppKit

@MainActor
class CitationTextView: AttachmentTextView {
    var onOpenCitation: ((AssistantCitation) -> Void)?
    var terminalClipboardSource: TerminalContextClipboard.Source?
    private var citationPopup: NSPopover?

    func enableCitationEditing() {
        isRichText = true
        importsGraphics = false
        usesFontPanel = false
        usesRuler = false
        typingAttributes = plainAttributes
    }

    var promptSource: String { textStorage.map(source(from:)) ?? string }
    var terminalContextRecords: [Wire] { TerminalContextClipboard.contexts(in: attributedString()).map(\.record) }

    func setPromptSource(_ raw: String, contextRecords: [Wire] = []) {
        closeCitation()
        textStorage?.setAttributedString(document(raw, contextRecords: contextRecords))
        typingAttributes = plainAttributes
    }

    func addCitation(_ citation: AssistantCitation) -> Bool {
        guard let position = insertChip(AssistantCitationAttachment(citation)),
              self.citation(at: position) == citation else { return false }
        if let frame = attachmentFrame(at: position) { showCitation(citation, at: position, frame: frame) }
        return true
    }

    func addTerminalContext(_ context: TerminalContext) -> Bool {
        guard let position = insertChip(TerminalContextAttachment(context)) else { return false }
        return terminalContext(at: position) == context
    }

    private func insertChip(_ attachment: NSTextAttachment) -> Int? {
        guard isEditable else { return nil }
        let range = selectedRange()
        let insertion = NSMutableAttributedString(attachment: attachment)
        let source = string as NSString
        guard range.location >= 0, range.location <= source.length, range.length <= source.length - range.location else { return nil }
        let needsSpace = range.location > 0 && !source.substring(with: NSRange(location: range.location - 1, length: 1)).allSatisfy(\.isWhitespace)
        if needsSpace { insertion.insert(NSAttributedString(string: " ", attributes: plainAttributes), at: 0) }
        insertion.append(NSAttributedString(string: " ", attributes: plainAttributes))
        insertText(insertion, replacementRange: range)
        typingAttributes = plainAttributes
        return range.location + (needsSpace ? 1 : 0)
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { AttachmentInput.pasteboardTypes + [.string] }
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { readablePasteboardTypes }
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string, .html, TerminalContextClipboard.fragment] }

    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if type == .string, isEditable, let value = pasteboard.string(forType: .string) {
            let records = terminalContextRecords + TerminalContextClipboard.read(from: pasteboard, text: value)
            insertText(document(value, contextRecords: records), replacementRange: selectedRange())
            typingAttributes = plainAttributes
            return true
        }
        return super.readSelection(from: pasteboard, type: type)
    }

    override func writeSelection(to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let text = attributedString()
        let parts = selectedRanges.map(\.rangeValue).filter { $0.length > 0 && NSMaxRange($0) <= text.length }.map {
            text.attributedSubstring(from: $0)
        }
        guard !parts.isEmpty else { return false }
        return TerminalContextClipboard.write(text: parts.map(source(from:)).joined(separator: "\n"),
                                              contexts: parts.flatMap(TerminalContextClipboard.contexts(in:)),
                                              source: terminalClipboardSource, to: pasteboard, type: type)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        for position in [index, index - 1] where position >= 0 {
            guard let frame = attachmentFrame(at: position), frame.contains(point) else { continue }
            if let value = citation(at: position) {
                showCitation(value, at: position, frame: frame)
                return
            }
            if let value = terminalContext(at: position) {
                showTerminalContext(value, at: position, frame: frame)
                return
            }
        }
        super.mouseDown(with: event)
    }

    func closeCitation() {
        citationPopup?.close()
        citationPopup = nil
    }

    private var plainAttributes: [NSAttributedString.Key: Any] {
        [.font: font ?? NSFont.systemFont(ofSize: 14), .foregroundColor: textColor ?? WorkspaceStyle.ink]
    }

    private func document(_ raw: String, contextRecords: [Wire]) -> NSAttributedString {
        let terminals = TerminalContext.byID(contextRecords)
        var matches: [(range: NSRange, chip: NSTextAttachment)] = AssistantCitation.matches(in: raw).map {
            ($0.range, AssistantCitationAttachment($0.citation))
        }
        matches += TerminalContext.references(in: raw).compactMap { match in
            terminals[match.id].map { (match.range, TerminalContextAttachment($0)) }
        }
        guard !matches.isEmpty else { return NSAttributedString(string: raw, attributes: plainAttributes) }
        let source = raw as NSString
        let result = NSMutableAttributedString()
        var offset = 0
        for (range, chip) in matches.sorted(by: { $0.range.location < $1.range.location }) where range.location >= offset {
            let text = source.substring(with: NSRange(location: offset, length: range.location - offset))
            result.append(NSAttributedString(string: text, attributes: plainAttributes))
            result.append(NSAttributedString(attachment: chip))
            offset = NSMaxRange(range)
        }
        result.append(NSAttributedString(string: source.substring(from: offset), attributes: plainAttributes))
        return result
    }

    private func source(from value: NSAttributedString) -> String {
        let raw = value.string as NSString
        var text = ""
        value.enumerateAttribute(.attachment, in: NSRange(location: 0, length: value.length)) { attachment, range, _ in
            if let attachment = attachment as? AssistantCitationAttachment {
                text += String(repeating: attachment.citation.markdown, count: range.length)
            } else if let attachment = attachment as? TerminalContextAttachment {
                text += String(repeating: attachment.context.markdown, count: range.length)
            } else { text += raw.substring(with: range) }
        }
        return text
    }

    private func citation(at index: Int) -> AssistantCitation? {
        (attachment(at: index) as? AssistantCitationAttachment)?.citation
    }

    private func terminalContext(at index: Int) -> TerminalContext? {
        (attachment(at: index) as? TerminalContextAttachment)?.context
    }

    private func attachment(at index: Int) -> NSTextAttachment? {
        guard let textStorage, index >= 0, index < textStorage.length else { return nil }
        return textStorage.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment
    }

    private func attachmentFrame(at index: Int) -> NSRect? {
        guard let layoutManager, let textContainer, attachment(at: index) != nil else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        return layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    private func showCitation(_ citation: AssistantCitation, at index: Int, frame: NSRect) {
        guard window != nil else { return }
        closeCitation()
        let popup = NSPopover()
        popup.behavior = .transient
        let card = AssistantCitationView(citation: citation, onSource: onOpenCitation.map { open in { open(citation) } },
                                         onSave: isEditable ? { [weak self] comment in
            guard let self, isEditable, self.citation(at: index) == citation else {
                throw ClientError.message("This quote is no longer in the draft.")
            }
            let updated = try citation.replacingComment(comment)
            if updated != citation {
                insertText(NSAttributedString(attachment: AssistantCitationAttachment(updated)), replacementRange: NSRange(location: index, length: 1))
                typingAttributes = plainAttributes
            }
        } : nil, onRemove: isEditable ? { [weak self] in
            guard let self, isEditable, self.citation(at: index) == citation else { return }
            insertText("", replacementRange: NSRange(location: index, length: 1))
            typingAttributes = plainAttributes
        } : nil)
        card.onClose = { [weak self] in self?.closeCitation() }
        popup.contentViewController = card
        citationPopup = popup
        popup.show(relativeTo: frame, of: self, preferredEdge: .minY)
        card.focusComment()
    }

    private func showTerminalContext(_ context: TerminalContext, at index: Int, frame: NSRect) {
        guard window != nil else { return }
        closeCitation()
        let popup = NSPopover()
        popup.behavior = .transient
        popup.contentViewController = TerminalContextView(context, onRemove: isEditable ? { [weak self] in
            guard let self, isEditable, terminalContext(at: index) == context else { return }
            closeCitation()
            insertText("", replacementRange: NSRange(location: index, length: 1))
            typingAttributes = plainAttributes
        } : nil)
        citationPopup = popup
        popup.show(relativeTo: frame, of: self, preferredEdge: .minY)
    }
}
