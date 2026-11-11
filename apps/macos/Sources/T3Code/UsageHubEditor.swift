import AppKit

@MainActor
final class UsageHubEditor: NSWindowController {
    private enum KeyMode: Equatable {
        case saved, value, reference(String)
    }

    private let workspace: Workspace
    private let original: UsageHubConfiguration?
    private let id: String
    private let connection: UUID
    private let address = NSTextField()
    private let name = NSTextField()
    private let credential = NSPopUpButton()
    private let password = NSSecureTextField()
    private let reference = NSTextField()
    private let savedKey = label("The environment will keep the saved key.", size: 11.5, color: WorkspaceStyle.muted)
    private let enabled = NSButton(checkboxWithTitle: "Read quota from this hub", target: nil, action: nil)
    private let notice = NSTextField(wrappingLabelWithString: "")
    private lazy var save = ActionButton(original == nil ? "Add Hub" : "Save", style: .subtle) { [weak self] in self?.submit() }
    private lazy var cancel = ActionButton("Cancel", style: .subtle) { [weak self] in self?.closeSheet() }
    private var task: Task<Void, Never>?
    private var invalidated = false
    var onClose: (() -> Void)?

    init(workspace: Workspace, original: UsageHubConfiguration?, connection: UUID) {
        self.workspace = workspace
        self.original = original
        self.connection = connection
        id = original?.id ?? "cliproxy-" + UUID().uuidString.lowercased()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 495, height: 310),
                              styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = original == nil ? "Add CLIProxyAPI Hub" : "Edit CLIProxyAPI Hub"
        window.isReleasedWhenClosed = false
        build(window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present(in parent: NSWindow) {
        guard let window, parent.attachedSheet == nil else { return }
        parent.beginSheet(window) { [weak self] _ in
            self?.password.stringValue = ""
            self?.onClose?()
        }
        window.makeFirstResponder(address)
    }

    func syncConnection() {
        guard !invalidated, workspace.connectionID != connection || !workspace.canEditUsageHubs else { return }
        invalidated = true
        password.stringValue = ""
        reference.stringValue = ""
        setEditing(false)
        cancel.isEnabled = task == nil
        showNotice("The environment connection changed. Open the hub settings again.")
    }

    private var mode: KeyMode {
        if let provider = credential.selectedItem?.representedObject as? String { return .reference(provider) }
        return credential.selectedItem?.tag == 1 ? .saved : .value
    }

    private func build(_ window: NSWindow) {
        address.placeholderString = "https://hub.example.com:8318"
        address.stringValue = original?.address?.value ?? ""
        name.placeholderString = "Optional"
        name.stringValue = original?.label ?? ""
        enabled.state = original?.enabled != false ? .on : .off
        password.placeholderString = "Management key"
        password.setAccessibilityLabel("Management Key")
        reference.placeholderString = "Secret reference"
        reference.setAccessibilityLabel("Secret Reference")
        credential.setAccessibilityLabel("Management Key Source")
        credential.target = self
        credential.action = #selector(changeKeyMode)
        if original?.hasKey == true {
            let title = original?.reference.flatMap { saved in
                workspace.settingsSecretProviders.first { $0.id == saved.provider }?.label
            }.map { "Keep \($0) Reference" } ?? "Keep Saved Key"
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.tag = 1
            credential.menu?.addItem(item)
        }
        credential.addItem(withTitle: "Enter Key")
        for source in workspace.settingsSecretProviders {
            let item = NSMenuItem(title: source.label, action: nil, keyEquivalent: "")
            item.representedObject = source.id
            credential.menu?.addItem(item)
        }
        credential.selectItem(at: 0)
        credential.isHidden = credential.numberOfItems <= 1
        notice.font = .systemFont(ofSize: 11.5)
        notice.textColor = WorkspaceStyle.negative
        notice.maximumNumberOfLines = 4
        notice.isHidden = true
        save.keyEquivalent = "\r"
        cancel.keyEquivalent = "\u{1b}"

        let heading = label(window.title, size: 17, weight: .semibold, color: WorkspaceStyle.ink)
        let environment = label(workspace.environment?.name ?? "Environment", size: 12, color: WorkspaceStyle.muted)
        let secret = column([
            row([label("Management key", size: 11.5, weight: .medium), NSView(), credential]),
            password, reference, savedKey,
        ], spacing: 5, alignment: .width)
        let body = column([
            column([heading, environment], spacing: 3),
            field("Hub URL", address), secret, field("Label", name), row([enabled, NSView()]), notice,
            row([NSView(), cancel, save]),
        ], spacing: 12, alignment: .width)
        let content = Surface(WorkspaceStyle.navigation)
        window.contentView = content
        fill(body, in: content, inset: 20)
        changeKeyMode()
    }

    private func field(_ title: String, _ input: NSTextField) -> NSView {
        input.setAccessibilityLabel(title)
        return column([label(title, size: 11.5, weight: .medium), input], spacing: 4, alignment: .width)
    }

    @objc private func changeKeyMode() {
        let mode = mode
        password.isHidden = mode != .value
        savedKey.isHidden = mode != .saved
        if case .reference(let provider) = mode {
            reference.stringValue = original?.reference?.provider == provider ? original?.reference?.reference ?? "" : ""
            reference.isHidden = false
        } else { reference.isHidden = true }
        showNotice("")
    }

    private func submit() {
        guard task == nil, !invalidated else { return }
        let key: UsageHubEdit.Key
        switch mode {
        case .saved: key = .keep
        case .value: key = .value(password.stringValue)
        case .reference(let provider):
            guard let value = SettingsSecretReference(provider: provider, reference: reference.stringValue) else {
                showNotice("Enter a valid secret reference.")
                return
            }
            key = .reference(value)
        }
        let edit = UsageHubEdit(url: address.stringValue, label: name.stringValue, enabled: enabled.state == .on, key: key)
        showNotice("")
        setEditing(false)
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                task = nil
                setEditing(!invalidated)
                cancel.isEnabled = true
            }
            do {
                try await workspace.saveUsageHub(id: id, original: original, edit: edit, connection: connection)
                closeSheet(saved: true)
            } catch {
                if !invalidated { showNotice(error.localizedDescription) }
            }
        }
    }

    private func showNotice(_ message: String) {
        notice.stringValue = message
        notice.isHidden = message.isEmpty
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 495, height: content.fittingSize.height))
    }

    private func setEditing(_ editing: Bool) {
        let controls: [NSControl] = [address, name, credential, password, reference, enabled, save, cancel]
        for control in controls { control.isEnabled = editing }
    }

    private func closeSheet(saved: Bool = false) {
        guard saved || task == nil, let window, let parent = window.sheetParent else { return }
        password.stringValue = ""
        parent.endSheet(window)
    }
}
