import AppKit

@MainActor
final class QuestionAnswerController: NSWindowController, NSTextViewDelegate {
    let target: Workspace.QuestionResponseTarget
    private let questions: [AgentQuestion]
    private let supportsAttachments: Bool
    private let editor = AttachmentTextView()
    private let title = label(size: 16, weight: .semibold)
    private let progress = label(size: 11.5, color: WorkspaceStyle.muted)
    private let questionText = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let optionList = NSStackView()
    private let picker = NSPopUpButton()
    private var formScroll: NSScrollView?
    private lazy var input = textScroller(editor, editable: true)
    private lazy var attachmentMenu = ActionButton("Attachments", symbol: "paperclip", style: .subtle) { [weak self] in
        self?.showAttachments()
    }
    private lazy var attach = ActionButton("Attach Files…", symbol: "plus", style: .subtle) { [weak self] in
        self?.chooseFiles()
    }
    private lazy var attachmentTools = row([attachmentMenu, attach, NSView()])
    private lazy var previous = ActionButton("Previous") { [weak self] in self?.move(-1) }
    private lazy var next = ActionButton("Next") { [weak self] in self?.advance() }
    private lazy var cancel = ActionButton("Cancel") { [weak self] in self?.closeSheet() }
    private var index = 0
    private var drafts: [String: QuestionAnswerDraft] = [:]
    private var available = true
    private var preparation: Task<Void, Never>?
    private var submission: Task<Void, Never>?
    private var attempt: Workspace.QuestionResponseAttempt?
    var onSubmit: (@MainActor (Workspace.QuestionResponseAttempt) async throws -> Void)?
    var onClose: (() -> Void)?

    init(target: Workspace.QuestionResponseTarget, questions: [AgentQuestion], supportsAttachments: Bool) {
        self.target = target
        self.questions = questions
        self.supportsAttachments = supportsAttachments
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 395),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = questions.count == 1 ? "Agent Question" : "Agent Questions"
        window.contentMinSize = NSSize(width: 450, height: 320)
        let surface = Surface(WorkspaceStyle.navigation)
        window.contentView = surface
        title.textColor = WorkspaceStyle.ink
        progress.setContentCompressionResistancePriority(.required, for: .horizontal)
        questionText.font = .systemFont(ofSize: 13)
        questionText.textColor = WorkspaceStyle.ink
        status.font = .systemFont(ofSize: 11.5)
        status.maximumNumberOfLines = 3
        optionList.orientation = .vertical
        optionList.alignment = .leading
        optionList.spacing = 5
        picker.target = self
        picker.action = #selector(pickOption)
        picker.setAccessibilityLabel("Answer options")
        editor.font = .systemFont(ofSize: 14)
        editor.textColor = WorkspaceStyle.ink
        editor.insertionPointColor = WorkspaceStyle.ink
        editor.textContainerInset = NSSize(width: 7, height: 7)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.allowsUndo = true
        editor.delegate = self
        editor.setAccessibilityLabel("Answer")
        input.heightAnchor.constraint(equalToConstant: 92).isActive = true
        let answer = Surface(WorkspaceStyle.canvas, border: WorkspaceStyle.outline, radius: 8)
        fill(input, in: answer, inset: 2)
        let fields = column([questionText, optionList, answer, attachmentTools], spacing: 10, alignment: .width)
        let scroll = scroller(for: fields)
        formScroll = scroll
        fields.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            fields.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            fields.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            fields.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        cancel.keyEquivalent = "\u{1b}"
        next.keyEquivalent = "\r"
        next.keyEquivalentModifierMask = .command
        fill(column([row([title, NSView(), progress]), scroll, status, row([previous, NSView(), cancel, next])],
                    spacing: 12, alignment: .width), in: surface, inset: 18)
        showQuestion()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var question: AgentQuestion { questions[index] }
    private var draft: QuestionAnswerDraft {
        get { drafts[question.id] ?? question.initialDraft }
        set { drafts[question.id] = newValue }
    }
    private var acceptsFiles: Bool { supportsAttachments && question.custom }
    private var busy: Bool { preparation != nil || submission != nil }

