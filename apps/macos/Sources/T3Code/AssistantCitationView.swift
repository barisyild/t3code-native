import AppKit

final class ComposerContextChipCell: NSTextAttachmentCell {
    nonisolated override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -3) }

    @MainActor
    init(title: String, accessibility: String) {
        let text = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .foregroundColor: WorkspaceStyle.ink,
        ])
        let size = NSSize(width: min(247, ceil(text.size().width) + 14), height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            WorkspaceStyle.selection.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5).fill()
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let label = NSMutableAttributedString(attributedString: text)
            label.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: label.length))
            label.draw(in: NSRect(x: rect.minX + 7, y: rect.minY + 1, width: rect.width - 14, height: rect.height - 3))
            return true
        }
        image.accessibilityDescription = accessibility
        super.init(imageCell: image)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }
}

final class AssistantCitationAttachment: NSTextAttachment {
    let citation: AssistantCitation

    @MainActor
    init(_ citation: AssistantCitation) {
        self.citation = citation
        super.init(data: nil, ofType: nil)
        attachmentCell = ComposerContextChipCell(title: "″  \(citation.label)", accessibility: "Assistant quote \(citation.label)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

@MainActor
final class AssistantCitationView: NSViewController, NSTextViewDelegate {
    private let citation: AssistantCitation
    private let onSource: (() -> Void)?
    private let onSave: ((String) throws -> Void)?
    private let onRemove: (() -> Void)?
    private let excerpt = NSTextView()
    private let comment = NSTextView()
    private let status = label(size: 11.5, color: WorkspaceStyle.negative)
    private lazy var save = ActionButton("Save Comment") { [weak self] in self?.submit() }
    var onClose: (() -> Void)?

    init(citation: AssistantCitation, onSource: (() -> Void)?, onSave: ((String) throws -> Void)? = nil,
         onRemove: (() -> Void)? = nil) {
        self.citation = citation
        self.onSource = onSource
        self.onSave = onSave
        self.onRemove = onRemove
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = Surface(WorkspaceStyle.navigation)
        let title = label("Assistant Quote", size: 13, weight: .semibold, color: WorkspaceStyle.ink)
        excerpt.font = .systemFont(ofSize: 12.5)
        excerpt.textColor = WorkspaceStyle.ink
        excerpt.textContainerInset = NSSize(width: 6, height: 5)
        excerpt.string = citation.text
        excerpt.setAccessibilityLabel("Quoted Assistant Text")
        let preview = Surface(WorkspaceStyle.canvas, border: WorkspaceStyle.outline, radius: 7)
        fill(textScroller(excerpt), in: preview, inset: 1)
        preview.heightAnchor.constraint(equalToConstant: citation.text.utf16.count < 180 ? 52 : 105).isActive = true
        var fields: [NSView] = [title, preview]
        if onSave != nil || citation.comment != nil {
            let editable = onSave != nil
            comment.font = .systemFont(ofSize: 12.5)
            comment.textColor = WorkspaceStyle.ink
            comment.insertionPointColor = WorkspaceStyle.ink
            comment.textContainerInset = NSSize(width: 6, height: 5)
            comment.string = citation.comment ?? ""
            comment.delegate = self
            comment.setAccessibilityLabel("Quote Comment")
            let box = Surface(WorkspaceStyle.canvas, border: WorkspaceStyle.outline, radius: 7)
            fill(textScroller(comment, editable: editable), in: box, inset: 1)
            box.heightAnchor.constraint(equalToConstant: editable ? 65 : 48).isActive = true
            fields += [label("Comment", size: 11.5, color: WorkspaceStyle.muted), box]
        }
        var buttons: [NSView] = []
        if let onRemove {
            buttons.append(ActionButton("Remove Quote", symbol: "trash", iconOnly: true, style: .subtle) { [weak self] in
                onRemove()
                self?.onClose?()
            })
        } else {
            buttons.append(ActionButton("Copy Citation", symbol: "document.on.document", iconOnly: true, style: .subtle) { [weak self] in
                guard let self else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(citation.markdown, forType: .string)
            })
        }
        buttons.append(NSView())
        if let onSource {
            buttons.append(ActionButton("Go to Source", symbol: "arrow.up.right", style: .subtle) { [weak self] in
                self?.submit(then: onSource)
            })
        }
        if onSave != nil {
            save.keyEquivalent = "\r"
            save.keyEquivalentModifierMask = .command
            buttons.append(save)
        }
        status.isHidden = true
        fields += [status, row(buttons, spacing: 6)]
        fill(column(fields, spacing: 8, alignment: .width), in: view, inset: 13)
        view.frame.size = NSSize(width: 395, height: view.fittingSize.height)
        preferredContentSize = view.frame.size
    }

    func focusComment() {
        guard onSave != nil else { return }
        view.window?.makeFirstResponder(comment)
        comment.setSelectedRange(NSRange(location: comment.string.utf16.count, length: 0))
    }

    func textDidChange(_ notification: Notification) {
        status.isHidden = true
        save.isEnabled = comment.string.utf16.count <= AssistantCitation.maximumComment
        if !save.isEnabled {
            status.stringValue = "Use up to 8,000 characters for a quote comment."
            status.isHidden = false
        }
    }

    private func submit(then followUp: (() -> Void)? = nil) {
        do {
            try onSave?(comment.string)
            onClose?()
            followUp?()
        } catch {
            status.stringValue = error.localizedDescription
            status.isHidden = false
        }
    }
}
