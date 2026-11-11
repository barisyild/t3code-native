import AppKit

@MainActor
final class VoiceCloudEditor: NSWindowController, NSTextFieldDelegate {
    private enum KeySource { case saved, value, reference(String) }

    private let workspace: Workspace
    private let target: VoiceTarget
    private let provider: VoiceCloudProvider
    private let model = NSPopUpButton()
    private let keySource = NSPopUpButton()
    private let key = NSSecureTextField()
    private let reference = NSTextField()
    private let state = NSTextField(wrappingLabelWithString: "")
    private let issue = NSTextField(wrappingLabelWithString: "")
    private let disclosure = NSTextField(wrappingLabelWithString: "")
    private lazy var modelRow = row([label("Model", size: 12), NSView(), model])
    private lazy var keyRow = row([label("API key source", size: 12), NSView(), keySource])
    private lazy var retry = ActionButton("Retry", style: .subtle) { [weak self] in self?.load() }
    private lazy var remove = ActionButton("Remove Key…", style: .subtle) { [weak self] in self?.removeKey() }
    private lazy var closeButton = ActionButton("Cancel", style: .subtle) { [weak self] in self?.finish() }
    private lazy var apply = ActionButton("Use for Dictation") { [weak self] in self?.submit() }
    private var task: Task<Void, Never>?
    private var configured: Bool?
    private var models: [VoiceCloudModel] = []
    private var loaded = false
    private var confirmsRemoval = false
    var onClose: (() -> Void)?

    init(workspace: Workspace, target: VoiceTarget, provider: VoiceCloudProvider) {
        self.workspace = workspace
        self.target = target
        self.provider = provider
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 495, height: 340),
                              styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "\(provider.title) Dictation"
        window.isReleasedWhenClosed = false
        let surface = Surface(WorkspaceStyle.navigation)
        window.contentView = surface
        let heading = label(window.title, size: 16, weight: .semibold, color: WorkspaceStyle.ink)
        for field in [disclosure, state, issue] {
            field.font = .systemFont(ofSize: 12)
            field.maximumNumberOfLines = 3
            field.setContentHuggingPriority(.required, for: .vertical)
        }
        disclosure.textColor = WorkspaceStyle.secondary
        state.textColor = WorkspaceStyle.muted
        issue.textColor = WorkspaceStyle.negative
        model.setAccessibilityLabel("OpenRouter Transcription Model")
        model.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        model.target = self
        model.action = #selector(changed)
        keySource.setAccessibilityLabel("API Key Source")
        keySource.target = self
        keySource.action = #selector(changeSource)
        key.placeholderString = "Enter API key"
        key.setAccessibilityLabel("\(provider.name) API Key")
        reference.placeholderString = "Secret reference"
        reference.setAccessibilityLabel("\(provider.name) Key Reference")
        for field in [key, reference] {
            field.target = self
            field.action = #selector(submit)
            field.delegate = self
        }
        closeButton.keyEquivalent = "\u{1b}"
        apply.keyEquivalent = "\r"
        let actions = row([remove, retry, NSView(), closeButton, apply], spacing: 8)
        fill(column([heading, disclosure, state, modelRow, keyRow, key, reference, issue, NSView(), actions],
                    spacing: 9, alignment: .width), in: surface, inset: 18)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present(in parent: NSWindow) {
        guard let window, parent.attachedSheet == nil else { return }
        parent.beginSheet(window) { [weak self] _ in
            self?.task?.cancel()
            self?.key.stringValue = ""
            self?.reference.stringValue = ""
            self?.onClose?()
        }
        load()
    }

    func sync() {
        guard workspace.voiceTarget == target, workspace.supportsCloudVoiceTranscription else { finish(); return }
        render()
    }

    private var canManage: Bool { workspace.can("settings:write") }
    private var source: KeySource {
        if let id = keySource.selectedItem?.representedObject as? String { return .reference(id) }
        return keySource.selectedItem?.tag == 1 ? .saved : .value
    }

    private var candidate: VoiceCloudDestination? {
        VoiceCloudDestination(provider: provider, model: model.selectedItem?.representedObject as? String)
    }

    private var replacement: Wire? {
        switch source {
        case .saved: nil
        case .value: VoiceCloudProvider.apiKey(key.currentEditor()?.string ?? key.stringValue)
        case .reference(let id): SettingsSecretReference(provider: id, reference: reference.currentEditor()?.string ?? reference.stringValue)?.wire
        }
    }

    private func load() {
        guard task == nil else { return }
        issue.stringValue = ""
        task = Task { [weak self, workspace, target, provider] in
            guard let self else { return }
            defer { task = nil; sync() }
            do {
                let api = try workspace.voiceAPI(target)
                async let keys = api.cloudVoiceKeys()
                if provider == .openrouter { models = try await api.cloudVoiceModels() }
                let presence = try await keys
                guard !Task.isCancelled, workspace.voiceTarget == target else { return }
                configured = presence[provider.rawValue].bool
                loaded = true
                populate()
            } catch {
                if !Task.isCancelled { issue.stringValue = error.localizedDescription }
            }
        }
        render()
    }

