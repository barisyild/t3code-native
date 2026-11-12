import AppKit

@MainActor
final class ConversationApprovalView: NSView {
    struct Content: Equatable {
        struct Option: Equatable {
            let label: String
            let decision: String
            var warning: String?
        }

        let requestID: String?
        let title: String
        let prompt: String?
        let command: String?
        let context: String
        let options: [Option]

        init(kind: String, entry: TimelineEntry?) {
            let value = entry?.value ?? .null
            requestID = entry?.requestId
            title = switch kind {
            case "command": "Run this command?"
            case "file-read": "File read approval"
            case "file-change": "File change approval"
            case "mcp-elicitation": "App access approval"
            case "permission": "Permission approval"
            default: "Approval requested"
            }
            let reason = value["reason"].string
            let actionTitle = value["title"].string
            let actionPrompt = value["prompt"].string
            let action = [actionTitle == actionPrompt ? nil : actionTitle, actionPrompt].compactMap { $0 }
                .filter { !$0.isEmpty }.joined(separator: "\n")
            let detail = action.isEmpty ? reason : action
            command = kind == "command" ? (actionPrompt?.isEmpty == false ? actionPrompt : detail) : nil
            prompt = command ?? detail
            let summary = command != nil && actionTitle != prompt && actionTitle != reason ? actionTitle : nil
            let override = switch value["fullAccessOverride"].string {
            case "ask_rule": "Your approval rules require a decision for this action."
            case "provider_check": "The provider requires approval for this action in Full Access."
            default: ""
            }
            context = [summary, value["appName"].string, reason == detail || reason == prompt ? nil : reason, override]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            let supplied = value["options"].array.compactMap { option -> Option? in
                guard let label = option["label"].string, let decision = option["decision"].string else { return nil }
                return Option(label: label, decision: decision, warning: option["warning"].string)
            }
            options = entry == nil ? [] : supplied.isEmpty
                ? [Option(label: "Allow Once", decision: "accept"), Option(label: "Decline", decision: "decline")]
                : supplied
        }
    }