    func present(in parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window) { [weak self] _ in self?.onClose?() }
        focusAnswer()
    }

    func setAvailable(_ available: Bool) {
        guard self.available != available else { return }
        self.available = available
        showStatus(available ? "" : "This question is no longer available to answer.")
        render()
    }

    func textDidChange(_ notification: Notification) {
        draft.text = editor.string
        if available, !busy { showStatus("") }
        render()
    }

    private func showQuestion() {
        title.stringValue = question.title
        progress.stringValue = "\(index + 1) of \(questions.count)"
        progress.isHidden = questions.count == 1
        questionText.stringValue = question.text
        editor.string = draft.text
        editor.undoManager?.removeAllActions()
        input.superview?.isHidden = !question.custom
        if acceptsFiles {
            editor.onReadAttachment = { [weak self] pasteboard in
                guard let self, available, submission == nil else { return false }
                let inputs = AttachmentInput.read(pasteboard)
                guard !inputs.isEmpty else { return false }
                prepare(inputs)
                return true
            }
        } else { editor.onReadAttachment = nil }
        for child in optionList.arrangedSubviews {
            optionList.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
        if question.multiple {
            for (index, option) in question.options.enumerated() {
                let button = NSButton(checkboxWithTitle: option.label, target: self, action: #selector(toggleOption(_:)))
                button.tag = index
                button.toolTip = option.detail
                button.state = draft.selected.contains(index) ? .on : .off
                optionList.addArrangedSubview(button)
            }
        } else if !question.options.isEmpty {
            picker.removeAllItems()
            picker.addItems(withTitles: ["Choose an option…"] + question.options.map(\.label))
            for (index, option) in question.options.enumerated() { picker.item(at: index + 1)?.toolTip = option.detail }
            picker.selectItem(at: draft.selected.first.map { $0 + 1 } ?? 0)
            optionList.addArrangedSubview(picker)
        }
        optionList.isHidden = question.options.isEmpty
        showStatus("")
        render()
        window?.contentView?.layoutSubtreeIfNeeded()
        if let formScroll, let document = formScroll.documentView {
            let clip = formScroll.contentView
            let top = document.isFlipped ? document.bounds.minY : max(document.bounds.minY, document.bounds.maxY - clip.bounds.height)
            clip.scroll(to: NSPoint(x: document.bounds.minX, y: top))
            formScroll.reflectScrolledClipView(clip)
        }
    }

    private func focusAnswer() {
        if question.custom { window?.makeFirstResponder(editor) }
        else { window?.makeFirstResponder(optionList.arrangedSubviews.first) }
    }

    private func render() {
        let enabled = available && !busy
        let count = draft.files.count
        attachmentMenu.title = count == 1 ? draft.files[0].name : "\(count) attachments"
        attachmentMenu.setAccessibilityLabel(attachmentMenu.title)
        attachmentMenu.isHidden = count == 0
        attachmentMenu.isEnabled = enabled
        attach.isHidden = !acceptsFiles
        attach.isEnabled = enabled
        attachmentTools.isHidden = !acceptsFiles && count == 0
        editor.isEditable = submission == nil
        for control in optionList.arrangedSubviews.compactMap({ $0 as? NSControl }) { control.isEnabled = enabled }
        previous.isHidden = index == 0
        previous.isEnabled = enabled
        next.title = index + 1 == questions.count ? "Send Answers" : "Next"
        next.isEnabled = enabled && (!question.required || draft.answer(for: question) != nil || count > 0)
        cancel.isEnabled = submission == nil
        status.isHidden = status.stringValue.isEmpty
    }

    @objc private func toggleOption(_ sender: NSButton) {
        if sender.state == .on { draft.selected.insert(sender.tag) }
        else { draft.selected.remove(sender.tag) }
        showStatus("")
        render()
    }

    @objc private func pickOption() {
        draft.selected = picker.indexOfSelectedItem > 0 ? [picker.indexOfSelectedItem - 1] : []
        showStatus("")
        render()
    }

    private func chooseFiles() {
        guard available, acceptsFiles, !busy, let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach Files"
        panel.beginSheetModal(for: window) { [weak self] result in
            if result == .OK { self?.prepare(panel.urls.map(AttachmentInput.file)) }
        }
    }

    private func prepare(_ inputs: [AttachmentInput]) {
        guard available, acceptsFiles, submission == nil else { return }
        guard preparation == nil else {
            showStatus("Wait for the current attachments to finish preparing.", error: true)
            return
        }
        showStatus("Preparing attachments…")
        preparation = Task { [weak self] in
            defer {
                self?.preparation = nil
                self?.render()
            }
            do {
                let additions = try await AttachmentInput.prepare(inputs)
                try Task.checkCancellation()
                guard let self else { return }
                try PickedAttachment.validate(drafts.values.flatMap(\.files) + additions)
                draft.files += additions
                if available { showStatus("") }
            } catch {
                if !Task.isCancelled, let self, available { showStatus(error.localizedDescription, error: true) }
            }
        }
        render()
    }

    private func showAttachments() {
        let menu = NSMenu()
        for (index, file) in draft.files.enumerated() {
            let item = menuItem("Remove \(file.name)", target: self, action: #selector(removeFile(_:)))
            item.tag = index
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: attachmentMenu.bounds.height), in: attachmentMenu)
    }

    @objc private func removeFile(_ sender: NSMenuItem) {
        guard available, !busy, draft.files.indices.contains(sender.tag) else { return }
        draft.files.remove(at: sender.tag)
        showStatus("")
        render()
    }

    private func move(_ offset: Int) {
        guard available, !busy, questions.indices.contains(index + offset) else { return }
        index += offset
        showQuestion()
        focusAnswer()
    }

    private func advance() {
        guard next.isEnabled else { return }
        if index + 1 < questions.count { move(1); return }
        guard let onSubmit else { return }
        do {
            let content = try QuestionResponseContent(questions: questions, drafts: drafts, supportsAttachments: supportsAttachments)
            let attempt = attempt.flatMap { $0.content == content ? $0 : nil } ?? .init(content: content)
            self.attempt = attempt
            showStatus("Sending answers…")
            submission = Task {
                do {
                    try await onSubmit(attempt)
                    submission = nil
                    closeSheet()
                } catch {
                    submission = nil
                    showStatus(error.localizedDescription, error: true)
                    render()
                }
            }
            render()
        } catch {
            showStatus(error.localizedDescription, error: true)
            render()
        }
    }

    private func closeSheet() {
        guard submission == nil, let window, let parent = window.sheetParent else { return }
        preparation?.cancel()
        parent.endSheet(window)
    }

    private func showStatus(_ message: String, error: Bool = false) {
        status.stringValue = message
        status.textColor = error ? WorkspaceStyle.negative : WorkspaceStyle.muted
        status.isHidden = message.isEmpty
    }
}
