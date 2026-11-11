import AppKit

@MainActor
final class DeviceHostEditor: NSWindowController, NSTextFieldDelegate {
    private enum CredentialMode: Equatable {
        case keep, environment, value, reference(String)
    }

    private struct ExpoProject {
        let id: String
        let name: String
    }

    private let workspace: Workspace
    private let kind: DeviceHostKind
    private let original: DeviceHostConfiguration?
    private let connection: UUID
    private let id: String
    private let name = NSTextField()
    private let target = NSTextField()
    private let identityFile = NSTextField()
    private let port = NSTextField()
    private let project = NSTextField()
    private let gateway = NSTextField()
    private let sessionMinutes = NSTextField()
    private let idleMinutes = NSTextField()
    private let concurrentSessions = NSTextField()
    private let leases = NSTextField()
    private let leaseMinutes = NSTextField()
    private let credentialSource = NSPopUpButton()
    private let token = NSSecureTextField()
    private let reference = NSTextField()
    private let credentialHint = label(size: 11.5, color: WorkspaceStyle.muted)
    private let notice = NSTextField(wrappingLabelWithString: "")
    private lazy var save = ActionButton(original == nil ? "Add Host" : "Save", style: .subtle) { [weak self] in self?.submit() }
    private lazy var cancel = ActionButton("Cancel", style: .subtle) { [weak self] in self?.closeSheet() }
    private lazy var check = ActionButton(kind == .ssh ? "Test Connection" : "Check Account", style: .subtle) {
        [weak self] in self?.checkConnection()
    }
    private lazy var chooseProject = ActionButton("Choose…", style: .subtle) { [weak self] in self?.showProjects() }
    private var inputs: [NSControl] = []
    private var apps: [ExpoProject] = []
    private var task: Task<Void, Never>?
    private var invalidated = false
    var onClose: (() -> Void)?

