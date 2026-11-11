import AppKit

@MainActor
final class RepositoryRequestCheckout: NSWindowController, NSTextFieldDelegate {
    private let workspace: Workspace
    private let target: RepositoryTarget
    private let draftThreadID: String
    private let reference = NSTextField()
    private let titleField = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private lazy var lookup = ActionButton("Look Up") { [weak self] in self?.resolve() }
    private lazy var local = ActionButton("Use Local Checkout") { [weak self] in self?.prepare(mode: "local") }
    private lazy var worktree = ActionButton("Use Worktree") { [weak self] in self?.prepare(mode: "worktree") }
    private lazy var cancel = ActionButton("Cancel") { [weak self] in self?.closeSheet() }
    private var resolved: (input: String, request: Wire)?
    private var task: Task<Void, Never>?
    private var canOperate: Bool {
        workspace.canChangeRepository(target) && workspace.can("orchestration:operate") &&
            !workspace.sending.contains(.project(target.project.id))
    }
    var onClose: (() -> Void)?
    var onPrepared: ((WorkspaceCheckout, String?, Bool) -> Void)?

    init(workspace: Workspace, target: RepositoryTarget, initialReference: String? = nil) {
        self.workspace = workspace
        self.target = target
        draftThreadID = workspace.preparedDraftThreadID ?? UUID().uuidString
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 555, height: 264),
                              styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Thread from Pull Request"
        let surface = Surface(WorkspaceStyle.navigation)
        window.contentView = surface
        let intro = label("Open a new thread in \(target.project.name) from an existing change request.", size: 12, color: WorkspaceStyle.secondary)
        reference.placeholderString = "Pull request URL, number or checkout command"
        reference.stringValue = initialReference ?? ""
        reference.setAccessibilityLabel("Pull Request Reference")
        reference.delegate = self
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.maximumNumberOfLines = 2
        titleField.textColor = WorkspaceStyle.ink
        detail.font = .systemFont(ofSize: 11.5)
        detail.maximumNumberOfLines = 2
        detail.textColor = WorkspaceStyle.secondary
        message.font = .systemFont(ofSize: 11.5)
        message.maximumNumberOfLines = 3
        lookup.keyEquivalent = "\r"
        cancel.keyEquivalent = "\u{1b}"
        let prompt = row([reference, lookup])
        let status = column([titleField, detail, message], spacing: 5, alignment: .width)
        let footer = row([cancel, NSView(), local, worktree])
        fill(column([label("Thread from Pull Request", size: 16, weight: .semibold), intro, prompt, status, NSView(), footer],
                    spacing: 10, alignment: .width), in: surface, inset: 18)
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present(in parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window) { [weak self] _ in self?.onClose?() }
        window.makeFirstResponder(reference)
        if input != nil { resolve() }
    }

    func controlTextDidChange(_ obj: Notification) {
        resolved = nil
        setMessage("")
        render()
    }

    private var input: String? { RepositoryRequestReference(reference.stringValue)?.value }

    private func render() {
        let idle = task == nil
        let current = workspace.isCurrent(target)
        lookup.isEnabled = idle && current && input != nil
        reference.isEnabled = idle
        cancel.isEnabled = idle
        local.isEnabled = idle && resolved != nil && canOperate
        worktree.isEnabled = local.isEnabled
        if let request = resolved?.request {
            titleField.stringValue = "#\(request["number"].identifier ?? "")  \(request["title"].string ?? "")"
            let branch = [request["headBranch"].string, request["baseBranch"].string].compactMap { $0 }.joined(separator: " → ")
            detail.stringValue = [request["state"].string?.capitalized, branch].compactMap { $0 }.joined(separator: "  ·  ")
        } else {
            titleField.stringValue = ""
            detail.stringValue = ""
        }
        titleField.isHidden = resolved == nil
        detail.isHidden = resolved == nil
    }

    private func resolve() {
        guard lookup.isEnabled, let input else { return }
        resolved = nil
        run("Looking up change request…") {
            guard self.workspace.isCurrent(self.target) else { throw ClientError.disconnected }
            let result = try await self.workspace.request("git.resolvePullRequest", [
                "cwd": .string(self.target.project.root), "reference": .string(input),
            ])
            guard self.workspace.isCurrent(self.target) else { throw ClientError.disconnected }
            guard result["pullRequest"]["number"].int != nil else { throw ClientError.invalidResponse }
            self.resolved = (input, result["pullRequest"])
            self.setMessage("Choose where the new thread will work.")
        }
    }

    private func prepare(mode: String) {
        guard let resolved, canOperate else { return }
        run("Preparing \(mode == "local" ? "local checkout" : "worktree")…") {
            try self.workspace.requireRepositoryWrite(self.target)
            guard self.canOperate else { throw ClientError.disconnected }
            var payload: Payload = [
                "cwd": .string(self.target.project.root), "reference": .string(resolved.input), "mode": .string(mode),
            ]
            if mode == "worktree" { payload["threadId"] = .string(self.draftThreadID) }
            let result = try await self.workspace.request("git.preparePullRequestThread", payload)
            guard self.workspace.isCurrent(self.target) else { throw ClientError.disconnected }
            let branch = try result.requireString("branch")
            let checkout = result["worktreePath"].string.map { WorkspaceCheckout.worktree(path: $0, branch: branch) } ?? .root(branch: branch)
            self.task = nil
            self.closeSheet()
            self.onPrepared?(checkout, mode == "worktree" ? self.draftThreadID : nil, result["isOnPullRequestHead"].bool != false)
        }
    }

    private func run(_ status: String, action: @escaping @MainActor () async throws -> Void) {
        guard task == nil else { return }
        setMessage(status)
        task = Task {
            defer { task = nil; render() }
            do { try await action() }
            catch { setMessage(error.localizedDescription, error: true) }
        }
        render()
    }

    private func setMessage(_ value: String, error: Bool = false) {
        message.stringValue = value
        message.textColor = error ? WorkspaceStyle.negative : WorkspaceStyle.muted
    }

    private func closeSheet() {
        guard task == nil, let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }
}
