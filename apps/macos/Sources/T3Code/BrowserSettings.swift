import AppKit

@MainActor
final class BrowserSettingsController: NSViewController, NSTextFieldDelegate {
    private struct NameEditor {
        let profile: BrowserProfile?
        let field: NSTextField
        let problem: NSTextField
        let commit: NSButton
    }

    private struct ProfileList: Equatable {
        let profiles: [BrowserProfile]
        let defaultID: String
        let editable: Bool
    }

    private let workspace: Workspace
    private let defaultProfile = NSPopUpButton()
    private lazy var defaultViewport = ActionButton("Fill Panel", symbol: "chevron.up.chevron.down") {
        [weak self] in self?.showViewportMenu()
    }
    private let defaultZoom = NSPopUpButton()
    private let defaultAppearance = NSPopUpButton()
    private let engine = NSPopUpButton()
    private let recordingFrameRate = NSPopUpButton()
    private let recordingShortcuts = NSButton(checkboxWithTitle: "Show Keyboard Shortcuts", target: nil, action: nil)
    private let recordingMouse = NSButton(checkboxWithTitle: "Show Mouse Presses", target: nil, action: nil)
    private let customURL = NSTextField()
    private let profiles = NSView()
    private let notice = NSTextField(wrappingLabelWithString: "")
    private let document = BrowserSettingsDocument()
    private lazy var add = ActionButton("Add Profile…", symbol: "plus", style: .subtle) { [weak self] in self?.editProfile(nil) }
    private lazy var applySearch = ActionButton("Apply", style: .subtle) { [weak self] in self?.saveSearchURL() }
    private lazy var customRow = row([customURL, applySearch], spacing: 8)
    private var nameEditor: NameEditor?
    private var draftSearchURL: String?
    private var profileList: ProfileList?
    private var operation: Task<Void, Never>?
    private var status: String?
    private var failed = false

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = Surface(WorkspaceStyle.navigation)
        defaultProfile.target = self
        defaultProfile.action = #selector(changeDefault)
        defaultViewport.imagePosition = .imageTrailing
        defaultZoom.target = self
        defaultZoom.action = #selector(changeZoom)
        for level in BrowserZoom.levels {
            let item = NSMenuItem(title: level.title, action: nil, keyEquivalent: "")
            item.representedObject = level
            defaultZoom.menu?.addItem(item)
        }
        defaultAppearance.target = self
        defaultAppearance.action = #selector(changeAppearance)
        for appearance in BrowserPageAppearance.allCases {
            let item = NSMenuItem(title: appearance.title, action: nil, keyEquivalent: "")
            item.representedObject = appearance
            defaultAppearance.menu?.addItem(item)
        }
        engine.target = self
        engine.action = #selector(changeSearch)
        for choice in BrowserSearch.Engine.allCases {
            let item = NSMenuItem(title: choice.title, action: nil, keyEquivalent: "")
            item.representedObject = choice.rawValue
            engine.menu?.addItem(item)
        }
        recordingFrameRate.target = self
        recordingFrameRate.action = #selector(changeRecording)
        for rate in BrowserRecordingPreferences.FrameRate.allCases {
            let item = NSMenuItem(title: "\(rate.rawValue) fps", action: nil, keyEquivalent: "")
            item.representedObject = rate
            recordingFrameRate.menu?.addItem(item)
        }
        for button in [recordingShortcuts, recordingMouse] {
            button.target = self
            button.action = #selector(changeRecording)
            button.setAccessibilityLabel(button.title)
        }
        customURL.target = self
        customURL.action = #selector(saveSearchURL)
        customURL.delegate = self
        customURL.placeholderString = "https://search.example.test/?q=%s"
        customURL.setAccessibilityLabel("Custom Search URL")
        customURL.toolTip = "Use %s for the search term."
        customURL.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        notice.font = .systemFont(ofSize: 11.5)
        notice.maximumNumberOfLines = 3

