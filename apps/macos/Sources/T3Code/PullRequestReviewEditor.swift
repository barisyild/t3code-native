import AppKit

@MainActor
final class PullRequestReviewEditor: NSWindowController, NSTextViewDelegate {
    enum Option: String {
        case comment = "general"
        case reviewComment = "comment"
        case approve
        case requestChanges = "request-changes"

        var title: String {
            switch self {
            case .comment: "Comment"
            case .reviewComment: "Review comment"
            case .approve: "Approve"
            case .requestChanges: "Request changes"
            }
        }
    }

    private let options: [Option]
    private let editor = NSTextView()
    private let kind: NSSegmentedControl
    private let status = NSTextField(wrappingLabelWithString: "")
    private lazy var submit = ActionButton("Post Comment") { [weak self] in self?.save() }
    private lazy var cancel = ActionButton("Cancel") { [weak self] in self?.closeSheet() }
    private var task: Task<Void, Never>?
    var onSubmit: ((Option, String) async throws -> Void)?
    var onClose: (() -> Void)?

    init(title: String, viewer: String?, options: [Option]) {
        self.options = options
        kind = NSSegmentedControl(labels: options.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 316),
                              styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Review Pull Request"
        let surface = Surface(WorkspaceStyle.navigation)
        window.contentView = surface
        let heading = label("Review Pull Request", size: 16, weight: .semibold)
        let subject = label(title, size: 12, color: WorkspaceStyle.muted)
        subject.toolTip = title
        kind.controlSize = .small
        kind.selectedSegment = 0
        kind.setAccessibilityLabel("Review Type")
        kind.target = self
        kind.action = #selector(changeOption)
        let identity = label(viewer.map { "Posting as @\($0)" } ?? "", size: 11, color: WorkspaceStyle.muted)
        editor.font = .systemFont(ofSize: 13)
        editor.textColor = WorkspaceStyle.ink
        editor.insertionPointColor = WorkspaceStyle.ink
        editor.textContainerInset = NSSize(width: 5, height: 5)
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.setAccessibilityLabel("Review Body")
        editor.delegate = self
        let prompt = Surface(WorkspaceStyle.canvas, border: WorkspaceStyle.outline, radius: 6)
        fill(textScroller(editor, editable: true), in: prompt, inset: 2)
        prompt.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        status.font = .systemFont(ofSize: 11.5)
        status.textColor = WorkspaceStyle.muted
        status.maximumNumberOfLines = 3
        cancel.keyEquivalent = "\u{1b}"
        fill(column([row([heading, NSView(), identity]), subject, kind, prompt, status, row([NSView(), cancel, submit])],
                    spacing: 9, alignment: .width), in: surface, inset: 18)
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present(in parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window) { [weak self] _ in self?.onClose?() }
        window.makeFirstResponder(editor)
    }

    private var selected: Option? { options.indices.contains(kind.selectedSegment) ? options[kind.selectedSegment] : nil }
    private var valid: Bool {
        selected != nil && editor.string.utf16.count <= 65_536 &&
            (selected == .approve || !editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @objc private func changeOption() { status.stringValue = ""; render() }
    func textDidChange(_ notification: Notification) { status.stringValue = ""; render() }

    private func render() {
        let idle = task == nil
        submit.title = selected == .comment ? "Post Comment" : "Submit Review"
        submit.setAccessibilityLabel(submit.title)
        submit.isEnabled = idle && valid
        cancel.isEnabled = idle
        editor.isEditable = idle
        kind.isEnabled = idle
        if editor.string.utf16.count > 65_536 {
            status.stringValue = "The review can be up to 65,536 characters."
            status.textColor = WorkspaceStyle.negative
        }
        status.isHidden = status.stringValue.isEmpty
    }

    private func save() {
        guard task == nil, valid, let selected, let onSubmit else { return }
        let body = editor.string
        status.textColor = WorkspaceStyle.muted
        status.stringValue = "Posting…"
        task = Task {
            do {
                try await onSubmit(selected, body)
                task = nil
                closeSheet()
            } catch {
                task = nil
                status.textColor = WorkspaceStyle.negative
                status.stringValue = error.localizedDescription
                render()
            }
        }
        render()
    }

    private func closeSheet() {
        guard task == nil, let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }
}
