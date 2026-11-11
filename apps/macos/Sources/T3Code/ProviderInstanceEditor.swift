import AppKit

@MainActor
final class ProviderInstanceEditor: NSWindowController {
    enum Destination {
        case create(ProviderCreationKind, id: String, connection: UUID)
        case edit(ProviderSetupTarget, driver: String, managed: Bool)

        var instanceID: String {
            switch self {
            case .create(_, let id, _): id
            case .edit(let target, _, _): target.instanceID
            }
        }

        var driver: String {
            switch self {
            case .create(let kind, _, _): kind.driver
            case .edit(_, let driver, _): driver
            }
        }

        var allowsCLIPaths: Bool {
            switch self {
            case .create(let kind, _, _): kind != .managedCodex
            case .edit(_, let driver, let managed): !managed && ComposerProvider(rawValue: driver) != nil
            }
        }

        var title: String {
            switch self {
            case .create(let kind, _, _): "Add " + kind.title
            case .edit: "Configure Provider"
            }
        }
    }

    private let workspace: Workspace
    private let destination: Destination
    private let original: ProviderConfigurationFields
    private let name = NSTextField()
    private let binary = NSTextField()
    private let home = NSTextField()
    private let shadowHome = NSTextField()
    private let launchArgs = NSTextField()
    private let enabled = NSButton(checkboxWithTitle: "Enable provider", target: nil, action: nil)
    private let failure = NSTextField(wrappingLabelWithString: "")
    private lazy var save = ActionButton("Save", style: .subtle) { [weak self] in self?.submit() }
    private lazy var cancel = ActionButton("Cancel", style: .subtle) { [weak self] in self?.closeSheet() }
    private var editableFields: [NSTextField] = []
    private var task: Task<Void, Never>?
    var onClose: (() -> Void)?
    var onSaved: ((String) -> Void)?

    init(workspace: Workspace, destination: Destination, fields: ProviderConfigurationFields) {
        self.workspace = workspace
        self.destination = destination
        original = fields
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 505, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = destination.title
        window.isReleasedWhenClosed = false
        build(window, fields)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present(in parent: NSWindow) {
        guard let window, parent.attachedSheet == nil else { return }
        parent.beginSheet(window) { [weak self] _ in self?.onClose?() }
        window.makeFirstResponder(name)
    }

    private func build(_ window: NSWindow, _ fields: ProviderConfigurationFields) {
        name.stringValue = fields.name
        binary.stringValue = fields.binaryPath
        binary.placeholderString = destination.driver == ComposerProvider.codex.rawValue ? "codex" : "claude"
        home.stringValue = fields.homePath
        shadowHome.stringValue = fields.shadowHomePath
        launchArgs.stringValue = fields.launchArgs
        enabled.state = fields.enabled ? .on : .off
        enabled.contentTintColor = WorkspaceStyle.secondary
        failure.textColor = WorkspaceStyle.negative
        failure.font = .systemFont(ofSize: 11.5)
        failure.maximumNumberOfLines = 3
        failure.isHidden = true
        save.keyEquivalent = "\r"
        cancel.keyEquivalent = "\u{1b}"

        var fieldsToShow: [(String, NSTextField)] = [("Name", name)]
        if destination.allowsCLIPaths {
            fieldsToShow += [("Executable", binary), ("Configuration directory", home)]
            if destination.driver == ComposerProvider.codex.rawValue { fieldsToShow.append(("Shadow directory", shadowHome)) }
            fieldsToShow.append(("Launch arguments", launchArgs))
        }
        let hostName = workspace.environment?.name ?? "this environment"
        let title = label(destination.title, size: 17, weight: .semibold, color: WorkspaceStyle.ink)
        let location = label("Environment · " + hostName, size: 12, color: WorkspaceStyle.muted)
        let form = column(fieldsToShow.map { caption, input in
            input.setAccessibilityLabel(caption)
            input.font = .systemFont(ofSize: 12.5)
            return column([label(caption, size: 11.5, weight: .medium, color: WorkspaceStyle.secondary), input],
                          spacing: 4, alignment: .width)
        }, spacing: 11, alignment: .width)
        editableFields = fieldsToShow.map(\.1)
        let body = column([column([title, location], spacing: 3, alignment: .width), form, row([enabled, NSView()]),
                           failure, row([NSView(), cancel, save])], spacing: 15, alignment: .width)
        let content = Surface(WorkspaceStyle.navigation)
        window.contentView = content
        fill(body, in: content, inset: 20)
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 505, height: body.fittingSize.height + 40))
    }

    private func submit() {
        guard task == nil else { return }
        guard !name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showFailure("Enter a provider name.")
            return
        }
        var next = original
        next.name = name.stringValue
        next.enabled = enabled.state == .on
        next.binaryPath = binary.stringValue
        next.homePath = home.stringValue
        next.shadowHomePath = shadowHome.stringValue
        next.launchArgs = launchArgs.stringValue
        showFailure("")
        setEditing(false)
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil; setEditing(true) }
            do {
                switch destination {
                case .create(let kind, let id, let connection):
                    try await workspace.createProvider(kind, id: id, fields: next, connection: connection)
                case .edit(let target, _, _):
                    try await workspace.configureProvider(target, edit: .init(before: original, after: next))
                }
                onSaved?(destination.instanceID)
                closeSheet(saved: true)
            } catch {
                showFailure(error.localizedDescription)
            }
        }
    }

    private func showFailure(_ text: String) {
        failure.stringValue = text
        failure.isHidden = text.isEmpty
        if let window, let content = window.contentView {
            content.layoutSubtreeIfNeeded()
            window.setContentSize(NSSize(width: 505, height: content.fittingSize.height))
        }
    }

    private func setEditing(_ editing: Bool) {
        for field in editableFields { field.isEnabled = editing }
        enabled.isEnabled = editing
        cancel.isEnabled = editing
        save.isEnabled = editing
    }

    private func closeSheet(saved: Bool = false) {
        guard (saved || task == nil), let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }
}