    init(workspace: Workspace, kind: DeviceHostKind, original: DeviceHostConfiguration?, connection: UUID) {
        self.workspace = workspace
        self.kind = kind
        self.original = original
        self.connection = connection
        id = original?.id ?? "\(kind.rawValue)-\(UUID().uuidString.lowercased())"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: 395),
                              styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = original == nil ? "Add \(kind.title) Host" : "Edit \(kind.title) Host"
        window.isReleasedWhenClosed = false
        build(window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present(in parent: NSWindow) {
        guard let window, parent.attachedSheet == nil else { return }
        parent.beginSheet(window) { [weak self] _ in
            self?.clearToken()
            self?.onClose?()
        }
        window.makeFirstResponder(name)
    }

    func syncConnection() {
        guard !invalidated, !workspace.canEditDeviceHosts(connection, kind: kind) else { return }
        invalidated = true
        task?.cancel()
        clearToken()
        updateControls()
        show("The environment connection or access changed. Reopen the host settings.", error: true)
    }

    private func build(_ window: NSWindow) {
        name.stringValue = original?.name ?? (kind == .ssh ? "" : kind.title)
        name.placeholderString = kind == .ssh ? "Mac mini" : kind.title
        notice.font = .systemFont(ofSize: 11.5)
        notice.maximumNumberOfLines = 4
        notice.isHidden = true
        save.keyEquivalent = "\r"
        cancel.keyEquivalent = "\u{1b}"
        if kind == .simlock {
            check.title = "Check Gateway"
            check.setAccessibilityLabel("Check Gateway")
        }

        let heading = column([
            label(window.title, size: 17, weight: .semibold, color: WorkspaceStyle.ink),
            label(workspace.environment?.name ?? "Environment", size: 12, color: WorkspaceStyle.muted),
        ], spacing: 3)
        let fields = [heading, field("Name", name)] + endpointFields() + [notice, row([check, NSView(), cancel, save])]
        let content = Surface(WorkspaceStyle.navigation)
        window.contentView = content
        fill(column(fields, spacing: 12, alignment: .width), in: content, inset: 20)
        updateCredentialFields()
        updateControls()
        resize()
    }

    private func endpointFields() -> [NSView] {
        switch kind {
        case .ssh:
            target.placeholderString = "user@host or SSH alias"
            identityFile.placeholderString = "SSH configuration default"
            port.placeholderString = "Default"
            target.stringValue = original?.fields["target"]?.string ?? ""
            identityFile.stringValue = original?.fields["identityFile"]?.string ?? ""
            port.stringValue = original?.fields["port"]?.int.map(String.init) ?? ""
            let portField = field("Port", port)
            portField.widthAnchor.constraint(equalToConstant: 100).isActive = true
            return [
                field("SSH Target", target),
                row([field("Identity File on Environment", identityFile), portField], spacing: 12),
            ]
        case .eas:
            project.placeholderString = "Use the conversation’s EAS project"
            project.stringValue = original?.fields["appId"]?.string ?? ""
            let limits = row([
                limit("Session (min)", sessionMinutes, key: "maxSessionMinutes", fallback: 30, range: "1–115"),
                limit("Idle (min)", idleMinutes, key: "idleMinutes", fallback: 10, range: "1–60"),
                limit("Concurrent Sessions", concurrentSessions, key: "maxConcurrentSessions", fallback: 2, range: "1–20"),
            ], spacing: 12)
            limits.distribution = .fillEqually
            return [
                credentialFields("Expo Access Token"),
                field("Fallback EAS Project ID", project, trailing: chooseProject),
                limits,
            ]
        case .simlock:
            gateway.placeholderString = "https://gateway.example.test:4700"
            gateway.stringValue = original?.fields["gatewayUrl"]?.string ?? ""
            let limits = row([
                limit("Concurrent Leases", leases, key: "maxLeases", fallback: 2, range: "1–20"),
                limit("Lease (min)", leaseMinutes, key: "maxLeaseMinutes", fallback: 60, range: "5–240"),
            ], spacing: 12)
            limits.distribution = .fillEqually
            return [
                field("Gateway URL", gateway),
                credentialFields("Agent Token"),
                limits,
            ]
        case .local: return []
        }
    }

    private func field(_ title: String, _ input: NSTextField, trailing: NSView? = nil) -> NSView {
        input.setAccessibilityLabel(title)
        input.delegate = self
        input.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        inputs.append(input)
        let control = trailing.map { row([input, $0], spacing: 6) } ?? input
        return column([label(title, size: 11.5, weight: .medium), control], spacing: 4, alignment: .width)
    }

    private func limit(_ title: String, _ input: NSTextField, key: String, fallback: Int, range: String) -> NSView {
        input.stringValue = String(original?.fields[key]?.int ?? fallback)
        input.toolTip = range
        input.setAccessibilityHelp("Range \(range)")
        return field(title, input)
    }

    private func credentialFields(_ title: String) -> NSView {
        credentialSource.setAccessibilityLabel("\(title) Source")
        credentialSource.target = self
        credentialSource.action = #selector(changeCredential)
        if original?.hasToken == true {
            let provider = original?.reference.flatMap { saved in
                workspace.settingsSecretProviders.first { $0.id == saved.provider }?.label
            }
            credentialSource.addItem(withTitle: provider.map { "Saved · \($0)" } ?? "Saved Token")
            credentialSource.lastItem?.tag = 1
        }
        credentialSource.addItem(withTitle: "Environment Credentials")
        credentialSource.addItem(withTitle: "Enter Token")
        credentialSource.lastItem?.tag = 2
        for provider in workspace.settingsSecretProviders {
            let item = NSMenuItem(title: provider.label, action: nil, keyEquivalent: "")
            item.representedObject = provider.id
            credentialSource.menu?.addItem(item)
        }
        credentialSource.selectItem(at: 0)
        token.setAccessibilityLabel(title)
        token.placeholderString = title
        token.delegate = self
        reference.setAccessibilityLabel("Secret Reference")
        reference.placeholderString = "Secret reference"
        reference.delegate = self
        inputs += [credentialSource, token, reference]
        return column([
            row([label(title, size: 11.5, weight: .medium), NSView(), credentialSource]),
            token, reference, credentialHint,
        ], spacing: 5, alignment: .width)
    }

    private var mode: CredentialMode {
        if let provider = credentialSource.selectedItem?.representedObject as? String { return .reference(provider) }
        switch credentialSource.selectedItem?.tag {
        case 1: return .keep
        case 2: return .value
        default: return .environment
        }
    }

    @objc private func changeCredential() {
        clearToken()
        if case .reference(let provider) = mode {
            reference.stringValue = original?.reference?.provider == provider ? original?.reference?.reference ?? "" : ""
        } else { reference.stringValue = "" }
        updateCredentialFields()
        invalidateCheck()
    }

    private func updateCredentialFields() {
        token.isHidden = mode != .value
        if case .reference = mode { reference.isHidden = false } else { reference.isHidden = true }
        credentialHint.isHidden = mode != .environment
        credentialHint.stringValue = kind == .eas ? "Uses EXPO_TOKEN or eas login on the environment." :
            "Uses the environment’s agent token for this gateway."
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let input = notification.object as? NSTextField else { return }
        if [target, identityFile, port, gateway, token, reference].contains(where: { $0 === input }) {
            invalidateCheck()
        }
    }

    private func invalidateCheck() {
        apps = []
        updateControls()
        show("")
    }

    private func makeDraft() throws -> DeviceHostDraft {
        let credential: DeviceHostDraft.Credential
        switch mode {
        case .keep: credential = .keep
        case .environment: credential = .environment
        case .value: credential = .value(token.stringValue)
        case .reference(let provider):
            guard let value = SettingsSecretReference(provider: provider, reference: reference.stringValue) else {
                throw ClientError.message("Enter a valid secret reference.")
            }
            credential = .reference(value)
        }
        let endpoint: DeviceHostDraft.Endpoint = switch kind {
        case .ssh, .local: .ssh(target: target.stringValue, identityFile: identityFile.stringValue, port: port.stringValue)
        case .eas: .eas(project: project.stringValue, session: sessionMinutes.stringValue, idle: idleMinutes.stringValue,
                        concurrent: concurrentSessions.stringValue)
        case .simlock: .simlock(gateway: gateway.stringValue, leases: leases.stringValue, duration: leaseMinutes.stringValue)
        }
        return .init(name: name.stringValue, endpoint: endpoint, credential: credential)
    }

    private func submit() {
        run("Saving…") { draft in
            try await self.workspace.saveDeviceHost(draft, id: self.id, original: self.original, connection: self.connection)
            if !self.invalidated { self.closeSheet(saved: true) }
        }
    }

    private func checkConnection() {
        run("Checking on \(workspace.environment?.name ?? "the environment")…") { draft in
            let result = try await self.workspace.checkDeviceHost(draft, id: self.id, original: self.original, connection: self.connection)
            if !self.invalidated { try self.showCheck(result) }
        }
    }

    private func run(_ message: String, _ action: @escaping @MainActor (DeviceHostDraft) async throws -> Void) {
        guard task == nil, !invalidated else { return }
        window?.makeFirstResponder(nil)
        let draft: DeviceHostDraft
        do { draft = try makeDraft() }
        catch { show(error.localizedDescription, error: true); return }
        show(message)
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil; updateControls() }
            do { try await action(draft) }
            catch { if !invalidated { show(error.localizedDescription, error: true) } }
        }
        updateControls()
    }

    private func showCheck(_ result: Wire) throws {
        switch kind {
        case .ssh:
            guard let host = DeviceHost(result) else { throw ClientError.invalidResponse }
            let available = host.platforms.filter(\.available).map { $0.platform.title }
            let unavailable = host.platforms.filter { !$0.available }.compactMap(\.reason)
            let result = available.isEmpty ? "SSH connected." : "SSH connected · \(available.joined(separator: ", ")) available"
            show(([result] + unavailable).joined(separator: "\n"))
        case .eas:
            let account = try result.requireString("signedInAs")
            apps = result["apps"].array.compactMap { value in
                guard let id = value["id"].string, let name = value["fullName"].string else { return nil }
                return .init(id: id, name: name)
            }
            let source = switch result["credentialSource"].string {
            case "settings": "Access token"
            case "env": "EXPO_TOKEN"
            case "eas-login": "eas login"
            default: "Expo"
            }
            show("Signed in as \(account) · \(source)")
        case .simlock:
            let identity = try result.requireString("signedInAs")
            if gateway.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                gateway.stringValue = try result.requireString("gatewayUrl")
            }
            show("Connected as \(identity)")
        case .local: break
        }
    }

    private func showProjects() {
        guard !apps.isEmpty, task == nil else { return }
        let menu = NSMenu()
        let fromThread = menuItem("Use the Conversation’s Project", target: self, action: #selector(selectProject(_:)))
        fromThread.representedObject = ""
        fromThread.state = project.stringValue.isEmpty ? .on : .off
        menu.addItem(fromThread)
        menu.addItem(.separator())
        for app in apps {
            let item = menuItem(app.name, target: self, action: #selector(selectProject(_:)))
            item.representedObject = app.id
            item.state = project.stringValue == app.id ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: chooseProject.bounds.height), in: chooseProject)
    }

    @objc private func selectProject(_ item: NSMenuItem) {
        if let id = item.representedObject as? String { project.stringValue = id }
    }

    private func show(_ message: String, error: Bool = false) {
        notice.stringValue = message
        notice.textColor = error ? WorkspaceStyle.negative : WorkspaceStyle.secondary
        notice.isHidden = message.isEmpty
        resize()
    }

    private func resize() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 510, height: content.fittingSize.height))
    }

    private func updateControls() {
        let editing = task == nil && !invalidated
        for control in inputs + [check, save] { control.isEnabled = editing }
        chooseProject.isEnabled = editing && !apps.isEmpty
        cancel.isEnabled = task == nil
    }

    private func clearToken() {
        if token.currentEditor() != nil { window?.makeFirstResponder(nil) }
        token.stringValue = ""
    }

    private func closeSheet(saved: Bool = false) {
        guard saved || task == nil, let window, let parent = window.sheetParent else { return }
        clearToken()
        parent.endSheet(window)
    }
}
