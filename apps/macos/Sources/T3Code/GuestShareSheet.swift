import AppKit

@MainActor
final class GuestShareSheet: NSWindowController {
    private let workspace: Workspace
    private let target: GuestShareTarget
    private let state = label(size: 12.5, weight: .medium, color: WorkspaceStyle.ink)
    private let note = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let link = NSTextField()
    private lazy var copy = ActionButton("Copy Link", symbol: "document.on.document") { [weak self] in self?.copyLink() }
    private lazy var linkRow = row([link, copy])
    private lazy var create = ActionButton("Create Link") { [weak self] in self?.createLink() }
    private lazy var stop = ActionButton("Stop Sharing", style: .subtle) { [weak self] in self?.stopSharing() }
    private lazy var done = ActionButton("Done") { [weak self] in self?.finish() }
    private var invitation: GuestShareInvitation?
    private var invitationWasCurrent = false
    private var operation: Task<Void, Never>?
    private var operationMessage: String?
    var onClose: (() -> Void)?

    init(workspace: Workspace, target: GuestShareTarget, threadTitle: String) {
        self.workspace = workspace
        self.target = target
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 234),
                              styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Share with Guest"
        window.isReleasedWhenClosed = false
        let surface = Surface(WorkspaceStyle.navigation)
        window.contentView = surface
        let title = label(threadTitle, size: 15, weight: .semibold, color: WorkspaceStyle.ink)
        title.toolTip = threadTitle
        for field in [note, errorLabel] {
            field.font = .systemFont(ofSize: 12)
            field.setContentHuggingPriority(.required, for: .vertical)
        }
        note.textColor = WorkspaceStyle.secondary
        errorLabel.textColor = WorkspaceStyle.negative
        link.isEditable = false
        link.isSelectable = true
        link.usesSingleLineMode = true
        link.lineBreakMode = .byTruncatingMiddle
        link.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        link.setAccessibilityLabel("Guest Link")
        done.keyEquivalent = "\u{1b}"
        let footer = row([stop, NSView(), done, create], spacing: 8)
        fill(column([title, state, note, linkRow, errorLabel, NSView(), footer], spacing: 10, alignment: .width), in: surface, inset: 17)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present(in parent: NSWindow) {
        guard let window, parent.attachedSheet == nil else { return }
        parent.beginSheet(window) { [weak self] _ in
            self?.invitation = nil
            self?.link.stringValue = ""
            self?.operation?.cancel()
            self?.onClose?()
        }
        sync()
    }

    func sync() {
        guard workspace.guestShareTarget(for: target.threadID) == target else { finish(); return }
        let detail = workspace.presentedDetail(for: target.threadID)
        let share = detail?.guestShare
        let now = Date()
        if let invitation {
            if !workspace.canCreateGuestShare { self.invitation = nil }
            else if invitation.isAvailable(for: share, at: now) { invitationWasCurrent = true }
            else if invitationWasCurrent || share?.id == invitation.shareID {
                self.invitation = nil
            }
        }
        let available = invitation?.isAvailable(for: share, at: now) == true
        let text = available ? invitation?.url.absoluteString ?? "" : ""
        if link.stringValue != text { link.stringValue = text }
        linkRow.isHidden = !available
        create.title = share == nil ? "Create Link" : "Replace Link"
        create.setAccessibilityLabel(create.title)
        create.isHidden = !workspace.canCreateGuestShare
        create.isEnabled = detail?.loaded == true && operation == nil
        stop.isHidden = share == nil || !workspace.can("orchestration:operate")
        stop.isEnabled = operation == nil
        done.isEnabled = operation == nil
        copy.isEnabled = operation == nil
        state.stringValue = {
            if let operationMessage { return operationMessage }
            if detail?.loaded != true { return "Loading conversation…" }
            if workspace.guestSharingEnabled == false { return "Guest links are off" }
            return share?.status(at: now) ?? "One-time link · Expires in 24 hours"
        }()
        note.stringValue = share == nil ?
            "A guest can see this conversation, including tool output and reasoning. Their messages wait for you to send or dismiss them." :
            "Replacing or stopping the link ends the current share and clears its waiting messages."
        errorLabel.isHidden = errorLabel.stringValue.isEmpty
    }

    private func createLink() {
        guard create.isEnabled, !create.isHidden else { return }
        run("Creating guest link…") { [weak self, workspace, target] in
            let invitation = try await workspace.createGuestShare(target)
            try Task.checkCancellation()
            self?.invitationWasCurrent = false
            self?.invitation = invitation
        }
    }

    private func stopSharing() {
        guard stop.isEnabled, !stop.isHidden, let shareID = workspace.presentedDetail(for: target.threadID)?.guestShare?.id else { return }
        run("Stopping guest sharing…") { [weak self, workspace, target] in
            try await workspace.closeGuestShare(target, shareID: shareID)
            try Task.checkCancellation()
            self?.finish()
        }
    }

    private func run(_ message: String, action: @escaping () async throws -> Void) {
        guard operation == nil else { return }
        errorLabel.stringValue = ""
        operationMessage = message
        operation = Task { [weak self] in
            do { try await action() }
            catch {
                if !Task.isCancelled { self?.errorLabel.stringValue = error.localizedDescription }
            }
            self?.operation = nil
            self?.operationMessage = nil
            if !Task.isCancelled { self?.sync() }
        }
        sync()
    }

    private func copyLink() {
        guard let invitation, workspace.canCreateGuestShare,
              workspace.guestShareTarget(for: target.threadID) == target,
              invitation.isAvailable(for: workspace.presentedDetail(for: target.threadID)?.guestShare, at: Date()) else {
            sync()
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(invitation.url.absoluteString, forType: .string)
    }

    private func finish() {
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
    }
}
