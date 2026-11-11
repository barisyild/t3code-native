import AppKit

final class TerminalContextAttachment: NSTextAttachment {
    let context: TerminalContext

    @MainActor
    init(_ context: TerminalContext) {
        self.context = context
        super.init(data: nil, ofType: nil)
        attachmentCell = ComposerContextChipCell(title: ">_  \(context.label)", accessibility: context.label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

@MainActor
final class TerminalContextView: NSViewController {
    private let context: TerminalContext
    private let onRemove: (() -> Void)?

    init(_ context: TerminalContext, onRemove: (() -> Void)? = nil) {
        self.context = context
        self.onRemove = onRemove
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = Surface(WorkspaceStyle.navigation)
        let title = label(context.label, size: 13, weight: .semibold, color: WorkspaceStyle.ink)
        title.lineBreakMode = .byTruncatingTail
        let excerpt = NSTextView()
        excerpt.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        excerpt.textColor = WorkspaceStyle.ink
        excerpt.textContainerInset = NSSize(width: 6, height: 5)
        let selection = context.selection
        let lines = selection.text.components(separatedBy: "\n").prefix(selection.lineEnd - selection.lineStart + 1)
        excerpt.string = lines.enumerated().map { offset, line in "\(selection.lineStart + offset)  \(line)" }.joined(separator: "\n")
        excerpt.setAccessibilityLabel("Terminal Output")
        let preview = Surface(WorkspaceStyle.canvas, border: WorkspaceStyle.outline, radius: 7)
        fill(textScroller(excerpt), in: preview, inset: 1)
        preview.heightAnchor.constraint(equalToConstant: min(182, max(45, CGFloat(lines.count) * 17 + 14))).isActive = true
        let copy = ActionButton("Copy Output", symbol: "document.on.document", style: .subtle) { [context] in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(context.selection.text, forType: .string)
        }
        var controls: [NSView] = [copy, NSView()]
        if let onRemove { controls.append(ActionButton("Remove", style: .subtle, action: onRemove)) }
        fill(column([row([WorkspaceStyle.icon("terminal", size: 12), title, NSView()], spacing: 6),
                     preview, row(controls)], spacing: 8, alignment: .width), in: view, inset: 12)
        preferredContentSize = NSSize(width: 380, height: min(182, max(45, CGFloat(lines.count) * 17 + 14)) + 82)
    }
}