    private let title = label(size: 14, weight: .semibold, color: WorkspaceStyle.ink)
    private let count = label(size: 11, color: WorkspaceStyle.muted)
    private let details = NSTextView(frame: .zero)
    private lazy var detailScroll = textScroller(details)
    private let preview = Surface(WorkspaceStyle.commandPreview, radius: 8)
    private let terminalGlyph = row([WorkspaceStyle.icon("terminal", size: 14, tint: WorkspaceStyle.quota)])
    private let context = label(size: 12, color: WorkspaceStyle.secondary)
    private let notice = label(size: 11.5, color: WorkspaceStyle.muted)
    private let accept = ActionButton("Allow Once", style: .filled) {}
    private let decline = ActionButton("Decline", style: .capsule) {}
    private lazy var more = ActionButton("More options", symbol: "chevron.down", style: .subtle) {
        [weak self] in self?.showMore()
    }
    private lazy var copy = ActionButton("Copy command", symbol: "doc.on.doc", iconOnly: true, style: .subtle) {
        [weak self] in self?.copyCommand()
    }
    private lazy var disclosure = ActionButton("Expand command", style: .subtle) {
        [weak self] in
        guard let self else { return }
        setExpanded(!expanded)
    }
    private lazy var expansionRow = row([disclosure, NSView()])
    private lazy var footer = row([more, NSView(), decline, accept], spacing: 7)
    private lazy var previewHeight = detailScroll.heightAnchor.constraint(equalToConstant: 28)
    private var content: Content?
    private var syntax: TranscriptSyntax?
    private var extra: [Content.Option] = []
    private var respond: ((String) -> Void)?
    private var expanded = false
    private var copyFeedback: Task<Void, Never>?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let panel = Surface(WorkspaceStyle.composer, border: WorkspaceStyle.outline, radius: 14)
        let heading = row([title, NSView(), count])
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        context.maximumNumberOfLines = 4
        context.lineBreakMode = .byWordWrapping
        notice.maximumNumberOfLines = 2
        notice.lineBreakMode = .byWordWrapping
        details.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        details.textColor = WorkspaceStyle.ink
        details.textContainerInset = NSSize(width: 0, height: 5)
        details.textContainer?.lineFragmentPadding = 2
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        details.defaultParagraphStyle = paragraph
        details.setAccessibilityLabel("Approval details")
        let commandLine = row([terminalGlyph, detailScroll, copy], spacing: 5)
        commandLine.alignment = .top
        expansionRow.edgeInsets = NSEdgeInsets(top: 0, left: 33, bottom: 0, right: 0)
        fill(column([commandLine, expansionRow], spacing: 0, alignment: .width), in: preview, inset: 6)
        previewHeight.priority = .defaultHigh
        previewHeight.isActive = true
        for control in [terminalGlyph as NSView, copy] {
            control.widthAnchor.constraint(equalToConstant: 28).isActive = true
            control.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        disclosure.heightAnchor.constraint(equalToConstant: 24).isActive = true
        expansionRow.isHidden = true
        disclosure.font = .systemFont(ofSize: 11.5, weight: .medium)
        more.font = .systemFont(ofSize: 12, weight: .medium)
        more.image = WorkspaceStyle.symbol("chevron.down", size: 9, weight: .semibold)
        for button in [more, disclosure] {
            button.imagePosition = .imageTrailing
            button.imageHugsTitle = true
        }
        for button in [decline, more, accept] {
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            button.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        }
        accept.widthAnchor.constraint(greaterThanOrEqualToConstant: 88).isActive = true
        decline.widthAnchor.constraint(greaterThanOrEqualToConstant: 68).isActive = true
        fill(column([heading, preview, context, notice, footer], spacing: 8, alignment: .width), in: panel, inset: 12)
        fill(panel, in: self)
        setExpanded(false)
        isHidden = true
        setAccessibilityRole(.group)
        setAccessibilityLabel("Approval request")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func render(_ content: Content?, pendingCount: Int, notice message: String, error: Bool, respond: ((String) -> Void)?) {
        self.respond = respond
        isHidden = content == nil
        if self.content != content {
            self.content = content
            title.stringValue = content?.title ?? ""
            details.string = content?.prompt ?? ""
            renderSyntax()
            preview.isHidden = details.string.isEmpty
            terminalGlyph.isHidden = content?.command == nil
            copy.isHidden = terminalGlyph.isHidden
            expansionRow.isHidden = true
            setExpanded(false)
            resetCopyFeedback()
            context.stringValue = content?.context ?? ""
            context.toolTip = context.stringValue
            context.isHidden = context.stringValue.isEmpty
            let options = content?.options ?? []
            bind(accept, to: options.first { $0.decision == "accept" })
            bind(decline, to: options.first { $0.decision == "decline" })
            extra = options.filter { $0.decision != "accept" && $0.decision != "decline" }
            more.isHidden = extra.isEmpty
            needsLayout = true
        }
        guard content != nil else { return }
        count.isHidden = pendingCount <= 1
        count.stringValue = "\(pendingCount) pending"
        notice.stringValue = message
        notice.textColor = error ? WorkspaceStyle.negative : WorkspaceStyle.muted
        notice.toolTip = message
        notice.isHidden = message.isEmpty
        for button in [decline, more, accept] { button.isEnabled = respond != nil }
        footer.isHidden = decline.isHidden && more.isHidden && accept.isHidden
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        renderSyntax()
    }

    private func renderSyntax() {
        syntax = content?.command.flatMap {
            TranscriptSyntax($0, language: "shellscript", dark: TranscriptArtwork.isDark(effectiveAppearance))
        }
        guard let storage = details.textStorage, storage.length > 0 else { return }
        storage.addAttribute(.foregroundColor, value: WorkspaceStyle.ink, range: NSRange(location: 0, length: storage.length))
        guard let syntax, TranscriptSyntaxRenderer.shared.isAvailable else { return }
        guard !TranscriptSyntaxRenderer.shared.apply(syntax, to: storage) else { return }
        TranscriptSyntaxRenderer.shared.load(syntax) { [weak self] ready in
            guard ready, let self, self.syntax == syntax, let storage = self.details.textStorage else { return }
            TranscriptSyntaxRenderer.shared.apply(syntax, to: storage)
        }
    }

    override func layout() {
        super.layout()
        guard !isHidden, !preview.isHidden, detailScroll.contentSize.width > 0,
              let container = details.textContainer, let manager = details.layoutManager else { return }
        manager.ensureLayout(for: container)
        let fullHeight = ceil(manager.usedRect(for: container).height + 2 * details.textContainerInset.height)
        let collapsedHeight: CGFloat = 86
        let hideDisclosure = content?.command == nil || fullHeight <= collapsedHeight
        if expansionRow.isHidden != hideDisclosure { expansionRow.isHidden = hideDisclosure }
        let height = min(expanded ? 170 : collapsedHeight, max(28, fullHeight))
        if previewHeight.constant != height { previewHeight.constant = height }
    }

    private func setExpanded(_ expanded: Bool) {
        self.expanded = expanded
        disclosure.title = expanded ? "Collapse command" : "Expand command"
        disclosure.setAccessibilityLabel(disclosure.title)
        disclosure.image = WorkspaceStyle.symbol(expanded ? "chevron.up" : "chevron.down", size: 8, weight: .semibold)
        if !expanded {
            detailScroll.contentView.scroll(to: .zero)
            detailScroll.reflectScrolledClipView(detailScroll.contentView)
        }
        needsLayout = true
    }

    private func copyCommand() {
        guard let command = content?.command else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(command, forType: .string) else { return }
        copyFeedback?.cancel()
        copy.image = WorkspaceStyle.symbol("checkmark", size: 13, weight: .semibold)
        copy.toolTip = "Command copied"
        copy.setAccessibilityLabel("Command copied")
        copyFeedback = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1.2)) } catch { return }
            self?.resetCopyFeedback()
        }
    }

    private func resetCopyFeedback() {
        copyFeedback?.cancel()
        copyFeedback = nil
        copy.image = WorkspaceStyle.symbol("doc.on.doc", size: 13)
        copy.toolTip = "Copy command"
        copy.setAccessibilityLabel("Copy command")
    }

    private func bind(_ button: ActionButton, to option: Content.Option?) {
        button.isHidden = option == nil
        guard let option else { return }
        button.title = option.label
        button.setAccessibilityLabel(option.label)
        button.toolTip = option.warning
        button.image = option.warning == nil ? nil : WorkspaceStyle.symbol("exclamationmark.triangle", size: 11)
        button.imagePosition = .imageLeading
        button.actionBlock = { [weak self] in self?.respond?(option.decision) }
    }

    private func showMore() {
        guard let respond else { return }
        let menu = NSMenu()
        for option in extra {
            let item = menuItem(option.label, target: self, action: #selector(selectMore(_:)))
            item.toolTip = option.warning
            if option.warning != nil { item.image = WorkspaceStyle.symbol("exclamationmark.triangle", size: 11) }
            item.representedObject = { respond(option.decision) }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.maxY + 3), in: more)
    }

    @objc private func selectMore(_ item: NSMenuItem) {
        (item.representedObject as? () -> Void)?()
    }
}
