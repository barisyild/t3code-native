import AppKit

@MainActor
final class T3ConnectHostView: NSView {
    private let operations: T3ConnectHostOperations
    private let account: T3ConnectAccount?
    private let heading = label(size: 13, weight: .semibold, color: WorkspaceStyle.ink)
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let tunnel = NSSwitch()
    private let activity = NSSwitch()
    private let holdWebhooks = NSSwitch()
    private lazy var holdRow = setting("Hold webhooks while offline", toggle: holdWebhooks)
    private lazy var check = ActionButton("Check Tunnel", symbol: "arrow.clockwise", style: .subtle) { [weak self] in self?.checkTunnel() }

    private var presented = false
    private var target: T3ConnectHostTarget?
    private var state: T3ConnectHostState?
    private var lastCheck: T3ConnectReachability?
    private var refreshTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var operationMessage: String?
    private var readError: String?
    private var operationError: String?
    private var operationNote: String?
    var onLinkChange: (() -> Void)?

    init(workspace: Workspace, account: T3ConnectAccount?, relay: ManagedRelayClient?) {
        operations = .init(workspace: workspace, relay: relay)
        self.account = account
        super.init(frame: .zero)
        let surface = Surface(WorkspaceStyle.navigation, border: WorkspaceStyle.outline, radius: 9)
        for field in [summary, message] {
            field.font = .systemFont(ofSize: 11.5)
            field.maximumNumberOfLines = 3
            field.setContentHuggingPriority(.required, for: .vertical)
        }
        summary.textColor = WorkspaceStyle.muted
        message.textColor = WorkspaceStyle.muted
        let controls = [setting("T3 Connect tunnel", toggle: tunnel),
                        setting("Publish agent activity", toggle: activity), holdRow]
        fill(column([row([heading, NSView(), check]), summary] + controls + [message], spacing: 7, alignment: .width), in: surface, inset: 11)
        fill(surface, in: self)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setting(_ title: String, toggle: NSSwitch) -> NSView {
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(changeSetting(_:))
        toggle.setAccessibilityLabel(title)
        return row([label(title, size: 12, color: WorkspaceStyle.ink), NSView(), toggle])
    }

    func setPresented(_ value: Bool) {
        guard presented != value else { return }
        presented = value
        if value {
            sync()
            if target != nil && pollTask == nil { startPolling() }
            refresh()
        } else {
            refreshTask?.cancel()
            refreshTask = nil
            pollTask?.cancel()
            pollTask = nil
        }
    }

    func sync() {
        guard presented else { return }
        let next = operations.workspace.t3ConnectHostTarget
        if target != next {
            target = next
            state = nil
            lastCheck = nil
            readError = nil
            operationError = nil
            operationNote = nil
            refreshTask?.cancel()
            refreshTask = nil
            pollTask?.cancel()
            pollTask = nil
            if next != nil {
                startPolling()
                refresh()
            }
        }
        render()
    }

    func refresh() {
        guard presented, let target, operation == nil, refreshTask == nil else { return }
        refreshTask = Task { [weak self, operations] in
            do {
                let next = try await operations.state(target)
                guard let self, !Task.isCancelled, self.target == target else { return }
                state = next
                lastCheck = nil
                readError = nil
                refreshTask = nil
                render()
            } catch {
                guard let self, !Task.isCancelled, self.target == target else { return }
                readError = error.localizedDescription
                refreshTask = nil
                render()
            }
        }
        render()
    }

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) }
                catch { return }
                guard let self else { return }
                refresh()
            }
        }
    }

    private var canLinkHere: Bool {
        state?.linkableHere == true && target?.localOrigin != nil && operations.relay != nil &&
            account?.identity != nil && !operations.workspace.sharingConfiguration.blocksConnect
    }

    private func canApply(_ update: T3ConnectHostState.Update) -> Bool {
        guard operation == nil, operations.workspace.can("relay:write"), let state else { return false }
        if case .link = state.change(to: state.desired(update)) { return canLinkHere }
        return true
    }

    private func render() {
        isHidden = target == nil
        guard target != nil else { return }
        heading.stringValue = operations.workspace.environment?.name ?? "Connected environment"
        let tunnelOn = state?.tunnel == true
        let activityOn = state?.revoked == false && state?.activity == true
        tunnel.state = tunnelOn ? .on : .off
        activity.state = activityOn ? .on : .off
        holdWebhooks.state = state?.holdWebhooks == true ? .on : .off
        tunnel.isEnabled = canApply(.tunnel(!tunnelOn))
        activity.isEnabled = canApply(.activity(!activityOn))
        holdRow.isHidden = !tunnelOn
        holdWebhooks.isEnabled = tunnelOn && canApply(.holdWebhooks(state?.holdWebhooks != true))
        holdWebhooks.toolTip = "Keep webhook requests for up to 24 hours while the environment is offline."
        check.isHidden = !tunnelOn
        check.isEnabled = operation == nil

        let reachability = lastCheck ?? state?.reachability
        summary.stringValue = {
            guard let state else { return refreshTask == nil ? "T3 Connect status unavailable" : "Reading T3 Connect status…" }
            if state.revoked { return "This environment was removed from T3 Connect." }
            if state.tunnel {
                let status = reachability?.reachable == true ? reachability?.detail : "Tunnel enabled"
                return [status, state.hostname].compactMap { $0 }.joined(separator: " · ")
            }
            if state.linked { return "Linked for agent activity" }
            if operations.workspace.sharingConfiguration.blocksConnect { return "This environment’s policy restricts T3 Connect." }
            if !state.linkableHere || target?.localOrigin == nil { return "Enable T3 Connect on this environment’s host." }
            if operations.relay == nil { return "T3 Connect is unavailable in this build." }
            if account?.identity == nil { return "Sign in to link this environment." }
            return "Not linked to T3 Connect"
        }()
        summary.toolTip = summary.stringValue
        let unreachable = state?.tunnel == true && reachability?.reachable == false ? reachability?.detail : nil
        message.stringValue = operationMessage ?? operationError ?? operationNote ?? readError ?? unreachable ?? ""
        message.textColor = operationMessage == nil && (operationError != nil || readError != nil || unreachable != nil)
            ? WorkspaceStyle.negative : WorkspaceStyle.muted
        message.toolTip = message.stringValue
        message.isHidden = message.stringValue.isEmpty
        tunnel.toolTip = !tunnel.isEnabled && state?.tunnel == true && state?.activity == true && target?.localOrigin == nil
            ? "Open this environment on its host to keep activity publishing while turning off the tunnel." : nil
    }

    @objc private func changeSetting(_ sender: NSSwitch) {
        let enabled = sender.state == .on
        let update: T3ConnectHostState.Update = sender === tunnel ? .tunnel(enabled) :
            sender === activity ? .activity(enabled) : .holdWebhooks(enabled)
        guard canApply(update) else { render(); return }
        let accountID = account?.identity?.id
        run("Updating T3 Connect…", changed: true) { [weak self, operations] target in
            try await operations.apply(update, target: target, accountID: accountID, approveInstall: { version in
                await self?.confirmInstall(version) ?? false
            }, progress: { message in
                guard let self, self.target == target else { return }
                self.operationMessage = message
                self.render()
            })
        }
    }

    private func checkTunnel() {
        run("Checking the tunnel…", changed: false) { [weak self, operations] target in
            let result = try await operations.check(target)
            if self?.target == target { self?.lastCheck = result }
            return nil
        }
    }

    private func run(_ status: String, changed: Bool, action: @escaping (T3ConnectHostTarget) async throws -> String?) {
        guard let target, operation == nil else { return }
        refreshTask?.cancel()
        refreshTask = nil
        operationError = nil
        operationNote = nil
        operationMessage = status
        operation = Task { [weak self] in
            do {
                let note = try await action(target)
                if self?.target == target { self?.operationNote = note }
            } catch is CancellationError { }
            catch {
                if self?.target == target { self?.operationError = error.localizedDescription }
            }
            guard let self else { return }
            var linkChanged = changed
            if changed, self.target == target {
                do {
                    let next = try await operations.state(target)
                    if self.target == target {
                        linkChanged = state?.linked != next.linked || state?.tunnel != next.tunnel || state?.revoked != next.revoked
                        state = next
                        lastCheck = nil
                        readError = nil
                    }
                } catch {
                    if self.target == target { readError = error.localizedDescription }
                }
            }
            operation = nil
            operationMessage = nil
            if linkChanged { onLinkChange?() }
            if self.target != target { refresh() }
            render()
        }
        render()
    }

    private func confirmInstall(_ version: String) async -> Bool {
        guard let window, window.isVisible, window.attachedSheet == nil else { return false }
        let alert = NSAlert()
        alert.messageText = "Install the T3 Connect relay client?"
        alert.informativeText = "T3 Code will install cloudflared \(version) on the connected host to run this tunnel."
        alert.addButton(withTitle: "Install & Enable")
        alert.addButton(withTitle: "Cancel")
        let result = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        return result == .alertFirstButtonReturn
    }
}
