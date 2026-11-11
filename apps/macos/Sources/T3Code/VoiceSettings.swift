import AppKit

@MainActor
final class VoiceSettingsController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private enum ModelAction: String { case download, select, cancel, remove }

    private let workspace: Workspace
    private let destination = label("Voice", size: 16, weight: .semibold, color: WorkspaceStyle.ink)
    private let destinationInfo = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = label(size: 12, color: WorkspaceStyle.muted)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let sourcePicker = NSPopUpButton()
    private let enabled = NSSwitch()
    private let language = NSPopUpButton()
    private let translate = NSSwitch()
    private let fillers = NSSwitch()
    private let silence = NSSwitch()
    private let cleanup = NSSwitch()
    private let cleanupInfo = NSTextField(wrappingLabelWithString: "Sends the transcript and nearby draft text to this environment’s text generation model.")
    private let table = NSTableView()
    private let modelPanel = Surface(WorkspaceStyle.canvas, border: WorkspaceStyle.outline, radius: 9)
    private let cloudSpacer = NSView()
    private lazy var configureCloud = ActionButton("Configure Provider…", style: .subtle) { [weak self] in
        guard let self, let provider = cloud?.provider else { return }
        showCloud(provider)
    }
    private lazy var configureCleanup = ActionButton("Cleanup Settings…", style: .subtle) { [weak self] in self?.showCleanup() }
    private lazy var refresh = ActionButton("Refresh Speech Models", symbol: "arrow.clockwise", iconOnly: true, style: .subtle) { [weak self] in self?.reload() }
    private lazy var select = ActionButton("Use Model", style: .subtle) { [weak self] in self?.changeModel() }
    private lazy var remove = ActionButton("Remove Model", style: .subtle) { [weak self] in self?.perform(.remove) }
    private var target: VoiceTarget?
    private var cloud: VoiceCloudDestination?
    private var cloudConfigured: Bool?
    private var cloudEditor: VoiceCloudEditor?
    private var cleanupEditor: VoiceCleanupEditor?
    private var status: VoiceStatus?
    private var models: [VoiceModel] = []
    private var reading: Task<Void, Never>?
    private var updating: Task<Void, Never>?
    private var cancelling: Task<Void, Never>?
    private var polling: Task<Void, Never>?
    private var downloadID: String?
    private var presented = false
    private var issue: String?

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = Surface(WorkspaceStyle.navigation)
        let title = row([destination, NSView(), refresh])
        for field in [destinationInfo, errorLabel, cleanupInfo] {
            field.font = .systemFont(ofSize: 12)
            field.maximumNumberOfLines = 2
            field.setContentHuggingPriority(.required, for: .vertical)
        }
        destinationInfo.textColor = WorkspaceStyle.secondary
        cleanupInfo.textColor = WorkspaceStyle.muted
        errorLabel.textColor = WorkspaceStyle.negative
        let modelColumn = NSTableColumn(identifier: .init("voice-model"))
        modelColumn.resizingMask = .autoresizingMask
        table.addTableColumn(modelColumn)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.headerView = nil
        table.style = .inset
        table.backgroundColor = .clear
        table.rowHeight = 29
        table.delegate = self
        table.dataSource = self
        table.setAccessibilityLabel("Speech Models")
        fill(scroller(for: table), in: modelPanel, inset: 3)
        modelPanel.heightAnchor.constraint(greaterThanOrEqualToConstant: 85).isActive = true
        language.controlSize = .small
        language.target = self
        language.action = #selector(changePreferences)
        language.setAccessibilityLabel("Dictation Language")
        sourcePicker.controlSize = .small
        sourcePicker.target = self
        sourcePicker.action = #selector(chooseSource)
        sourcePicker.setAccessibilityLabel("Transcription Destination")
        sourcePicker.menu?.autoenablesItems = false
        let source = row([label("Transcribe with", size: 12, color: WorkspaceStyle.ink), NSView(), sourcePicker, configureCloud])
        let controls = row([statusLabel, NSView(), remove, select], spacing: 8)
        cleanup.controlSize = .small
        cleanup.target = self
        cleanup.action = #selector(changePreferences)
        cleanup.setAccessibilityLabel("Clean Up Transcripts")
        let cleanupRow = row([label("Clean up transcripts", size: 12, color: WorkspaceStyle.ink), NSView(), configureCleanup, cleanup])
        let preferences = column([
            setting("Use this environment for dictation", control: enabled),
            setting("Language", control: language),
            setting("Translate to English", control: translate),
            setting("Remove filler words", control: fillers),
            setting("Filter silence", control: silence),
            cleanupRow, cleanupInfo,
        ], spacing: 6, alignment: .width)
        fill(column([title, source, destinationInfo, preferences, modelPanel, cloudSpacer, controls, errorLabel],
                    spacing: 8, alignment: .width), in: view, inset: 16)
        render()
    }

    private func setting(_ title: String, control: NSControl) -> NSView {
        if let toggle = control as? NSSwitch {
            toggle.controlSize = .small
            toggle.target = self
            toggle.action = #selector(changePreferences)
            toggle.setAccessibilityLabel(title)
        }
        return row([label(title, size: 12, color: WorkspaceStyle.ink), NSView(), control])
    }

    override func viewWillAppear() { super.viewWillAppear(); setPresented(true) }
    override func viewDidDisappear() { super.viewDidDisappear(); setPresented(false) }

    func setPresented(_ value: Bool) {
        guard value != presented else { return }
        let _ = view
        presented = value
        if value { sync(); reload() }
        else {
            reading?.cancel()
            reading = nil
            polling?.cancel()
            polling = nil
        }
    }

    func sync() {
        guard presented, isViewLoaded else { return }
        let next = workspace.voiceTarget
        let nextCloud = workspace.voicePreferences.cloud
        var shouldRead = false
        if target != next {
            target = next
            status = nil
            issue = nil
            reading?.cancel()
            reading = nil
            updating?.cancel()
            updating = nil
            cancelling?.cancel()
            cancelling = nil
            downloadID = nil
            replaceModels([])
            shouldRead = true
        }
        if cloud != nextCloud {
            cloud = nextCloud
            reading?.cancel()
            reading = nil
            issue = nil
            shouldRead = true
        }
        if shouldRead { cloudConfigured = nil; reload() }
        cloudEditor?.sync()
        cleanupEditor?.sync()
        render()
    }

    private var selected: VoiceModel? { models.indices.contains(table.selectedRow) ? models[table.selectedRow] : nil }
    private var transferring: Bool { downloadID != nil || models.contains { $0.state == .downloading || $0.state == .verifying } }

    private func reload() {
        guard presented, let target, reading == nil, workspace.supportsVoiceDestination(cloud) else { return }
        let source = cloud
        reading = Task { [weak self, workspace] in
            guard let self else { return }
            defer {
                if self.target == target, !Task.isCancelled {
                    reading = nil
                    render()
                }
            }
            do {
                let api = try workspace.voiceAPI(target)
                if let source {
                    let keys = try await api.cloudVoiceKeys()
                    guard !Task.isCancelled, workspace.voiceTarget == target, cloud == source else { return }
                    cloudConfigured = keys[source.provider.rawValue].bool
                    return
                }
                async let reply = api.http("/api/voice/status", timeout: 30)
                async let catalog = api.http("/api/voice/models", timeout: 30)
                let (next, modelList) = try await (reply, catalog)
                guard !Task.isCancelled, workspace.voiceTarget == target, cloud == nil else { return }
                guard let status = VoiceStatus(next), case .array(let rows) = modelList["models"] else { throw ClientError.invalidResponse }
                self.status = status
                replaceModels(rows.compactMap(VoiceModel.init))
            } catch {
                if !Task.isCancelled, self.target == target { issue = error.localizedDescription }
            }
        }
        render()
    }

    private func replaceModels(_ next: [VoiceModel]) {
        guard models != next else { return }
        let previous = selected?.id
        models = next
        table.reloadData()
        if let index = models.firstIndex(where: { $0.id == previous }) ?? models.firstIndex(where: \.active) ?? models.indices.first {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    private func render() {
        guard isViewLoaded else { return }
        let preferences = workspace.voicePreferences
        let localReady = target != nil && workspace.supportsVoiceTranscription && status?.supported == true
        let cloudReady = target != nil && workspace.supportsVoiceDestination(cloud) && cloudConfigured == true
        let ready = cloud == nil ? localReady : cloudReady
        let name = workspace.environment?.name
        destination.stringValue = name ?? "Voice"
        renderSources()
        if let cloud, target != nil { destinationInfo.stringValue = cloud.provider.disclosure(environment: name ?? "The environment") }
        else if localReady, let name { destinationInfo.stringValue = "Microphone audio is sent to \(name) for transcription." }
        else { destinationInfo.stringValue = "Choose a connected environment or cloud provider for transcription." }
        configureCloud.isHidden = cloud == nil || !workspace.supportsCloudVoiceTranscription
        configureCloud.isEnabled = target != nil
        configureCleanup.isEnabled = target != nil
        cleanup.state = preferences.cleanupGrant == nil ? .off : .on
        cleanup.isEnabled = target != nil
        enabled.state = preferences.grant == nil ? .off : .on
        enabled.isEnabled = ready || (target != nil && preferences.grant != nil)
        let choices = cloud == nil ? status?.languageChoices ?? ["auto"] : VoiceCloudDestination.languages
        if language.itemArray.compactMap({ $0.representedObject as? String }) != choices {
            language.removeAllItems()
            for code in choices {
                let title = code == "auto" ? "Detect automatically" : Locale.current.localizedString(forLanguageCode: code) ?? code
                language.addItem(withTitle: title)
                language.lastItem?.representedObject = code
            }
        }
        let languageCode = cloud == nil ? status?.language(for: preferences.language) ?? preferences.language : preferences.language
        language.selectItem(at: choices.firstIndex(of: languageCode) ?? 0)
        language.isEnabled = ready
        translate.state = preferences.translate ? .on : .off
        translate.isEnabled = localReady && cloud == nil && status?.canTranslate == true
        fillers.state = preferences.removeFillers ? .on : .off
        silence.state = preferences.filterSilence ? .on : .off
        fillers.isEnabled = ready
        silence.isEnabled = ready && (cloud == nil || cloud?.provider == .xai)
        refresh.isEnabled = target != nil && reading == nil && workspace.supportsVoiceDestination(cloud)
        modelPanel.isHidden = cloud != nil || !workspace.supportsVoiceTranscription
        cloudSpacer.isHidden = !modelPanel.isHidden
        statusLabel.stringValue = {
            if workspace.connection != .ready { return "Connect to an environment to set up dictation." }
            if target == nil { return "Voice input is unavailable on this connection." }
            if let cloud {
                if reading != nil { return "Checking cloud voice settings…" }
                if cloudReady { return preferences.grant == nil ? "Enable dictation for \(cloud.provider.title)." : cloud.title }
                return "Configure \(cloud.provider.title) to use dictation."
            }
            if !workspace.supportsVoiceTranscription { return "Choose a cloud provider for this environment." }
            if let status, !status.supported { return status.reason ?? "Voice input is unavailable." }
            if status?.state == "transcribing" { return "Transcription in progress" }
            if models.contains(where: { $0.active && $0.state == .installed }) {
                return preferences.grant == nil ? "Enable dictation to use this model." : "Ready for dictation"
            }
            if status?.state == "missing-model" { return "Choose a speech model to download." }
            return reading == nil ? "Speech status unavailable" : "Reading speech status…"
        }()
        let canManage = localReady && cloud == nil && workspace.can("settings:write")
        let downloading = selected.map { $0.id == downloadID || $0.state == .downloading || $0.state == .verifying } == true
        select.title = downloading ? "Cancel Download" : selected?.state == .installed ? "Use Model" : "Download Model"
        select.setAccessibilityLabel(select.title)
        let canChoose = selected.map { $0.state != .installed || !$0.active } == true
        select.isEnabled = canManage && cancelling == nil && (downloading || (updating == nil && !transferring && canChoose))
        select.isHidden = modelPanel.isHidden
        remove.isHidden = modelPanel.isHidden || selected?.state != .installed
        remove.isEnabled = canManage && updating == nil && cancelling == nil
        errorLabel.stringValue = issue ?? ""
        errorLabel.isHidden = issue == nil
        if presented && cloud == nil && transferring && polling == nil {
            polling = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) }
                    catch { return }
                    guard let self else { return }
                    reload()
                }
            }
        } else if !transferring || cloud != nil {
            polling?.cancel()
            polling = nil
        }
    }

    private func renderSources() {
        let providers = workspace.supportsCloudVoiceTranscription ? VoiceCloudProvider.allCases : []
        let choices = ["environment"] + providers.map(\.rawValue)
        if sourcePicker.itemArray.compactMap({ $0.representedObject as? String }) != choices {
            sourcePicker.removeAllItems()
            sourcePicker.addItem(withTitle: "Environment Model")
            sourcePicker.lastItem?.representedObject = "environment"
            for provider in providers {
                sourcePicker.addItem(withTitle: provider.title)
                sourcePicker.lastItem?.representedObject = provider.rawValue
            }
        }
        sourcePicker.item(at: 0)?.isEnabled = workspace.supportsVoiceTranscription
        sourcePicker.selectItem(at: choices.firstIndex(of: cloud?.provider.rawValue ?? "environment") ?? 0)
        sourcePicker.isEnabled = target != nil && !providers.isEmpty
    }

    @objc private func chooseSource() {
        guard let target, let selection = sourcePicker.selectedItem?.representedObject as? String else { return }
        if let provider = VoiceCloudProvider(rawValue: selection) { showCloud(provider) }
        else if workspace.supportsVoiceTranscription, cloud != nil {
            var preferences = workspace.voicePreferences
            preferences.cloud = nil
            preferences.grant = nil
            workspace.setVoicePreferences(preferences, target: target)
        }
        render()
    }

    private func showCloud(_ provider: VoiceCloudProvider) {
        guard let target, workspace.supportsCloudVoiceTranscription, let window = view.window, window.attachedSheet == nil else { return }
        let editor = VoiceCloudEditor(workspace: workspace, target: target, provider: provider)
        cloudEditor = editor
        editor.onClose = { [weak self, weak editor] in
            guard let self, cloudEditor === editor else { return }
            cloudEditor = nil
            reading?.cancel()
            reading = nil
            reload()
            render()
        }
        editor.present(in: window)
    }

    private func showCleanup() {
        guard let target, let window = view.window, window.attachedSheet == nil else { return }
        let editor = VoiceCleanupEditor(workspace: workspace, target: target)
        cleanupEditor = editor
        editor.onClose = { [weak self, weak editor] in
            if self?.cleanupEditor === editor { self?.cleanupEditor = nil }
        }
        editor.present(in: window)
    }

    @objc private func changePreferences() {
        guard let target else { return }
        var next = workspace.voicePreferences
        if enabled.state == .off { next.grant = nil }
        else if next.grant == nil, enabled.isEnabled { next.grant = UUID() }
        if cleanup.state == .off { next.cleanupGrant = nil }
        else if next.cleanupGrant == nil { next.cleanupGrant = UUID() }
        next.language = language.selectedItem?.representedObject as? String ?? "auto"
        next.translate = translate.state == .on
        next.removeFillers = fillers.state == .on
        next.filterSilence = silence.state == .on
        workspace.setVoicePreferences(next, target: target)
    }

    private func changeModel() {
        guard let model = selected, select.isEnabled else { return }
        if model.id == downloadID || model.state == .downloading || model.state == .verifying { perform(.cancel) }
        else { perform(model.state == .installed ? .select : .download) }
    }

    private func perform(_ action: ModelAction) {
        guard cloud == nil, let target, let model = selected, workspace.can("settings:write"), cancelling == nil,
              action == .cancel || updating == nil else { return }
        issue = nil
        if action == .download { downloadID = model.id }
        let task = Task { [weak self, workspace] in
            guard let self else { return }
            defer {
                if self.target == target, !Task.isCancelled {
                    if action == .cancel { cancelling = nil }
                    else {
                        updating = nil
                        downloadID = nil
                    }
                    reading?.cancel()
                    reading = nil
                    reload()
                    render()
                }
            }
            do {
                let api = try workspace.voiceAPI(target)
                let data = try JSONEncoder().encode(Wire.object(["modelId": .string(model.id)]))
                let reply = try await api.http("/api/voice/models/\(action.rawValue)", method: "POST", body: data,
                                               contentType: "application/json", timeout: action == .download ? 1_800 : 30)
                guard !Task.isCancelled, workspace.voiceTarget == target else { return }
                guard case .array(let rows) = reply["models"] else { throw ClientError.invalidResponse }
                if action == .cancel, downloadID == model.id {
                    updating?.cancel()
                    updating = nil
                    downloadID = nil
                }
                replaceModels(rows.compactMap(VoiceModel.init))
            } catch {
                if !Task.isCancelled, self.target == target, action == .cancel || cancelling == nil { issue = error.localizedDescription }
            }
        }
        if action == .cancel { cancelling = task }
        else { updating = task }
        render()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { models.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        let model = models[index]
        let name = label(model.name, size: 12, weight: .medium, color: WorkspaceStyle.ink)
        name.toolTip = model.name
        let status = label(model.statusLabel, size: 11, color: model.active && model.state == .installed ? WorkspaceStyle.positive : WorkspaceStyle.muted)
        status.setContentCompressionResistancePriority(.required, for: .horizontal)
        return row([name, NSView(), status], spacing: 7)
    }

    func tableViewSelectionDidChange(_ notification: Notification) { render() }
}