    private func populate() {
        model.removeAllItems()
        model.addItem(withTitle: "Choose model…")
        for entry in models {
            let item = NSMenuItem(title: entry.name, action: nil, keyEquivalent: "")
            item.toolTip = entry.id
            item.representedObject = entry.id
            model.menu?.addItem(item)
        }
        if let current = workspace.voicePreferences.cloud, current.provider == provider,
           let index = model.itemArray.firstIndex(where: { $0.representedObject as? String == current.model && current.model != nil }) {
            model.selectItem(at: index)
        }
        keySource.removeAllItems()
        if configured == true {
            keySource.addItem(withTitle: "Use Saved Key")
            keySource.lastItem?.tag = 1
        }
        if canManage {
            keySource.addItem(withTitle: configured == true ? "Replace API Key" : "Enter API Key")
            for source in workspace.settingsSecretProviders {
                let item = NSMenuItem(title: source.label, action: nil, keyEquivalent: "")
                item.representedObject = source.id
                keySource.menu?.addItem(item)
            }
        }
        if keySource.numberOfItems > 0 { keySource.selectItem(at: 0) }
    }

    private func render() {
        let busy = task != nil
        let environment = workspace.environment?.name ?? "The environment"
        disclosure.stringValue = confirmsRemoval ? "Removing this key turns off \(provider.name) dictation for everyone using \(environment)." :
            provider.disclosure(environment: environment)
        state.stringValue = {
            if busy { return loaded ? "Updating voice settings…" : "Checking voice settings…" }
            if loaded && configured == nil { return "This environment needs an update to use \(provider.name) dictation." }
            if configured == true { return "\(provider.name) key saved on \(environment)" }
            if loaded && !canManage { return "An administrator on this environment can add the API key." }
            if loaded { return "Add an API key to use \(provider.name)." }
            return ""
        }()
        state.isHidden = state.stringValue.isEmpty
        modelRow.isHidden = confirmsRemoval || provider != .openrouter || !loaded
        model.isEnabled = !busy && !models.isEmpty
        keyRow.isHidden = confirmsRemoval || keySource.numberOfItems <= 1 || !loaded
        keySource.isEnabled = !busy
        key.isHidden = confirmsRemoval || !loaded || !canManage || configured == nil || {
            if case .value = source { return false }
            return true
        }()
        reference.isHidden = confirmsRemoval || !loaded || !canManage || {
            if case .reference = source { return false }
            return true
        }()
        key.isEnabled = !busy
        reference.isEnabled = !busy
        remove.isHidden = configured != true || !canManage
        remove.title = confirmsRemoval ? "Remove Key" : "Remove Key…"
        remove.setAccessibilityLabel(remove.title)
        remove.isEnabled = !busy
        retry.isHidden = busy || loaded
        closeButton.isEnabled = !busy
        apply.isHidden = confirmsRemoval
        let hasKey = switch source {
        case .saved: configured == true
        case .value, .reference: canManage && replacement != nil
        }
        apply.isEnabled = !busy && loaded && configured != nil && candidate != nil && hasKey
        apply.title = key.isHidden && reference.isHidden ? "Use for Dictation" : "Save and Enable"
        apply.setAccessibilityLabel(apply.title)
        issue.isHidden = issue.stringValue.isEmpty
        if let window, let content = window.contentView {
            content.layoutSubtreeIfNeeded()
            let height = max(198, ceil(content.fittingSize.height))
            if abs(content.bounds.height - height) > 1 { window.setContentSize(NSSize(width: 495, height: height)) }
        }
    }

    @objc private func changed() { issue.stringValue = ""; render() }

    func controlTextDidChange(_ notification: Notification) { changed() }

    @objc private func changeSource() {
        key.stringValue = ""
        reference.stringValue = ""
        if case .reference(let id) = source, workspace.voiceCloudReferences[provider]?.provider == id {
            reference.stringValue = workspace.voiceCloudReferences[provider]?.reference ?? ""
        }
        changed()
    }

    @objc private func submit() {
        guard task == nil, !apply.isHidden, apply.isEnabled, let candidate else { return }
        if case .saved = source {
            guard configured == true else { return }
            enable(candidate)
            finish()
        } else {
            guard canManage, let replacement else {
                issue.stringValue = "Enter a valid API key or secret reference."
                render()
                return
            }
            updateKey(replacement, enable: candidate)
        }
    }

    private func removeKey() {
        guard task == nil, canManage, configured == true else { return }
        if !confirmsRemoval { confirmsRemoval = true; render(); return }
        if workspace.voicePreferences.cloud?.provider == provider {
            var preferences = workspace.voicePreferences
            preferences.grant = nil
            workspace.setVoicePreferences(preferences, target: target)
        }
        updateKey(.null, enable: nil)
    }

    private func updateKey(_ value: Wire, enable destination: VoiceCloudDestination?) {
        issue.stringValue = ""
        let previous = workspace.voicePreferences
        task = Task { [weak self, workspace, target, provider] in
            guard let self else { return }
            defer { task = nil; sync() }
            do {
                guard workspace.can("settings:write") else { throw ClientError.disconnected }
                let api = try workspace.voiceAPI(target)
                try await api.setCloudVoiceKey(value, for: provider)
                guard !Task.isCancelled, workspace.voiceTarget == target else { return }
                if let destination, workspace.voicePreferences.cloud == previous.cloud,
                   workspace.voicePreferences.grant == previous.grant { enable(destination) }
                finish()
            } catch {
                if !Task.isCancelled { issue.stringValue = error.localizedDescription }
            }
        }
        render()
    }

    private func enable(_ destination: VoiceCloudDestination) {
        var preferences = workspace.voicePreferences
        preferences.cloud = destination
        preferences.grant = UUID()
        workspace.setVoicePreferences(preferences, target: target)
    }

    private func finish() {
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
    }
}
