import AppKit
import SwiftTerm

struct TerminalContextTarget: Equatable {
    let environmentID: String
    let threadID: String
    let connection: UUID
}

@MainActor
private final class ConversationTerminalView: SwiftTerm.TerminalView {
    var onContextMenu: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        onContextMenu?() ?? super.menu(for: event)
    }
}

@MainActor
final class TerminalPanel: NSView, @preconcurrency TerminalViewDelegate {
    private struct ThreadKey: Hashable {
        let environmentID: String
        let threadID: String
    }

    private struct Scope: Equatable {
        let thread: ThreadKey
        let connection: UUID
    }

    private struct Sessions {
        var selected = "term-1"
        var actionTitles: [String: String] = [:]
    }

    private struct SelectedOutput {
        let target: TerminalContextTarget
        let terminalID: String
        let selection: TerminalSelection
    }

    private let workspace: Workspace
    private let terminal = ConversationTerminalView(frame: .zero)
    private let status = label("Terminal", size: 11, weight: .semibold, color: .secondaryLabelColor)
    private let picker = NSPopUpButton()
    private lazy var interrupt = ActionButton("Interrupt (Control-C)", symbol: "stop.circle", iconOnly: true) { [weak self] in
        self?.enqueue("\u{3}")
    }
    private lazy var closeShell = ActionButton("End Shell", symbol: "power", iconOnly: true) { [weak self] in self?.endShell() }
    private var streamTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var pendingInput = ""
    private var scope: Scope?
    private var attachedID: String?
    private var sessions: [ThreadKey: Sessions] = [:]
    private var remoteTitles: [String: String] = [:]
    private var running = false
    private var dimensions = (cols: 80, rows: 24)
    private var arguments: Payload {
        guard let scope, let attachedID else { return [:] }
        return ["threadId": .string(scope.thread.threadID), "terminalId": .string(attachedID)]
    }
    var onClose: (() -> Void)?
    var onError: ((String) -> Void)?
    var onAddContext: ((TerminalContext, TerminalContextTarget) throws -> Void)?

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(frame: .zero)
        let close = ActionButton("Hide Terminal", symbol: "xmark", iconOnly: true) { [weak self] in self?.onClose?() }
        let restart = ActionButton("Start or Reconnect Shell", symbol: "arrow.clockwise", iconOnly: true) { [weak self] in
            self?.start(restart: true)
            self?.focus()
        }
        let shell = Surface(WorkspaceStyle.composer, border: WorkspaceStyle.outline, radius: 11)
        fill(shell, in: self)
        picker.isBordered = false
        picker.font = .systemFont(ofSize: 11.5, weight: .medium)
        picker.target = self
        picker.action = #selector(chooseSession)
        picker.setAccessibilityLabel("Terminal Session")
        picker.isHidden = true
        let header = row([picker, status, NSView(), interrupt, restart, closeShell, close], spacing: 4)
        terminal.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        terminal.terminalDelegate = self
        terminal.onContextMenu = { [weak self] in self?.terminalMenu() }
        terminal.setAccessibilityLabel("Terminal")
        terminal.heightAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        let stack = column([header, terminal], spacing: 4, alignment: .width)
        fill(stack, in: shell, inset: 8)
        setRunning(false)
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            terminal.nativeBackgroundColor = WorkspaceStyle.canvas
            terminal.nativeForegroundColor = WorkspaceStyle.ink
        }
    }

    func sync() {
        guard let next = currentScope else {
            hide()
            setStatus(workspace.connection == .ready ? "Terminal · Select a thread" : "Terminal · Disconnected")
            return
        }
        if scope != next {
            hide()
            scope = next
            subscribeSessions(next)
        }
        if attachedID != selectedID || streamTask == nil { start() }
        renderPicker()
    }

    func focus() { window?.makeFirstResponder(terminal) }

    func reveal(_ action: ProjectActionTerminal) {
        guard let next = currentScope, next.connection == action.target.project.connection,
              next.thread.threadID == action.target.threadID else { return }
        sessions[next.thread, default: Sessions()].selected = action.id
        sessions[next.thread, default: Sessions()].actionTitles[action.id] = action.title
        sync()
        focus()
    }

    func hide() {
        stopStream()
        metadataTask?.cancel()
        metadataTask = nil
        scope = nil
        remoteTitles.removeAll()
        renderPicker()
    }

    private var currentScope: Scope? {
        guard let connection = workspace.connectionID, let environmentID = workspace.environment?.id,
              let threadID = workspace.selectedThread?.id else { return nil }
        return .init(thread: .init(environmentID: environmentID, threadID: threadID), connection: connection)
    }

    private var selectedID: String { scope.flatMap { sessions[$0.thread]?.selected } ?? "term-1" }

    private func stopStream() {
        streamTask?.cancel()
        streamTask = nil
        attachedID = nil
        terminal.selectNone()
        setRunning(false)
    }

    private func start(restart: Bool = false) {
        stopStream()
        terminal.getTerminal().resetToInitialState()
        guard let scope, scope == currentScope, let thread = workspace.selectedThread, let cwd = workspace.workspacePath else {
            setStatus("Terminal · Select a thread")
            return
        }
        guard workspace.can("terminal:operate") else {
            setStatus("Terminal · Connection unavailable")
            return
        }
        let id = selectedID
        attachedID = id
        setStatus("Terminal · Connecting…")
        var payload = arguments.merging([
            "cols": .int(dimensions.cols), "rows": .int(dimensions.rows),
            "restartIfNotRunning": .bool(restart), "resume": .bool(!restart),
        ]) { _, new in new }
        if id == "term-1" || restart {
            payload["cwd"] = .string(cwd)
            payload["worktreePath"] = thread.worktreePath.map(Wire.string) ?? .null
        }
        streamTask = Task {
            do {
                try await workspace.subscribe("terminal.attach", payload) { frames in
                    guard self.scope == scope, self.attachedID == id else { return }
                    self.consume(frames)
                }
            }
            catch {
                guard !Task.isCancelled, self.scope == scope, attachedID == id else { return }
                setRunning(false)
                setStatus("Terminal · Disconnected")
                terminal.feed(text: "\r\n\(error.localizedDescription)\r\n")
            }
        }
    }

    private func subscribeSessions(_ scope: Scope) {
        guard workspace.can("terminal:read") else { return }
        metadataTask = Task { [weak self, workspace] in
            try? await workspace.subscribe("subscribeTerminalMetadata", [:]) { frames in
                guard let self, self.scope == scope else { return }
                for frame in frames {
                    switch frame["type"].string {
                    case "snapshot":
                        self.remoteTitles.removeAll(keepingCapacity: true)
                        for terminal in frame["terminals"].array { self.recordSession(terminal, scope: scope) }
                    case "upsert": self.recordSession(frame["terminal"], scope: scope)
                    case "remove":
                        if frame["threadId"].string == scope.thread.threadID, let id = frame["terminalId"].string {
                            self.remoteTitles.removeValue(forKey: id)
                            self.sessions[scope.thread]?.actionTitles.removeValue(forKey: id)
                        }
                    default: break
                    }
                }
                self.renderPicker()
            }
        }
    }

    private func recordSession(_ value: Wire, scope: Scope) {
        guard value["threadId"].string == scope.thread.threadID, let id = value["terminalId"].string else { return }
        remoteTitles[id] = value["label"].string ?? ""
    }

    private func renderPicker() {
        let local = scope.flatMap { sessions[$0.thread]?.actionTitles } ?? [:]
        let titles = remoteTitles.merging(local) { _, new in new }
        let extra = Set(titles.keys).union([selectedID]).subtracting(["term-1"]).sorted()
        let ids = ["term-1"] + extra
        let names = ["Shell"] + extra.enumerated().map { index, id in
            titles[id].flatMap { $0.isEmpty ? nil : $0 } ?? "Terminal \(index + 2)"
        }
        if picker.itemArray.compactMap({ $0.representedObject as? String }) != ids || picker.itemTitles != names {
            picker.removeAllItems()
            for (id, title) in zip(ids, names) {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.representedObject = id
                picker.menu?.addItem(item)
            }
        }
        picker.selectItem(at: ids.firstIndex(of: selectedID) ?? 0)
        picker.isHidden = scope == nil || extra.isEmpty
        status.isHidden = !picker.isHidden && status.stringValue == "Terminal"
    }

    private func setStatus(_ text: String) {
        status.stringValue = text
        status.isHidden = !picker.isHidden && text == "Terminal"
    }

    @objc private func chooseSession() {
        guard let scope, scope == currentScope, let id = picker.selectedItem?.representedObject as? String else { return }
        sessions[scope.thread, default: Sessions()].selected = id
        sync()
        focus()
    }

    private func consume(_ frames: [Wire]) {
        for frame in frames {
            switch frame["type"].string {
            case "snapshot", "restarted":
                terminal.selectNone()
                terminal.getTerminal().resetToInitialState()
                let snapshot = frame["snapshot"]
                let shellRunning = snapshot["status"].string == "running"
                if let history = snapshot["history"].string { terminal.feed(text: history) }
                setRunning(shellRunning)
                setStatus(running ? "Terminal" : "Terminal · Shell exited")
                scheduleResize()
            case "output":
                if let chunk = frame["data"].string { terminal.feed(text: chunk) }
            case "cleared":
                terminal.selectNone()
                terminal.getTerminal().resetToInitialState()
                terminal.needsDisplay = true
            case "exited", "closed", "error":
                setRunning(false)
                setStatus("Terminal · Shell exited")
                if let message = frame["message"].string { terminal.feed(text: "\r\n\(message)\r\n") }
            default: break
            }
        }
    }

    private func selectedOutput() -> SelectedOutput? {
        guard let scope, scope == currentScope, let terminalID = attachedID, let selection = terminal.selection,
              selection.active, selection.hasSelectionRange else { return nil }
        let core = terminal.getTerminal()
        guard let captured = TerminalSelection.capture(from: selection.start, to: selection.end, columns: core.cols,
                                                       read: { core.getText(start: $0, end: $1) }) else { return nil }
        let target = TerminalContextTarget(environmentID: scope.thread.environmentID, threadID: scope.thread.threadID,
                                           connection: scope.connection)
        return SelectedOutput(target: target, terminalID: terminalID, selection: captured)
    }

    private func terminalMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let output = selectedOutput()
        let add = menuItem("Add to Chat", target: self, action: #selector(addToChat(_:)))
        add.representedObject = output
        add.isEnabled = output != nil && onAddContext != nil && workspace.can("orchestration:operate") &&
            workspace.selectedThread?.archived == false
        let copy = menuItem("Copy", target: terminal, action: #selector(SwiftTerm.TerminalView.copy(_:)))
        copy.isEnabled = terminal.selectionActive && terminal.selection.hasSelectionRange
        let paste = menuItem("Paste", target: terminal, action: #selector(SwiftTerm.TerminalView.paste(_:)))
        paste.isEnabled = running && workspace.can("terminal:operate") && NSPasteboard.general.availableType(from: [.string]) != nil
        let selectAll = menuItem("Select All", target: terminal, action: #selector(NSResponder.selectAll(_:)))
        let latest = menuItem("Jump to Latest", target: self, action: #selector(jumpToLatest))
        for item in [add, copy, paste, .separator(), selectAll, latest] { menu.addItem(item) }
        return menu
    }

    @objc private func addToChat(_ item: NSMenuItem) {
        guard let original = item.representedObject as? SelectedOutput, let current = selectedOutput(),
              current.target == original.target, current.terminalID == original.terminalID,
              current.selection.text == original.selection.text, let onAddContext else { return }
        let name = picker.isHidden ? "Terminal" : picker.titleOfSelectedItem ?? "Terminal"
        guard let context = TerminalContext(terminalID: current.terminalID, terminalLabel: name, selection: current.selection) else { return }
        do {
            try onAddContext(context, current.target)
            terminal.selectNone()
        } catch { onError?(error.localizedDescription) }
    }

    @objc private func jumpToLatest() { terminal.scroll(toPosition: 1) }

    private func setRunning(_ running: Bool) {
        self.running = running
        interrupt.isEnabled = running
        closeShell.isEnabled = running
        if !running {
            inputTask?.cancel()
            inputTask = nil
            resizeTask?.cancel()
            pendingInput = ""
        }
    }

    private func enqueue(_ data: String) {
        guard running, let scope, !data.isEmpty else { return }
        pendingInput += data
        guard inputTask == nil else { return }
        inputTask = Task {
            while !Task.isCancelled, self.scope == scope, workspace.connectionID == scope.connection, !pendingInput.isEmpty {
                let prefix = pendingInput.unicodeScalars.prefix(8_192)
                let next = String(prefix)
                pendingInput = String(pendingInput[prefix.endIndex...])
                let payload = arguments.merging(["data": .string(next)]) { _, new in new }
                do { _ = try await workspace.request("terminal.write", payload) }
                catch {
                    if !Task.isCancelled { onError?(error.localizedDescription); pendingInput = "" }
                    break
                }
            }
            if !Task.isCancelled { inputTask = nil }
        }
    }

    private func scheduleResize() {
        resizeTask?.cancel()
        guard running, let scope else { return }
        let payload = arguments.merging(["cols": .int(dimensions.cols), "rows": .int(dimensions.rows)]) { _, new in new }
        resizeTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(80))
                try Task.checkCancellation()
                guard self.scope == scope, workspace.connectionID == scope.connection else { return }
                _ = try await workspace.request("terminal.resize", payload)
            } catch {
                if !Task.isCancelled { onError?(error.localizedDescription) }
            }
        }
    }

    private func endShell() {
        guard let scope else { return }
        let payload = arguments
        Task {
            guard workspace.connectionID == scope.connection else { return }
            do { _ = try await workspace.request("terminal.close", payload) }
            catch { onError?(error.localizedDescription) }
        }
    }

    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        dimensions = (max(1, min(1_000, newCols)), max(1, min(500, newRows)))
        scheduleResize()
    }

    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) { enqueue(String(decoding: data, as: UTF8.self)) }
    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) { status.toolTip = title }
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    func bell(source: SwiftTerm.TerminalView) {}

    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link), ["https", "http"].contains(url.scheme) { NSWorkspace.shared.open(url) }
    }

    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {}
}