        let scroll = scroller(for: document)
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        let title = label("Browser", size: 16, weight: .semibold, color: WorkspaceStyle.ink)
        let newTabs = column([
            setting("Default Profile", control: defaultProfile),
            setting("Default Viewport", control: defaultViewport),
            setting("Default Zoom", control: defaultZoom),
            setting("Default Page Appearance", control: defaultAppearance),
            setting("Search Engine", control: engine),
            customRow,
        ], spacing: 10, alignment: .width)
        let profileHeading = row([label("Profiles", size: 13, weight: .semibold, color: WorkspaceStyle.ink), NSView(), add])
        let recording = column([
            label("Recording", size: 13, weight: .semibold, color: WorkspaceStyle.ink),
            divider(),
            setting("Recording Frame Rate", control: recordingFrameRate),
            row([recordingShortcuts, NSView()]),
            row([recordingMouse, NSView()]),
        ], spacing: 9, alignment: .width)
        fill(column([newTabs, profileHeading, profiles, recording], spacing: 14, alignment: .width), in: document, inset: 1)
        fill(column([title, divider(), notice, scroll], spacing: 12, alignment: .width), in: view, inset: 20)
        sync()
    }

    private func setting(_ title: String, control: NSControl) -> NSView {
        control.setAccessibilityLabel(title)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return row([label(title, size: 12, color: WorkspaceStyle.ink), NSView(), control])
    }

    private func divider() -> NSView {
        let line = Surface(WorkspaceStyle.line)
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    func sync() {
        guard isViewLoaded else { return }
        let preferences = workspace.browserPreferences
        let editable = operation == nil && nameEditor == nil
        let defaults = preferences.profiles.filter { $0.kind == .persistent }
        if defaultProfile.itemArray.map(\.title) != defaults.map(\.name) ||
            defaultProfile.itemArray.compactMap({ $0.representedObject as? String }) != defaults.map(\.id) {
            defaultProfile.removeAllItems()
            for profile in defaults {
                let item = NSMenuItem(title: profile.name, action: nil, keyEquivalent: "")
                item.representedObject = profile.id
                defaultProfile.menu?.addItem(item)
            }
        }
        defaultProfile.select(defaultProfile.itemArray.first { $0.representedObject as? String == preferences.defaultProfileID })
        defaultViewport.title = preferences.display.viewport.title
        defaultViewport.toolTip = preferences.display.viewport.title
        defaultZoom.select(defaultZoom.itemArray.first { $0.representedObject as? BrowserZoom == preferences.display.zoom })
        defaultAppearance.select(defaultAppearance.itemArray.first { $0.representedObject as? BrowserPageAppearance == preferences.display.appearance })
        engine.select(engine.itemArray.first { $0.representedObject as? String == preferences.search.engine.rawValue })
        recordingFrameRate.select(recordingFrameRate.itemArray.first {
            $0.representedObject as? BrowserRecordingPreferences.FrameRate == preferences.recording.frameRate
        })
        recordingShortcuts.state = preferences.recording.showShortcuts ? .on : .off
        recordingMouse.state = preferences.recording.showMousePresses ? .on : .off
        customRow.isHidden = preferences.search.engine != .custom
        if customURL.currentEditor() == nil { customURL.stringValue = draftSearchURL ?? preferences.search.customTemplate }
        defaultProfile.isEnabled = editable
        defaultViewport.isEnabled = editable
        defaultZoom.isEnabled = editable
        defaultAppearance.isEnabled = editable
        engine.isEnabled = editable
        recordingFrameRate.isEnabled = editable
        recordingShortcuts.isEnabled = editable
        recordingMouse.isEnabled = editable
        customURL.isEnabled = editable
        applySearch.isEnabled = editable
        add.isEnabled = editable && preferences.customProfiles.count < BrowserPreferences.profileLimit
        notice.stringValue = status ?? ""
        notice.textColor = failed ? WorkspaceStyle.negative : WorkspaceStyle.secondary
        notice.isHidden = notice.stringValue.isEmpty
        validateName()
        let next = ProfileList(profiles: preferences.profiles, defaultID: preferences.defaultProfileID, editable: editable)
        guard profileList != next else { return }
        profileList = next
        profiles.subviews.forEach { $0.removeFromSuperview() }
        fill(column(next.profiles.map { profileRow($0, list: next) }, spacing: 0, alignment: .width), in: profiles)
    }

    private func profileRow(_ profile: BrowserProfile, list: ProfileList) -> NSView {
        let icon = WorkspaceStyle.icon(profile.kind == .incognito ? "eye.slash" : "person.crop.circle", size: 16)
        icon.widthAnchor.constraint(equalToConstant: 23).isActive = true
        let name = label(profile.name, size: 12.5, weight: .medium, color: WorkspaceStyle.ink)
        name.toolTip = profile.name
        var views: [NSView] = [icon, name, NSView()]
        if profile.id == list.defaultID && !profile.builtIn { views.append(label("Default", size: 11, color: WorkspaceStyle.muted)) }
        if profile.kind == .incognito { views.append(label("Temporary", size: 11, color: WorkspaceStyle.muted)) }
        else {
            let actions = ActionButton("Actions for \(profile.name)", symbol: "ellipsis", iconOnly: true, style: .subtle) {}
            actions.actionBlock = { [weak self, weak actions] in
                if let actions { self?.showProfileActions(profile, in: actions) }
            }
            actions.isEnabled = list.editable
            actions.widthAnchor.constraint(equalToConstant: 23).isActive = true
            actions.heightAnchor.constraint(equalToConstant: 23).isActive = true
            views.append(actions)
        }
        let content = row(views, spacing: 8)
        content.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return column([divider(), content], spacing: 0, alignment: .width)
    }

    private func showProfileActions(_ profile: BrowserProfile, in button: NSView) {
        guard operation == nil, nameEditor == nil, let current = workspace.browserPreferences.profile(profile.id) else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        if !current.builtIn {
            let rename = menuItem("Rename…", target: self, action: #selector(renameProfile(_:)))
            rename.representedObject = current.id
            menu.addItem(rename)
        }
        let clear = menuItem("Clear Data on Environment…", target: self, action: #selector(clearProfile(_:)))
        clear.representedObject = current.id
        clear.isEnabled = workspace.canClearBrowserProfiles
        menu.addItem(clear)
        if !current.builtIn {
            let remove = menuItem("Remove Profile…", target: self, action: #selector(removeProfile(_:)))
            remove.representedObject = current.id
            remove.isEnabled = workspace.canClearBrowserProfiles
            menu.addItem(remove)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }

    @objc private func changeDefault() {
        guard let id = defaultProfile.selectedItem?.representedObject as? String else { return }
        var next = workspace.browserPreferences
        next.selectDefault(id)
        workspace.updateBrowserPreferences(next)
        sync()
    }

    private func showViewportMenu() {
        guard operation == nil, nameEditor == nil else { return }
        let menu = BrowserViewportMenu.make(current: workspace.browserPreferences.display.viewport, enabled: true,
                                            target: self, select: #selector(selectViewport(_:)), custom: #selector(editViewport))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: defaultViewport.bounds.height), in: defaultViewport)
    }

    @objc private func selectViewport(_ item: NSMenuItem) {
        guard let setting = item.representedObject as? BrowserViewportSetting else { return }
        updateDisplay { $0.viewport = setting }
    }

    @objc private func editViewport() {
        guard operation == nil, nameEditor == nil, let window = view.window else { return }
        let initial = workspace.browserPreferences.display.viewport.size
        Task { [weak self] in
            guard let size = await BrowserViewportEditor.chooseSize(initial, in: window) else { return }
            self?.updateDisplay { $0.viewport = .fixed(size, presetID: nil) }
        }
    }

    @objc private func changeZoom() {
        guard let zoom = defaultZoom.selectedItem?.representedObject as? BrowserZoom else { return }
        updateDisplay { $0.zoom = zoom }
    }

    @objc private func changeAppearance() {
        guard let appearance = defaultAppearance.selectedItem?.representedObject as? BrowserPageAppearance else { return }
        updateDisplay { $0.appearance = appearance }
    }

    private func updateDisplay(_ edit: (inout BrowserDisplaySettings) -> Void) {
        var next = workspace.browserPreferences
        edit(&next.display)
        workspace.updateBrowserPreferences(next)
        sync()
    }

    @objc private func changeRecording() {
        guard let rate = recordingFrameRate.selectedItem?.representedObject as? BrowserRecordingPreferences.FrameRate else { return }
        var next = workspace.browserPreferences
        next.recording.frameRate = rate
        next.recording.showShortcuts = recordingShortcuts.state == .on
        next.recording.showMousePresses = recordingMouse.state == .on
        workspace.updateBrowserPreferences(next)
        sync()
    }

    @objc private func changeSearch() {
        guard let id = engine.selectedItem?.representedObject as? String, let choice = BrowserSearch.Engine(rawValue: id) else { return }
        draftSearchURL = nil
        status = nil
        failed = false
        var next = workspace.browserPreferences
        next.setSearchEngine(choice)
        workspace.updateBrowserPreferences(next)
        sync()
    }

    @objc private func saveSearchURL() {
        let value = customURL.stringValue
        var next = workspace.browserPreferences
        do {
            try next.setCustomSearch(value)
            draftSearchURL = nil
            status = nil
            failed = false
            workspace.updateBrowserPreferences(next)
        } catch {
            draftSearchURL = value
            status = error.localizedDescription
            failed = true
        }
        sync()
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === customURL { draftSearchURL = customURL.stringValue }
        else { validateName() }
    }

    @objc private func renameProfile(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String, let profile = workspace.browserPreferences.profile(id), !profile.builtIn else { return }
        editProfile(profile)
    }

    private func editProfile(_ profile: BrowserProfile?) {
        guard operation == nil, nameEditor == nil, let window = view.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = profile == nil ? "New Browser Profile" : "Rename Browser Profile"
        let input = NSTextField(string: profile?.name ?? "")
        input.placeholderString = "Profile name"
        input.setAccessibilityLabel("Profile Name")
        input.delegate = self
        let problem = label(size: 11, color: WorkspaceStyle.negative)
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 285, height: 49))
        fill(column([input, problem, NSView()], spacing: 4, alignment: .width), in: accessory)
        alert.accessoryView = accessory
        let commit = alert.addButton(withTitle: profile == nil ? "Add Profile" : "Rename")
        alert.addButton(withTitle: "Cancel")
        nameEditor = .init(profile: profile, field: input, problem: problem, commit: commit)
        alert.window.initialFirstResponder = input
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            nameEditor = nil
            if response == .alertFirstButtonReturn {
                do {
                    var next = workspace.browserPreferences
                    try next.saveProfile(name: input.stringValue, editing: profile?.id)
                    status = nil
                    failed = false
                    workspace.updateBrowserPreferences(next)
                } catch {
                    status = error.localizedDescription
                    failed = true
                }
            }
            sync()
        }
        sync()
    }

    private func validateName() {
        guard let editor = nameEditor else { return }
        let text = editor.field.stringValue
        let problem = workspace.browserPreferences.nameProblem(text, for: editor.profile?.id)
        editor.problem.stringValue = text.isEmpty ? "" : problem ?? ""
        editor.commit.isEnabled = problem == nil
    }

    @objc private func clearProfile(_ item: NSMenuItem) { confirmProfileDataAction(item, removing: false) }
    @objc private func removeProfile(_ item: NSMenuItem) { confirmProfileDataAction(item, removing: true) }

    private func confirmProfileDataAction(_ item: NSMenuItem, removing: Bool) {
        guard operation == nil, nameEditor == nil, workspace.canClearBrowserProfiles,
              let connection = workspace.connectionID, let window = view.window, window.attachedSheet == nil,
              let id = item.representedObject as? String, let profile = workspace.browserPreferences.profile(id),
              profile.kind == .persistent, !removing || !profile.builtIn else { return }
        let environment = workspace.environment?.name ?? "the connected environment"
        let alert = NSAlert()
        alert.messageText = removing ? "Remove \(profile.name)?" : "Clear data for \(profile.name)?"
        alert.informativeText = removing ?
            "Remove the profile from this Mac and clear its cookies, cache and site data on \(environment). Its tabs there will close." :
            "Clear this profile’s cookies, cache and site data on \(environment). Its tabs there will close."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: removing ? "Remove Profile" : "Clear Data").hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertSecondButtonReturn, workspace.connectionID == connection else { return }
            clearData(profile, removing: removing, environment: environment, connection: connection)
        }
    }

    private func clearData(_ profile: BrowserProfile, removing: Bool, environment: String, connection: UUID) {
        guard operation == nil else { return }
        status = "Clearing browser data on \(environment)…"
        failed = false
        operation = Task { [weak self, workspace] in
            do {
                try await workspace.clearBrowserProfile(profile.id, connection: connection, removing: removing)
                guard let self else { return }
                status = removing ? "Removed \(profile.name)." : "Cleared browser data on \(environment)."
            } catch {
                self?.status = error.localizedDescription
                self?.failed = true
            }
            self?.operation = nil
            self?.sync()
        }
        sync()
    }
}

private final class BrowserSettingsDocument: NSView {
    override var isFlipped: Bool { true }
}
