import AppKit

@MainActor
final class SettingsController: NSWindowController, NSWindowDelegate {
    private let workspace: Workspace
    private let tabs = NSTabViewController()
    private let cloud: T3ConnectSettings
    private let sharingAccess: SharingAccessSettings
    private let projects: ProjectSettingsController
    private let connections = NSPopUpButton()
    private let connectionStatus = label(size: 12, color: .secondaryLabelColor)
    private let providers: ProviderSettingsController
    private let devices: DeviceSettingsController
    private let browser: BrowserSettingsController
    private let usage: UsageHubSettingsController
    private let notifications: NotificationSettingsController
    private let voice: VoiceSettingsController
    private let appearance = NSPopUpButton()
    private var saved: [SavedEnvironment] = []
    var onPair: (() -> Void)?
    var onScheduled: (() -> Void)?
    var onAddProject: (() -> Void)? { didSet { projects.onAdd = onAddProject } }
    var onError: ((String) -> Void)?

    init(workspace: Workspace, account: T3ConnectAccount?, relay: ManagedRelayClient?, notifications: ThreadNotifications) {
        self.workspace = workspace
        cloud = T3ConnectSettings(workspace: workspace, account: account, relay: relay)
        sharingAccess = SharingAccessSettings(workspace: workspace)
        projects = ProjectSettingsController(workspace: workspace)
        providers = ProviderSettingsController(workspace: workspace)
        devices = DeviceSettingsController(workspace: workspace)
        browser = BrowserSettingsController(workspace: workspace)
        usage = UsageHubSettingsController(workspace: workspace)
        self.notifications = NotificationSettingsController(notifications: notifications)
        voice = VoiceSettingsController(workspace: workspace)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 445),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "T3 Code Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(makeTab("Connections", symbol: "point.3.connected.trianglepath.dotted", content: connectionView()))
        tabs.addTabViewItem(makeTab("T3 Connect", symbol: "globe", controller: cloud))
        tabs.addTabViewItem(makeTab("Sharing & Access", symbol: "lock.shield", controller: sharingAccess))
        tabs.addTabViewItem(makeTab("Providers", symbol: "cpu", controller: providers))
        tabs.addTabViewItem(makeTab("Devices", symbol: "iphone", controller: devices))
        tabs.addTabViewItem(makeTab("Browser", symbol: "globe", controller: browser))
        tabs.addTabViewItem(makeTab("Usage", symbol: "chart.bar", controller: usage))
        tabs.addTabViewItem(makeTab("Projects", symbol: "folder", controller: projects))
        tabs.addTabViewItem(makeTab("Appearance", symbol: "circle.lefthalf.filled", content: appearanceView()))
        tabs.addTabViewItem(makeTab("Notifications", symbol: "bell", controller: self.notifications))
        tabs.addTabViewItem(makeTab("Voice", symbol: "mic", controller: voice))
        tabs.addTabViewItem(makeTab("Scheduled", symbol: "clock", content: scheduledView()))
        window.contentViewController = tabs
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func applyAppearance() {
        switch UserDefaults.standard.string(forKey: "appearance") {
        case "Light": NSApp.appearance = NSAppearance(named: .aqua)
        case "System": NSApp.appearance = nil
        default: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func makeTab(_ title: String, symbol: String, content: NSView) -> NSTabViewItem {
        let controller = NSViewController()
        controller.view = content
        return makeTab(title, symbol: symbol, controller: controller)
    }

    private func makeTab(_ title: String, symbol: String, controller: NSViewController) -> NSTabViewItem {
        controller.title = title
        let item = NSTabViewItem(viewController: controller)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    private func connectionView() -> NSView {
        let view = NSView()
        let add = ActionButton("Pair Environment…", symbol: "plus") { [weak self] in self?.onPair?() }
        let connect = ActionButton("Connect") { [weak self] in self?.connectSelected() }
        let disconnect = ActionButton("Disconnect") { [weak self] in self?.workspace.disconnect() }
        let forget = ActionButton("Forget…") { [weak self] in self?.forgetSelected() }
        connections.setAccessibilityLabel("Saved Environments")
        connectionStatus.maximumNumberOfLines = 4
        connectionStatus.lineBreakMode = .byWordWrapping
        let title = label("Environments", size: 16, weight: .semibold)
        let stack = column([title, connections, connectionStatus, row([connect, disconnect, forget]), add, NSView()],
                           spacing: 12, alignment: .width)
        fill(stack, in: view, inset: 20)
        return view
    }

    private func appearanceView() -> NSView {
        let view = NSView()
        appearance.addItems(withTitles: ["System", "Light", "Dark"])
        appearance.selectItem(withTitle: UserDefaults.standard.string(forKey: "appearance") ?? "Dark")
        appearance.target = self
        appearance.action = #selector(changeAppearance)
        appearance.setAccessibilityLabel("Appearance")
        let renderMath = NSButton(checkboxWithTitle: "Render LaTeX in Markdown", target: self, action: #selector(changeMathRendering(_:)))
        renderMath.state = TranscriptMathRendering.enabled ? .on : .off
        let stack = column([row([label("Appearance"), appearance, NSView()]), row([renderMath, NSView()]), NSView()],
                           spacing: 12, alignment: .width)
        fill(stack, in: view, inset: 20)
        return view
    }

    private func scheduledView() -> NSView {
        let view = NSView()
        let title = label("Scheduled tasks", size: 16, weight: .semibold)
        let text = label("Create and manage tasks on your connected environment.", size: 12, color: .secondaryLabelColor)
        let open = ActionButton("Open Scheduled Tasks", symbol: "clock") { [weak self] in self?.onScheduled?() }
        fill(column([title, text, open, NSView()], spacing: 11), in: view, inset: 20)
        return view
    }

    func render() {
        let previouslySelected = selectedEnvironment?.id
        saved = workspace.environments
        if let active = workspace.environment, !saved.contains(where: { $0.id == active.id }) {
            saved.append(active)
        }
        connections.removeAllItems()
        for environment in saved {
            let route = environment.relay == nil ? environment.origin.host() ?? "" : "T3 Connect"
            connections.menu?.addItem(NSMenuItem(title: "\(environment.name) (\(route))", action: nil, keyEquivalent: ""))
        }
        if saved.isEmpty { connections.addItem(withTitle: "No saved environments") }
        if let index = saved.firstIndex(where: { $0.id == (previouslySelected ?? workspace.environment?.id) }) {
            connections.selectItem(at: index)
        }
        connectionStatus.stringValue = workspace.connectionError ?? {
            switch workspace.connection {
            case .offline: "Disconnected"
            case .connecting: "Connecting…"
            case .ready: "Connected to \(workspace.environment?.origin.absoluteString ?? "environment")"
            case .retrying: "Reconnecting…"
            case .needsPairing: "Pair this environment again to connect."
            }
        }()
        cloud.render()
        sharingAccess.sync()
        syncProjects()
        providers.sync()
        devices.sync()
        browser.sync()
        voice.sync()
        usage.sync()
    }

    func showT3Connect() { showTab(cloud) }
    func showSharingAccess() { showTab(sharingAccess) }
    func showProviders() { showTab(providers) }
    func showDevices() { showTab(devices) }
    func showBrowser() { showTab(browser) }
    func syncBrowserPreferences() { browser.sync() }
    func showUsage() { showTab(usage) }
    func showNotifications() { showTab(notifications) }
    func showVoice() { showTab(voice) }
    func syncVoice() { voice.sync() }
    func syncProjects() { projects.sync() }
    func showProjects(_ id: String?) {
        projects.sync(preferred: id)
        showTab(projects)
    }

    private func showTab(_ controller: NSViewController) {
        if let index = tabs.tabViewItems.firstIndex(where: { $0.viewController === controller }) {
            tabs.selectedTabViewItemIndex = index
        }
        render()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard tabs.tabViewItems.indices.contains(tabs.selectedTabViewItemIndex) else { return }
        let selected = tabs.tabViewItems[tabs.selectedTabViewItemIndex].viewController
        if selected === cloud { cloud.setPresented(true) }
        if selected === sharingAccess { sharingAccess.activate() }
        if selected === providers { providers.setPresented(true) }
        if selected === devices { devices.setPresented(true) }
        if selected === voice { voice.setPresented(true) }
    }

    func windowWillClose(_ notification: Notification) {
        cloud.setPresented(false)
        sharingAccess.deactivate()
        providers.setPresented(false)
        devices.setPresented(false)
        voice.setPresented(false)
    }

    func accountDidChange() { cloud.accountDidChange() }

    private var selectedEnvironment: SavedEnvironment? {
        let index = connections.indexOfSelectedItem
        return saved.indices.contains(index) ? saved[index] : nil
    }

    private func connectSelected() {
        guard let selectedEnvironment, workspace.environments.contains(selectedEnvironment) else { return }
        workspace.connect(to: selectedEnvironment)
    }

    private func forgetSelected() {
        guard let selectedEnvironment, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Forget \(selectedEnvironment.name)?"
        alert.informativeText = selectedEnvironment.relay == nil ?
            "Pair with the environment again the next time you want to connect." :
            "You can connect again from T3 Connect."
        alert.addButton(withTitle: "Forget Environment")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do { try workspace.forget(selectedEnvironment) }
            catch { onError?(error.localizedDescription) }
        }
    }

    @objc private func changeAppearance() {
        UserDefaults.standard.set(appearance.titleOfSelectedItem, forKey: "appearance")
        Self.applyAppearance()
    }

    @objc private func changeMathRendering(_ button: NSButton) {
        TranscriptMathRendering.enabled = button.state == .on
    }
}
