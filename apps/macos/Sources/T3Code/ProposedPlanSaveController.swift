import AppKit

@MainActor
final class ProposedPlanSaveController: NSWindowController, NSTextFieldDelegate {
    private let path = NSTextField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var available = true
    private var task: Task<Void, Never>?
    private lazy var save = ActionButton("Save to Workspace") { [weak self] in self?.submit() }
    private lazy var cancel = ActionButton("Cancel") { [weak self] in self?.closeSheet() }
    var onSubmit: (@MainActor (String) async throws -> Void)?
    var onClose: (() -> Void)?

    init(plan: ProposedPlan, workspaceRoot: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 224),
                              styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Save Plan to Workspace"
        let surface = Surface(WorkspaceStyle.navigation)
        window.contentView = surface
        let heading = label("Save Plan to Workspace", size: 16, weight: .semibold, color: WorkspaceStyle.ink)
        let root = label(workspaceRoot, size: 11.5, color: WorkspaceStyle.secondary)
        root.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        root.lineBreakMode = .byTruncatingMiddle
        root.toolTip = workspaceRoot
        path.stringValue = plan.filename
        path.placeholderString = plan.filename
        path.font = .systemFont(ofSize: 13)
        path.delegate = self
        path.setAccessibilityLabel("Workspace Path")
        status.font = .systemFont(ofSize: 11.5)
        status.maximumNumberOfLines = 3
        status.textColor = WorkspaceStyle.negative
        cancel.keyEquivalent = "\u{1b}"
        save.keyEquivalent = "\r"
        let description = column([label("Save a Markdown file relative to", size: 12, color: WorkspaceStyle.muted), root],
                                 spacing: 4, alignment: .width)
        let field = column([label("Workspace path", size: 12, weight: .medium), path], spacing: 5, alignment: .width)
        fill(column([heading, description, field, status, NSView(), row([NSView(), cancel, save])],
                    spacing: 12, alignment: .width), in: surface, inset: 18)
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present(in parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window) { [weak self] _ in self?.onClose?() }
        window.makeFirstResponder(path)
        path.selectText(nil)
    }

    func setAvailable(_ available: Bool) {
        guard self.available != available else { return }
        self.available = available
        status.stringValue = available ? "" : "This workspace is no longer available. Reopen the plan after reconnecting."
        render()
    }

    func controlTextDidChange(_ notification: Notification) {
        if available { status.stringValue = "" }
        render()
    }

    private func render() {
        path.isEditable = task == nil
        save.title = task == nil ? "Save to Workspace" : "Saving…"
        save.isEnabled = task == nil && available && !path.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        cancel.isEnabled = task == nil
        status.isHidden = status.stringValue.isEmpty
    }

    private func submit() {
        guard task == nil, available, let onSubmit else { return }
        let relativePath = path.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !relativePath.isEmpty else { return }
        guard relativePath.utf16.count <= 512 else {
            status.stringValue = "Use a workspace path of 512 characters or fewer."
            render()
            return
        }
        status.stringValue = ""
        task = Task {
            do {
                try await onSubmit(relativePath)
                task = nil
                closeSheet()
            } catch {
                task = nil
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
