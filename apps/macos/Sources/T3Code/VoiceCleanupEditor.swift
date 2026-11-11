import AppKit

@MainActor
final class VoiceCleanupEditor: NSWindowController {
    private let workspace: Workspace
    private let target: VoiceTarget
    private let originalModel: Wire
    private let model = NSPopUpButton()
    private let promptMode = NSSegmentedControl(labels: ["Built-in", "Custom"], trackingMode: .selectOne, target: nil, action: nil)
    private let prompt = NSTextView()
    private let cue = NSTextField()
    private let issue = NSTextField(wrappingLabelWithString: "")
    private let promptBox = Surface(WorkspaceStyle.canvas, border: WorkspaceStyle.outline, radius: 7)
    private lazy var save = ActionButton("Save Cleanup Settings") { [weak self] in self?.submit() }
    private lazy var cancel = ActionButton("Cancel", style: .subtle) { [weak self] in self?.finish() }
    private var task: Task<Void, Never>?
    var onClose: (() -> Void)?

    init(workspace: Workspace, target: VoiceTarget) {
        self.workspace = workspace
        self.target = target
        originalModel = workspace.voiceCleanupModel
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: 324),
                              styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Transcript Cleanup"
        window.isReleasedWhenClosed = false
        let surface = Surface(WorkspaceStyle.navigation)
        window.contentView = surface
        let heading = label(window.title, size: 16, weight: .semibold, color: WorkspaceStyle.ink)
        let description = label("The environment runs cleanup with the selected text generation model.", size: 12, color: WorkspaceStyle.secondary)
        model.setAccessibilityLabel("Transcript Cleanup Model")
        model.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        populateModels()
        promptMode.target = self
        promptMode.action = #selector(changed)
        promptMode.setAccessibilityLabel("Cleanup Instructions Mode")
        let preferences = workspace.voicePreferences
        promptMode.selectedSegment = preferences.usesCustomCleanupInstructions ? 1 : 0
        prompt.font = .systemFont(ofSize: 12.5)
        prompt.textColor = WorkspaceStyle.ink
        prompt.textContainerInset = NSSize(width: 7, height: 6)
        prompt.isAutomaticQuoteSubstitutionEnabled = false
        prompt.isAutomaticDashSubstitutionEnabled = false
        prompt.setAccessibilityLabel("Custom Cleanup Instructions")
        prompt.string = preferences.cleanupPrompt ?? ""
        fill(textScroller(prompt, editable: true), in: promptBox, inset: 1)
        promptBox.heightAnchor.constraint(equalToConstant: 78).isActive = true
        cue.stringValue = preferences.correctionCue ?? ""
        cue.placeholderString = "Optional"
        cue.setAccessibilityLabel("Spoken Correction Cue")
        issue.font = .systemFont(ofSize: 12)
        issue.textColor = WorkspaceStyle.negative
        issue.maximumNumberOfLines = 2
        issue.setContentHuggingPriority(.required, for: .vertical)
        cancel.keyEquivalent = "\u{1b}"
        let body = column([
            heading, description,
            row([label("Model", size: 12), NSView(), model]),
            row([label("Instructions", size: 12), NSView(), promptMode]), promptBox,
            row([label("Spoken correction cue", size: 12), NSView(), cue]), issue, NSView(),
            row([NSView(), cancel, save]),
        ], spacing: 9, alignment: .width)
        fill(body, in: surface, inset: 17)
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present(in parent: NSWindow) {
        guard let window, parent.attachedSheet == nil else { return }
        parent.beginSheet(window) { [weak self] _ in
            self?.task?.cancel()
            self?.onClose?()
        }
    }

    func sync() {
        guard workspace.voiceTarget == target else { finish(); return }
        render()
    }

    private func populateModels() {
        let fallback = workspace.voiceTextGenerationModel
        let fallbackProvider = workspace.providers.first { $0.id == ComposerModels.instanceID(fallback) }
        let fallbackName = fallbackProvider?.models.first { $0.slug == fallback["model"].string }?.name ?? fallback["model"].string
        model.addItem(withTitle: fallbackName.map { "Environment Default · \($0)" } ?? "Environment Default")
        model.lastItem?.representedObject = Wire.null
        for provider in workspace.providers where provider.isAvailable && provider.supportsTextGeneration {
            for option in provider.models {
                let choice = provider.selection(option)
                let item = NSMenuItem(title: "\(provider.name) · \(option.name)", action: nil, keyEquivalent: "")
                let matches = ComposerModels.instanceID(originalModel) == provider.id && originalModel["model"].string == option.slug
                item.representedObject = matches ? originalModel : choice
                model.menu?.addItem(item)
            }
        }
        if let index = model.itemArray.firstIndex(where: { $0.representedObject as? Wire == originalModel }) {
            model.selectItem(at: index)
        } else {
            let item = NSMenuItem(title: originalModel["model"].string ?? "Configured model", action: nil, keyEquivalent: "")
            item.representedObject = originalModel
            model.menu?.addItem(item)
            model.select(item)
        }
    }

    @objc private func changed() { render() }

    private func render() {
        let busy = task != nil
        model.isEnabled = !busy && workspace.can("settings:write")
        promptMode.isEnabled = !busy
        promptBox.isHidden = promptMode.selectedSegment != 1
        prompt.isEditable = !busy
        cue.isEnabled = !busy
        issue.isHidden = issue.stringValue.isEmpty
        save.isEnabled = !busy
        cancel.isEnabled = !busy
    }

    private func submit() {
        guard task == nil, workspace.voiceTarget == target else { return }
        let useCustom = promptMode.selectedSegment == 1
        let custom = prompt.string
        let correction = cue.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard custom.utf16.count <= 10_000, correction.utf16.count <= 50 else {
            issue.stringValue = "Use up to 10,000 characters for instructions and 50 for the correction cue."
            render()
            return
        }
        let selection = model.selectedItem?.representedObject as? Wire ?? originalModel
        issue.stringValue = ""
        task = Task { [weak self, workspace, target, originalModel] in
            guard let self else { return }
            defer { task = nil; sync() }
            do {
                if selection != originalModel { try await workspace.setVoiceCleanupModel(selection, target: target) }
                guard !Task.isCancelled, workspace.voiceTarget == target else { return }
                var preferences = workspace.voicePreferences
                preferences.cleanupPrompt = custom.isEmpty ? nil : custom
                preferences.cleanupUsesCustomInstructions = useCustom
                preferences.correctionCue = correction.isEmpty ? nil : correction
                workspace.setVoicePreferences(preferences, target: target)
                finish()
            } catch {
                if !Task.isCancelled { issue.stringValue = error.localizedDescription }
            }
        }
        render()
    }

    private func finish() {
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
    }
}
