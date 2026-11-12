import AppKit

enum WorkspacePage { case conversation, scheduled, pullRequests, usage }

@main
enum T3CodeApplication {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate(arguments: CommandLine.arguments)
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSWindowDelegate {
    private let workspace: Workspace
    private let notifications: ThreadNotifications
    private let connectAccount: T3ConnectAccount?
    private let relayClient: ManagedRelayClient?
    private let pairingFile: URL?
    private let localServer: LocalServer
    private let split = NSSplitViewController()
    private let rail = NavigationRail()
    private lazy var sidebar = SidebarController(workspace: workspace)
    private lazy var conversation = ConversationController(workspace: workspace)
    private lazy var inspector = InspectorController(workspace: workspace)
    private lazy var sideChats = SideChatPanel(workspace: workspace)
    private lazy var relationships = ThreadRelationshipPanel(workspace: workspace)
    private lazy var scheduled = ScheduledTasksController(workspace: workspace)
    private lazy var pullRequests = PullRequestInboxController(workspace: workspace)
    private lazy var usage = UsageController(workspace: workspace)
    private let workspaceContent = NSViewController()
    private let pageContent = NSView()
    private let auxiliaryContent = NSViewController()
    private var sideChatPresented = false
    private var relationshipsPresented = false
    private var page = WorkspacePage.conversation
    private var inspectorItem: NSSplitViewItem?
    private var sidebarItem: NSSplitViewItem?
    private var window: NSWindow!
    private var settings: SettingsController?
    private var projectOnboarding: ProjectOnboardingController?
    private var activityClock: Task<Void, Never>?
    private var decidingQuit = false
    private var quickOpen: QuickOpen?
    private var pendingCitation: (citation: AssistantCitation, environmentID: String)?

    init(arguments: [String]) {
        let persistent = !arguments.contains("--ephemeral")
        let account = persistent ? T3ConnectConfiguration.read().map(T3ConnectAccount.init(configuration:)) : nil
        let relay = account.map { account in
            ManagedRelayClient(origin: account.configuration.relay, persistent: persistent) { id in
                try await account.token(for: id)
            }
        }
        connectAccount = account
        relayClient = relay
        workspace = Workspace(persistent: persistent, relayClient: relay)
        notifications = ThreadNotifications(persistent: persistent)
        func path(_ key: String) -> URL? {
            guard let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1) else { return nil }
            return URL(fileURLWithPath: arguments[index + 1])
        }
        pairingFile = path("--pairing-file")
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let base = path("--server-home") ?? applicationSupport.appendingPathComponent("T3 Code AppKit")
        localServer = LocalServer(base: base, executable: path("--server-executable"))
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        SettingsController.applyAppearance()
        installMenus()
        makeWindow()
        workspace.onChange = { [weak self] change in self?.render(change) }
        workspace.onError = { [weak self] message in self?.showError(message) }
        notifications.onSettingsChange = { [weak self] in self?.updateNotificationObserver() }
        notifications.onOpen = { [weak self] target in self?.openNotification(target) }
        notifications.isViewing = { [weak self] target in self?.isViewingNotificationTarget(target) == true }
        updateNotificationObserver()
        connectAccount?.onChange = { [weak self] previous, current in
            guard let self else { return }
            if let oldID = previous?.id, oldID != current?.id {
                workspace.removeRelayEnvironments(for: oldID)
                Task { await self.relayClient?.signOut(accountID: oldID) }
            }
            if let current, let active = workspace.environment, active.relay?.accountID == current.id,
               workspace.connection == .needsPairing {
                workspace.connect(to: active)
            }
            settings?.accountDidChange()
        }
        render(.all)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let pairingFile {
            do {
                let address = try String(contentsOf: pairingFile, encoding: .utf8)
                workspace.pair(try PairingTarget(address: address, code: ""), persistent: false)
            } catch { showError(error.localizedDescription) }
        } else { workspace.restoreConnection() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if decidingQuit { return .terminateLater }
        guard inspector.hasUnsavedFiles || inspector.hasPendingBrowserCapture else { return .terminateNow }
        decidingQuit = true
        Task {
            var shouldQuit = true
            if inspector.hasUnsavedFiles { shouldQuit = await inspector.flushBeforeQuit() }
            if !shouldQuit {
                let alert = NSAlert()
                alert.messageText = "Unsaved workspace files"
                alert.informativeText = "Some file edits could not be saved to their environment."
                alert.addButton(withTitle: "Keep Editing")
                alert.addButton(withTitle: "Quit Without Saving")
                shouldQuit = alert.runModal() == .alertSecondButtonReturn
            }
            if shouldQuit { await inspector.finishBrowserCaptureBeforeQuit() }
            decidingQuit = false
            if !shouldQuit { inspector.resumeAfterCancelledQuit() }
            sender.reply(toApplicationShouldTerminate: shouldQuit)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        notifications.setEnvironment(nil)
        activityClock?.cancel()
        quickOpen?.close()
        inspector.shutdown()
        scheduled.shutdown()
        if pullRequests.parent != nil { pullRequests.shutdown() }
        if page == .usage { usage.setPresented(false) }
        workspace.shutdown()
        connectAccount?.shutdown()
        localServer.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        notifications.clearBackground()
        syncProviderUsageActivity()
    }

    func applicationDidResignActive(_ notification: Notification) {
        workspace.updateProviderUsageActivity(active: false)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        notifications.clearBackground()
        syncProviderUsageActivity()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) { syncProviderUsageActivity() }

    private func syncProviderUsageActivity() {
        workspace.updateProviderUsageActivity(active: NSApp.isActive && window?.occlusionState.contains(.visible) == true)
    }

    private func makeWindow() {
        let tools = NSSplitViewItem(viewController: rail)
        tools.minimumThickness = WorkspaceStyle.railWidth
        tools.maximumThickness = WorkspaceStyle.railWidth
        tools.holdingPriority = .required
        split.addSplitViewItem(tools)
        let navigation = NSSplitViewItem(viewController: sidebar)
        navigation.minimumThickness = 211
        navigation.maximumThickness = 262
        navigation.automaticMaximumThickness = 246
        navigation.preferredThicknessFraction = 0.213
        navigation.holdingPriority = NSLayoutConstraint.Priority(260)
        navigation.canCollapse = true
        split.addSplitViewItem(navigation)
        sidebarItem = navigation
        workspaceContent.view = NSView()
        fill(pageContent, in: workspaceContent.view)
        workspaceContent.addChild(conversation)
        fill(conversation.view, in: pageContent)
        notifications.install(in: workspaceContent.view)
        let main = NSSplitViewItem(viewController: workspaceContent)
        main.minimumThickness = 420
        split.addSplitViewItem(main)
        auxiliaryContent.view = NSView()
        auxiliaryContent.addChild(inspector)
        fill(inspector.view, in: auxiliaryContent.view)
        let extra = NSSplitViewItem(inspectorWithViewController: auxiliaryContent)
        extra.minimumThickness = 240
        extra.maximumThickness = 580
        extra.preferredThicknessFraction = 0.28
        extra.holdingPriority = NSLayoutConstraint.Priority(255)
        extra.canCollapse = true
        extra.allowsFullHeightLayout = true
        extra.isCollapsed = true
        split.addSplitViewItem(extra)
        inspectorItem = extra
        split.splitView.isVertical = true
        split.splitView.dividerStyle = .thin
        split.splitView.autosaveName = "T3Code.Workspace.Rail"

        window = NSWindow(contentViewController: split)
        window.delegate = self
        window.title = "T3 Code"
        window.styleMask.formUnion([.resizable, .fullSizeContentView])
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.backgroundColor = WorkspaceStyle.canvas
        window.contentMinSize = NSSize(width: 690, height: 520)
        window.isReleasedWhenClosed = false
        extra.isCollapsed = true
        window.setContentSize(NSSize(width: 1160, height: 720))
        window.contentView?.layoutSubtreeIfNeeded()
        split.splitView.setPosition(WorkspaceStyle.railWidth + 248, ofDividerAt: 1)
        window.center()

        rail.onSidebar = { [weak self] in self?.toggleSidebar() }
        rail.onNew = { [weak self] in self?.newThread() }
        rail.onSearch = { [weak self] in self?.searchConversations() }
        rail.onTerminal = { [weak self] in self?.showTerminal() }
        rail.onFiles = { [weak self] in self?.showFiles() }
        rail.onUsage = { [weak self] in self?.showUsage() }
        rail.onSettings = { [weak self] in self?.openSettings() }
        sidebar.onAdd = { [weak self] in self?.addProject() }
        sidebar.onSearch = { [weak self] in self?.searchConversations() }
        sidebar.onNew = { [weak self] in self?.newThread() }
        sidebar.onNewChat = { [weak self] in
            guard let self else { return }
            showWorkspace()
            perform {
                try await self.workspace.startScratch()
                self.conversation.focusComposer()
            }
        }
        sidebar.onScheduled = { [weak self] in self?.showScheduled() }
        sidebar.onPullRequests = { [weak self] projectID in
            guard let self else { return }
            showPullRequests()
            if let projectID { pullRequests.filterProject(projectID) }
        }
        sidebar.onShowWorkspace = { [weak self] in self?.showWorkspace() }
        sidebar.onThreadAction = { [weak self] id, command in self?.threadAction(id, command) }
        sidebar.onProjectSettings = { [weak self] target in
            guard let self, workspace.projectTarget(target.id) == target else { return }
            settingsController().showProjects(target.id)
        }
        sidebar.onProjectChange = { [weak self] target, change in
            guard let self else { return }
            perform { try await self.workspace.changeProject(target, change) }
        }
        scheduled.onCount = { [weak self] count in self?.sidebar.setScheduledCount(count) }
        scheduled.onBack = { [weak self] in self?.showWorkspace() }
        scheduled.onAddProject = { [weak self] in self?.addProject() }
        scheduled.onOpenThread = { [weak self] id in
            guard let self else { return }
            workspace.showArchive(false)
            workspace.select(.thread(id))
            showWorkspace()
        }
        pullRequests.onBack = { [weak self] in self?.showWorkspace() }
        pullRequests.onOpenThread = { [weak self] id, archived in
            guard let self else { return }
            workspace.showArchive(archived)
            workspace.select(.thread(id))
            showWorkspace()
        }
        pullRequests.onCheckout = { [weak self] reference, url in
            guard let self, workspace.can("source-control:write"), workspace.can("orchestration:operate"),
                  workspace.data.projects[reference.projectID]?.archived == false else { return }
            workspace.showArchive(false)
            workspace.select(.project(reference.projectID))
            showWorkspace()
            conversation.showPullRequestCheckout(reference: url)
        }
        conversation.onPair = { [weak self] in self?.pairEnvironment() }
        conversation.onVoiceSettings = { [weak self] in self?.openVoiceSettings() }
        conversation.onOpenCitation = { [weak self] citation in self?.openCitation(citation) }
        conversation.onT3Connect = { [weak self] in self?.openT3Connect() }
        conversation.onStartLocal = { [weak self] in self?.startLocalServer() }
        conversation.onAdd = { [weak self] in self?.addProject() }
        conversation.onInspector = { [weak self] tab in self?.toggleInspector(tab) }
        conversation.onOpenWorkspaceFile = { [weak self] reference, context in
            guard let self, workspace.workspaceFileContext == context else { return }
            showInspector(.files, opening: reference)
        }
        conversation.onRepositoryChange = { [weak self] in
            guard let self, inspector.selectedTab == .changes, inspectorItem?.isCollapsed == false else { return }
            inspector.sync(force: true)
        }
        inspector.onBrowserReveal = { [weak self] in
            guard let self, page == .conversation else { return }
            showInspector(.browser)
        }
        inspector.onBrowserSettings = { [weak self] in self?.openBrowserSettings() }
        inspector.onBrowserRecordingChange = { [weak self] active in self?.conversation.showBrowserRecording(active) }
        inspector.onAttachBrowserRecording = { [weak self] clip in
            guard let self else { throw ClientError.disconnected }
            showWorkspace()
            try conversation.attachBrowserRecording(clip)
        }
        inspector.onAttachBrowserImage = { [weak self] file, target in
            guard let self else { throw ClientError.disconnected }
            showWorkspace()
            try conversation.attachBrowserMedia(file, target: target)
        }
        inspector.onError = { [weak self] message in self?.showError(message) }
        inspector.onDeviceSettings = { [weak self] in self?.openDeviceSettings() }
        conversation.onTerminalToggle = { [weak self] open in self?.rail.terminalButton.isMarked = open }
        conversation.onThreadAction = sidebar.onThreadAction
        conversation.onProjectSettings = sidebar.onProjectSettings
        conversation.onProjectActionPreview = { [weak self] address, target in
            guard let self, workspace.projectActionTarget == target, workspace.can("preview:operate"), inspector.canShow(.browser) else { return }
            showInspector(.browser)
            inspector.openActionPreview(address)
        }
        conversation.onOpenPullRequest = { [weak self] reference in
            guard let self else { return }
            showPullRequests()
            pullRequests.open(reference)
        }
        conversation.onShowUsageLimits = { [weak self] in
            guard let self else { return }
            usage.selectLimits()
            showUsage()
        }
        conversation.onOpenSideChat = { [weak self] id in self?.openSideChatLink(id) ?? false }
        conversation.onRelatedConversations = { [weak self] in self?.showRelatedConversations() }
        conversation.onSideChatStarted = { [weak self] reference, model in
            guard let self else { return }
            sideChats.conversation.seedSideChatDraft(reference, model: model)
            if workspace.selectedThread?.id == reference.parentID, page == .conversation,
               workspace.presentSideChat(reference) {
                sideChats.conversation.focusComposer()
            }
        }
        conversation.onError = { [weak self] message in self?.showError(message) }
    }

    private func render(_ change: Workspace.Change) {
        if change == .voiceInput || change == .voiceSettings {
            conversation.render(change)
            if sideChatPresented { sideChats.conversation.render(change) }
            if change == .voiceSettings { settings?.syncVoice() }
            return
        }
        if change.contains(.connection) {
            let hasSession = workspace.connection != .offline && workspace.connection != .needsPairing
            notifications.setEnvironment(hasSession ? workspace.environment?.id : nil)
        }
        if change.contains(.selection) || change.contains(.sideChat) { dismissViewedNotifications() }
        if change == .browserSettings {
            inspector.syncBrowserPreferences()
            settings?.syncBrowserPreferences()
            return
        }
        if change == .sideChat {
            syncSideChatPane(change)
            advanceCitationNavigation()
            return
        }
        if change == .clones {
            conversation.renderProjectClone()
            quickOpen?.sync()
            return
        }
        if !change.intersection([.selection, .connection]).isEmpty { quickOpen?.sync() }
        if !change.intersection([.sidebar, .connection, .selection]).isEmpty {
            sidebar.render()
            rail.sidebarButton.isMarked = sidebarItem?.isCollapsed == false
            rail.newButton.isEnabled = workspace.can("orchestration:operate")
            rail.filesButton.isEnabled = rail.filesButton.isMarked || (workspace.can("filesystem:read") && workspace.workspacePath != nil)
            rail.terminalButton.isEnabled = rail.terminalButton.isMarked || (workspace.can("terminal:operate") && workspace.selectedThread != nil)
            syncActivityClock()
        }
        conversation.render(change)
        syncSideChatPane(change)
        advanceCitationNavigation()
        if relationshipsPresented {
            if workspace.selectedThread == nil { hideRelatedConversations() }
            else { relationships.sync(change) }
        }
        if change.contains(.connection) || page == .scheduled { scheduled.sync() }
        if page == .pullRequests && !change.intersection([.connection, .sidebar]).isEmpty { pullRequests.sync() }
        if page == .usage && !change.intersection([.connection, .providers]).isEmpty {
            usage.sync(configurationOnly: !change.contains(.connection))
        }
        if !change.intersection([.sidebar, .selection, .connection]).isEmpty {
            inspector.sync(force: change.contains(.connection))
        }
        if !change.intersection([.connection, .providers]).isEmpty {
            settings?.render()
            projectOnboarding?.sync()
        }
        else if change.contains(.projects) { settings?.syncProjects() }
    }

    private func updateNotificationObserver() {
        guard !notifications.channels.isEmpty else {
            workspace.onThreadShellChange = nil
            return
        }
        workspace.onThreadShellChange = { [weak self] update in
            guard let self, workspace.can("orchestration:read") else { return }
            notifications.receive(update, data: workspace.data)
        }
        if workspace.can("orchestration:read") { notifications.receive(.snapshot, data: workspace.data) }
    }

    private func isViewingNotificationTarget(_ target: ThreadNotice.Target) -> Bool {
        page == .conversation && workspace.environment?.id == target.environmentID &&
            (workspace.selectedThread?.id == target.threadID || workspace.sideChat?.threadID == target.threadID)
    }

    private func dismissViewedNotifications() {
        guard page == .conversation, let environment = workspace.environment?.id else { return }
        if let selected = workspace.selectedThread?.id {
            notifications.dismissBanner(.init(environmentID: environment, threadID: selected))
        }
        if let sideChat = workspace.sideChat?.threadID {
            notifications.dismissBanner(.init(environmentID: environment, threadID: sideChat))
        }
    }

    private func openNotification(_ target: ThreadNotice.Target) {
        guard workspace.environment?.id == target.environmentID, workspace.data.threads[target.threadID]?.archived == false else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !openSideChatLink(target.threadID) {
            workspace.showArchive(false)
            workspace.select(.thread(target.threadID))
            showWorkspace()
        }
    }

    private func syncActivityClock() {
        guard workspace.connection == .ready, workspace.data.threads.values.contains(where: \.isWorking) else {
            activityClock?.cancel()
            activityClock = nil
            return
        }
        guard activityClock == nil else { return }
        activityClock = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
                guard let self else { return }
                guard window.occlusionState.contains(.visible) else { continue }
                sidebar.refreshActivityTimes()
                if page == .conversation {
                    conversation.refreshActivityTime()
                    if sideChatPresented { sideChats.conversation.refreshActivityTime() }
                }
            }
        }
    }

    private func installMenus() {
        let main = NSMenu()
        let application = NSMenu()
        application.addItem(menuItem("About T3 Code", target: NSApp, action: #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        application.addItem(.separator())
        application.addItem(menuItem("Settings…", target: self, action: #selector(openSettings), key: ","))
        application.addItem(menuItem("Provider Settings…", target: self, action: #selector(openProviderSettings)))
        application.addItem(menuItem("Notification Settings…", target: self, action: #selector(openNotificationSettings)))
        application.addItem(.separator())
        application.addItem(menuItem("Hide T3 Code", target: NSApp, action: #selector(NSApplication.hide(_:)), key: "h"))
        application.addItem(menuItem("Quit T3 Code", target: NSApp, action: #selector(NSApplication.terminate(_:)), key: "q"))
        addMenu("T3 Code", application, to: main)

        let file = NSMenu(title: "File")
        file.addItem(menuItem("New Thread", target: self, action: #selector(newThread), key: "n"))
        file.addItem(menuItem("New Side Chat", target: self, action: #selector(newSideChat)))
        file.addItem(menuItem("Add Project…", target: self, action: #selector(addProject), key: "o"))
        file.addItem(menuItem("Project Settings…", target: self, action: #selector(openProjectSettings)))
        file.addItem(menuItem("Share with Guest…", target: self, action: #selector(openGuestShare)))
        file.addItem(menuItem("Pair Environment…", target: self, action: #selector(pairEnvironment), key: "k", modifiers: [.command, .shift]))
        file.addItem(menuItem("T3 Connect…", target: self, action: #selector(openT3Connect)))
        file.addItem(menuItem("Sharing & Access…", target: self, action: #selector(openSharingAccess)))
        file.addItem(menuItem("Start Local Server", target: self, action: #selector(startLocalServer)))
        file.addItem(.separator())
        file.addItem(menuItem("Save File", target: self, action: #selector(saveWorkspaceFile), key: "s"))
        file.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        addMenu("File", file, to: main)

        let edit = NSMenu(title: "Edit")
        for (name, action, key, modifiers) in [
            ("Undo", Selector(("undo:")), "z", NSEvent.ModifierFlags.command),
            ("Redo", Selector(("redo:")), "z", [.command, .shift]),
            ("Cut", #selector(NSText.cut(_:)), "x", .command),
            ("Copy", #selector(NSText.copy(_:)), "c", .command),
            ("Paste", #selector(NSText.paste(_:)), "v", .command),
            ("Select All", #selector(NSText.selectAll(_:)), "a", .command),
        ] {
            let item = NSMenuItem(title: name, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            edit.addItem(item)
        }
        edit.addItem(.separator())
        edit.addItem(menuItem("Find in Thread…", target: self, action: #selector(findInThread), key: "f"))
        edit.addItem(menuItem("Find Next", target: self, action: #selector(findNext), key: "g"))
        edit.addItem(menuItem("Find Previous", target: self, action: #selector(findPrevious), key: "g",
                              modifiers: [.command, .shift]))
        edit.addItem(menuItem("Edit Last Message…", target: self, action: #selector(editLastMessage)))
        edit.addItem(menuItem("Dictate Message", target: self, action: #selector(toggleDictation), key: "d", modifiers: [.command, .shift]))
        addMenu("Edit", edit, to: main)

        let view = NSMenu(title: "View")
        view.addItem(menuItem("Quick Open…", target: self, action: #selector(openQuickOpen), key: "k"))
        view.addItem(menuItem("Search Conversations…", target: self, action: #selector(searchConversations)))
        view.addItem(menuItem("Find Files…", target: self, action: #selector(findWorkspaceFiles)))
        view.addItem(menuItem("Find in Files…", target: self, action: #selector(findWorkspaceContents)))
        view.addItem(menuItem("Related Conversations…", target: self, action: #selector(showRelatedConversations)))
        view.addItem(menuItem("Toggle Sidebar", target: self, action: #selector(toggleSidebar), key: "s", modifiers: [.command, .option]))
        view.addItem(menuItem("Filter Threads", target: self, action: #selector(focusSearch), key: "f",
                              modifiers: [.command, .shift]))
        view.addItem(menuItem("Show Active Threads Only", target: self, action: #selector(toggleActivity)))
        view.addItem(menuItem("Toggle Archive", target: self, action: #selector(showArchive)))
        view.addItem(menuItem("Scheduled Tasks", target: self, action: #selector(showScheduled), key: "4", modifiers: [.command, .option]))
        view.addItem(menuItem("Pull Requests", target: self, action: #selector(showPullRequests), key: "5", modifiers: [.command, .option]))
        view.addItem(menuItem("Usage", target: self, action: #selector(showUsage), key: "6", modifiers: [.command, .option]))
        view.addItem(.separator())
        view.addItem(menuItem("Toggle Files", target: self, action: #selector(showFiles), key: "1", modifiers: [.command, .option]))
        view.addItem(menuItem("Toggle Changes", target: self, action: #selector(showChanges), key: "2", modifiers: [.command, .option]))
        view.addItem(menuItem("Toggle Browser", target: self, action: #selector(toggleBrowser), key: "3", modifiers: [.command, .option]))
        view.addItem(menuItem("Toggle Device", target: self, action: #selector(toggleDevice), key: "7", modifiers: [.command, .option]))
        view.addItem(menuItem("Device Settings…", target: self, action: #selector(openDeviceSettings)))
        view.addItem(menuItem("Focus Browser Address", target: self, action: #selector(focusBrowserAddress), key: "l"))
        view.addItem(menuItem("New Browser Tab", target: self, action: #selector(newBrowserTab), key: "t"))
        view.addItem(menuItem("New Browser Tab in Profile…", target: self, action: #selector(newBrowserTabInProfile)))
        view.addItem(menuItem("Browser Zoom In", target: self, action: #selector(zoomBrowserIn), key: "="))
        view.addItem(menuItem("Browser Zoom Out", target: self, action: #selector(zoomBrowserOut), key: "-"))
        view.addItem(menuItem("Browser Actual Size", target: self, action: #selector(resetBrowserZoom), key: "0"))
        view.addItem(menuItem("Start Browser Recording", target: self, action: #selector(startBrowserRecording)))
        view.addItem(menuItem("Stop Browser Recording", target: self, action: #selector(stopBrowserRecording)))
        view.addItem(menuItem("Stop All Browser Recordings", target: self, action: #selector(stopAllBrowserRecordings)))
        view.addItem(menuItem("Latest Browser Recording…", target: self, action: #selector(previewLatestBrowserRecording)))
        view.addItem(menuItem("Take Browser Screenshot", target: self, action: #selector(captureBrowserScreenshot)))
        view.addItem(menuItem("Annotate Browser Region…", target: self, action: #selector(annotateBrowserRegion)))
        view.addItem(menuItem("Latest Browser Screenshot…", target: self, action: #selector(previewLatestBrowserScreenshot)))
        view.addItem(menuItem("Browser Settings…", target: self, action: #selector(openBrowserSettings)))
        view.addItem(menuItem("Toggle Terminal", target: self, action: #selector(showTerminal), key: "`"))
        view.addItem(.separator())
        view.addItem(menuItem("Send Next Queued Message", target: self, action: #selector(sendNextQueuedMessage), key: "\r",
                              modifiers: [.command, .shift]))
        addMenu("View", view, to: main)
        let repository = NSMenu(title: "Repository")
        repository.addItem(menuItem("Source Control…", target: self, action: #selector(showSourceControl), key: "g",
                                    modifiers: [.command, .option]))
        repository.addItem(menuItem("Choose Branch…", target: self, action: #selector(showBranches), key: "b",
                                    modifiers: [.command, .option]))
        repository.addItem(menuItem("Thread from Pull Request…", target: self, action: #selector(checkoutPullRequest)))
        addMenu("Repository", repository, to: main)
        let windows = NSMenu(title: "Window")
        windows.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windows.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        addMenu("Window", windows, to: main)
        NSApp.windowsMenu = windows
        NSApp.mainMenu = main
    }

    private func addMenu(_ title: String, _ submenu: NSMenu, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleActivity) {
            menuItem.state = sidebar.showsActivityOnly ? .on : .off
            return workspace.connection == .ready || sidebar.showsActivityOnly
        }
        return switch menuItem.action {
        case #selector(saveWorkspaceFile): page == .conversation && inspector.canSaveCurrentFile
        case #selector(startLocalServer): !localServer.isStarting
        case #selector(newThread), #selector(addProject): workspace.can("orchestration:operate")
        case #selector(newSideChat): page == .conversation && workspace.sideChatParent != nil
        case #selector(showRelatedConversations): page == .conversation && workspace.threadRelationshipScope != nil
        case #selector(findWorkspaceFiles), #selector(findWorkspaceContents): workspace.fileSearchScope != nil
        case #selector(openProjectSettings): workspace.can("orchestration:read")
        case #selector(openGuestShare): page == .conversation && focusedConversation.canOpenGuestShare
        case #selector(showFiles): rail.filesButton.isEnabled
        case #selector(showChanges): (inspectorItem?.isCollapsed == false && inspector.selectedTab == .changes) ||
            (workspace.can("filesystem:read") && workspace.workspacePath != nil)
        case #selector(toggleBrowser): (inspectorItem?.isCollapsed == false && inspector.selectedTab == .browser) || inspector.canShow(.browser)
        case #selector(toggleDevice): (inspectorItem?.isCollapsed == false && inspector.selectedTab == .device) || inspector.canShow(.device)
        case #selector(focusBrowserAddress), #selector(newBrowserTab): inspector.canShow(.browser) && workspace.can("preview:operate")
        case #selector(newBrowserTabInProfile):
            inspector.canShow(.browser) && workspace.can("preview:operate") && workspace.supportsServerBrowser
        case #selector(zoomBrowserIn): canZoomBrowser(.increase)
        case #selector(zoomBrowserOut): canZoomBrowser(.decrease)
        case #selector(resetBrowserZoom): canZoomBrowser(.actualSize)
        case #selector(startBrowserRecording): inspector.canStartBrowserRecording
        case #selector(stopBrowserRecording): inspector.canStopBrowserRecording
        case #selector(stopAllBrowserRecordings): inspector.canStopAllBrowserRecordings
        case #selector(previewLatestBrowserRecording): inspector.hasLatestBrowserRecording
        case #selector(captureBrowserScreenshot): inspector.canCaptureBrowserScreenshot
        case #selector(annotateBrowserRegion): inspector.canAnnotateBrowserRegion
        case #selector(previewLatestBrowserScreenshot): inspector.hasLatestBrowserScreenshot
        case #selector(showTerminal): rail.terminalButton.isEnabled
        case #selector(sendNextQueuedMessage): page == .conversation && focusedConversation.canSendNextQueuedMessage
        case #selector(findInThread): canUseFindShortcut
        case #selector(findNext), #selector(findPrevious): canUseFindShortcut && focusedConversation.canStepFind
        case #selector(editLastMessage): page == .conversation && focusedConversation.canEditLastMessage
        case #selector(toggleDictation): page == .conversation && focusedConversation.canToggleDictation
        case #selector(showArchive): workspace.connection == .ready
        case #selector(showSourceControl): workspace.repository != nil
        case #selector(showBranches): conversation.canChooseBranch
        case #selector(checkoutPullRequest): workspace.repository.map { workspace.canChangeRepository($0) } == true &&
            workspace.can("orchestration:operate")
        default: true
        }
    }

    @objc private func saveWorkspaceFile() { inspector.saveCurrentFile() }

    @objc private func toggleSidebar() {
        guard let item = sidebarItem else { return }
        item.isCollapsed.toggle()
        rail.sidebarButton.isMarked = !item.isCollapsed
        if sideChatPresented { fitAuxiliaryPane(356) }
        else if relationshipsPresented { fitAuxiliaryPane(318) }
    }
    @objc private func focusSearch() {
        if page == .pullRequests { pullRequests.focusSearch(); return }
        if sidebarItem?.isCollapsed == true { toggleSidebar() }
        sidebar.focusSearch()
    }

    @objc private func toggleActivity() {
        if sidebarItem?.isCollapsed == true { toggleSidebar() }
        sidebar.toggleActivity()
    }

    private var canUseFindShortcut: Bool {
        guard page == .conversation, window.isKeyWindow, focusedConversation.canFindInThread, !conversation.terminalHasFocus else {
            return false
        }
        if inspectorItem?.isCollapsed == false, let responder = window.firstResponder as? NSView,
           responder.isDescendant(of: inspector.view) { return false }
        return true
    }

    private var focusedConversation: ConversationController {
        sideChatPresented && sideChats.conversation.containsFocus ? sideChats.conversation : conversation
    }

    @objc private func findInThread() { if canUseFindShortcut { focusedConversation.findInThread() } }
    @objc private func findNext() { if canUseFindShortcut { focusedConversation.stepFind(1) } }
    @objc private func findPrevious() { if canUseFindShortcut { focusedConversation.stepFind(-1) } }
    @objc private func editLastMessage() { if page == .conversation { focusedConversation.editLastMessage() } }
    @objc private func toggleDictation() { if page == .conversation { focusedConversation.toggleDictation() } }
    @objc private func openGuestShare() { if page == .conversation { focusedConversation.openGuestShare() } }
    @objc private func newSideChat() { if page == .conversation { conversation.startSideChat() } }
    @objc private func showFiles() { toggleInspector(.files) }
    @objc private func showChanges() { toggleInspector(.changes) }
    @objc private func toggleBrowser() { toggleInspector(.browser) }
    @objc private func toggleDevice() { toggleInspector(.device) }
    @objc private func focusBrowserAddress() {
        showInspector(.browser)
        inspector.focusBrowserAddress()
    }
    @objc private func newBrowserTab() {
        showInspector(.browser)
        inspector.newBrowserTab()
    }
    @objc private func newBrowserTabInProfile() {
        showInspector(.browser)
        inspector.showBrowserProfiles()
    }
    private func canZoomBrowser(_ direction: BrowserZoom.Direction) -> Bool {
        page == .conversation && inspectorItem?.isCollapsed == false && inspector.selectedTab == .browser &&
            inspector.canZoomBrowser(direction)
    }
    @objc private func zoomBrowserIn() { if canZoomBrowser(.increase) { inspector.zoomBrowser(.increase) } }
    @objc private func zoomBrowserOut() { if canZoomBrowser(.decrease) { inspector.zoomBrowser(.decrease) } }
    @objc private func resetBrowserZoom() { if canZoomBrowser(.actualSize) { inspector.zoomBrowser(.actualSize) } }
    @objc private func startBrowserRecording() { inspector.startBrowserRecording() }
    @objc private func stopBrowserRecording() { inspector.stopBrowserRecording() }
    @objc private func stopAllBrowserRecordings() { inspector.stopAllBrowserRecordings() }
    @objc private func previewLatestBrowserRecording() { inspector.previewLatestBrowserRecording() }
    @objc private func captureBrowserScreenshot() { inspector.captureBrowserScreenshot() }
    @objc private func annotateBrowserRegion() { inspector.annotateBrowserRegion() }
    @objc private func previewLatestBrowserScreenshot() { inspector.previewLatestBrowserScreenshot() }
    @objc private func showTerminal() {
        showWorkspace()
        conversation.toggleTerminal()
    }
    @objc private func showArchive() {
        showWorkspace()
        workspace.showArchive(!workspace.isShowingArchive)
    }

    @objc private func sendNextQueuedMessage() {
        if page == .conversation { focusedConversation.sendNextQueuedMessage() }
    }

    @objc private func showSourceControl() {
        showWorkspace()
        conversation.showSourceControl()
    }

    @objc private func showBranches() {
        showWorkspace()
        conversation.showBranches()
    }

    @objc private func checkoutPullRequest() {
        showWorkspace()
        conversation.showPullRequestCheckout()
    }

    @objc private func showScheduled() { showPage(.scheduled) }
    @objc private func showPullRequests() { showPage(.pullRequests) }
    @objc private func showUsage() { showPage(.usage) }
    private func showWorkspace() { showPage(.conversation) }

    private func showPage(_ destination: WorkspacePage) {
        guard destination != page else { return }
        let previous = controller(for: page)
        if page == .pullRequests { pullRequests.setPresented(false) }
        if page == .usage { usage.setPresented(false) }
        let next = controller(for: destination)
        if next.parent == nil {
            workspaceContent.addChild(next)
            fill(next.view, in: pageContent)
        }
        page = destination
        dismissViewedNotifications()
        if destination != .conversation {
            workspace.hideSideChat()
            hideRelatedConversations()
        }
        if destination != .conversation, let item = inspectorItem, !item.isCollapsed {
            item.isCollapsed = true
            inspector.hide()
            markInspector(nil)
        }
        conversation.setWorkspaceVisible(destination == .conversation)
        previous.view.isHidden = true
        next.view.isHidden = false
        sidebar.setPage(destination)
        rail.usageButton.isMarked = destination == .usage
        if destination == .scheduled { scheduled.sync() }
        if destination == .pullRequests { pullRequests.setPresented(true) }
        if destination == .usage {
            usage.onBack = { [weak self] in self?.showWorkspace() }
            usage.onManageHubs = { [weak self] in self?.openUsageSettings() }
            usage.setPresented(true)
        }
        window.makeFirstResponder(nil)
    }

    private func controller(for page: WorkspacePage) -> NSViewController {
        switch page {
        case .conversation: conversation
        case .scheduled: scheduled
        case .pullRequests: pullRequests
        case .usage: usage
        }
    }

    @objc private func openQuickOpen() { openPalette(.all) }
    @objc private func searchConversations() { openPalette(.conversations) }
    @objc private func findWorkspaceFiles() { openPalette(.files) }
    @objc private func findWorkspaceContents() { openPalette(.contents) }

    private func paletteController() -> QuickOpen {
        if let quickOpen { return quickOpen }
        let panel = QuickOpen(workspace: workspace)
        panel.onOpenMessage = { [weak self] result, query, scope in self?.openMessageSearchResult(result, query: query, scope: scope) }
        panel.onOpenFile = { [weak self] reference, scope in
            guard let self, workspace.fileSearchScope == scope else { return }
            showInspector(.files, opening: reference)
        }
        quickOpen = panel
        return panel
    }

    private func openMessageSearchResult(_ result: MessageSearchResult, query: String, scope: MessageSearchScope) {
        guard workspace.messageSearchScope == scope else { return }
        showWorkspace()
        perform {
            try await self.workspace.openRelatedThread(result.hit.threadID, activeOnly: true)
            guard self.workspace.messageSearchScope == scope else { return }
            self.conversation.openMessageSearchResult(result, query: query, scope: scope)
        }
    }

    private func openPalette(_ mode: QuickOpen.Mode) {
        let palette = paletteController()
        if mode == .files || mode == .contents {
            palette.open([], mode: mode, over: window)
            return
        }
        if mode == .conversations {
            palette.open(paletteThreadEntries(), mode: mode, over: window)
            return
        }
        var entries: [QuickOpen.Entry] = [
            .init(name: "Pair Environment…", detail: "Connection", icon: "plus.circle") { [weak self] in self?.pairEnvironment() },
            .init(name: "T3 Connect…", detail: "Linked environments", icon: "globe") { [weak self] in self?.openT3Connect() },
            .init(name: "Sharing & Access…", detail: "Pairing links and clients", icon: "lock.shield") { [weak self] in self?.openSharingAccess() },
            .init(name: "Settings…", detail: "T3 Code", icon: "gearshape") { [weak self] in self?.openSettings() },
            .init(name: "Provider Settings…", detail: "Agent runtimes", icon: "cpu") { [weak self] in self?.openProviderSettings() },
            .init(name: "Notification Settings…", detail: "Conversation alerts", icon: "bell") { [weak self] in self?.openNotificationSettings() },
            .init(name: "Scheduled Tasks", detail: "⌘⌥4", icon: "clock") { [weak self] in self?.showScheduled() },
            .init(name: "Pull Requests", detail: "⌘⌥5", icon: "arrow.triangle.pull") { [weak self] in self?.showPullRequests() },
            .init(name: "Usage", detail: "⌘⌥6", icon: "chart.bar") { [weak self] in self?.showUsage() },
            .init(name: "Usage Settings…", detail: "CLIProxyAPI hubs", icon: "chart.bar") { [weak self] in self?.openUsageSettings() },
            .init(name: "Device Settings…", detail: "Simulator and emulator hosts", icon: "iphone") { [weak self] in self?.openDeviceSettings() },
            .init(name: "Browser Settings…", detail: "Profiles, display and search", icon: "globe") { [weak self] in self?.openBrowserSettings() },
            .init(name: "Voice Settings…", detail: "Dictation and speech models", icon: "mic") { [weak self] in self?.openVoiceSettings() },
        ]
        if page == .conversation && focusedConversation.canFindInThread {
            entries.append(.init(name: "Find in Thread…", detail: "⌘F", icon: "magnifyingglass") { [weak self] in
                self?.focusedConversation.findInThread()
            })
        }
        if page == .conversation && focusedConversation.canEditLastMessage {
            entries.append(.init(name: "Edit Last Message…", detail: "Rewind conversation", icon: "pencil") { [weak self] in
                self?.editLastMessage()
            })
        }
        if page == .conversation && focusedConversation.canToggleDictation {
            entries.append(.init(name: "Dictate Message", detail: "⌘⇧D", icon: "mic") { [weak self] in self?.toggleDictation() })
        }
        if page == .conversation && focusedConversation.canOpenGuestShare {
            entries.append(.init(name: "Share with Guest…", detail: "Current conversation", icon: "person.2") { [weak self] in
                self?.openGuestShare()
            })
        }
        if page == .conversation, workspace.sideChatParent != nil {
            entries.append(.init(name: "New Side Chat", detail: "Conversation", icon: "bubble.left.and.bubble.right") {
                [weak self] in self?.newSideChat()
            })
        }
        if page == .conversation, workspace.threadRelationshipScope != nil {
            entries.append(.init(name: "Related Conversations…", detail: "Current conversation", icon: "arrow.triangle.branch") {
                [weak self] in self?.showRelatedConversations()
            })
        }
        if page == .conversation, inspector.canShow(.device) {
            entries.append(.init(name: "Device", detail: "⌘⌥7", icon: "iphone") { [weak self] in self?.showInspector(.device) })
        }
        if page == .conversation, inspector.canShow(.browser), workspace.can("preview:operate") {
            entries.append(.init(name: "New Browser Tab", detail: "⌘T", icon: "plus") { [weak self] in self?.newBrowserTab() })
            if workspace.supportsServerBrowser {
                entries.append(.init(name: "New Browser Tab in Profile…", detail: "Browser", icon: "person.crop.circle") {
                    [weak self] in self?.newBrowserTabInProfile()
                })
            }
        }
        if page == .conversation, inspector.canShowBrowserDisplayOptions {
            entries.append(.init(name: "Browser Display Options…", detail: "Viewport, zoom and page appearance", icon: "rectangle.inset.filled") {
                [weak self] in self?.inspector.showBrowserDisplayOptions()
            })
        }
        if inspector.canStartBrowserRecording {
            entries.append(.init(name: "Start Browser Recording", detail: "Current browser tab", icon: "record.circle") {
                [weak self] in self?.startBrowserRecording()
            })
        }
        if inspector.canStopBrowserRecording {
            entries.append(.init(name: "Stop Browser Recording", detail: "Browser", icon: "stop.circle") { [weak self] in
                self?.stopBrowserRecording()
            })
        }
        if inspector.canStopAllBrowserRecordings {
            entries.append(.init(name: "Stop All Browser Recordings", detail: "Browser", icon: "stop.circle") {
                [weak self] in self?.stopAllBrowserRecordings()
            })
        }
        if inspector.hasLatestBrowserRecording {
            entries.append(.init(name: "Latest Browser Recording…", detail: "Playback and export", icon: "play.rectangle") {
                [weak self] in self?.previewLatestBrowserRecording()
            })
        }
        if inspector.canCaptureBrowserScreenshot {
            entries.append(.init(name: "Take Browser Screenshot", detail: "Current browser viewport", icon: "camera") {
                [weak self] in self?.captureBrowserScreenshot()
            })
        }
        if inspector.canAnnotateBrowserRegion {
            entries.append(.init(name: "Annotate Browser Region…", detail: "Attach a selected area and note", icon: "viewfinder") {
                [weak self] in self?.annotateBrowserRegion()
            })
        }
        if inspector.hasLatestBrowserScreenshot {
            entries.append(.init(name: "Latest Browser Screenshot…", detail: "Preview and export", icon: "photo") {
                [weak self] in self?.previewLatestBrowserScreenshot()
            })
        }
        if page == .conversation, let thread = workspace.selectedThread {
            entries += workspace.data.sideChats(of: thread.id).map { child in
                .init(name: child.title, detail: "Side chat · \(thread.title)", icon: "bubble.left.and.bubble.right") { [weak self] in
                    _ = self?.openSideChatLink(child.id)
                }
            }
        }
        if workspace.can("orchestration:operate") {
            entries.insert(contentsOf: [
                .init(name: "New Thread", detail: "⌘N", icon: "square.and.pencil") { [weak self] in self?.newThread() },
                .init(name: "Add Project…", detail: "⌘O", icon: "folder.badge.plus") { [weak self] in self?.addProject() },
            ], at: 0)
            if page == .conversation && conversation.canSendNextQueuedMessage {
                entries.append(.init(name: "Send Next Queued Message", detail: "⌘⇧↩", icon: "arrow.up") { [weak self] in
                    self?.sendNextQueuedMessage()
                })
            }
            if let thread = workspace.selectedThread {
                entries.insert(.init(name: thread.archived ? "Restore Thread" : "Archive Thread",
                                     detail: thread.title, icon: "archivebox") { [weak self] in
                    self?.threadAction(thread.id, thread.archived ? "thread.unarchive" : "thread.archive")
                }, at: 2)
                if !thread.archived {
                    entries.insert(.init(name: "Schedule Task…", detail: thread.title, icon: "clock") { [weak self] in
                        self?.threadAction(thread.id, "schedule")
                    }, at: 3)
                }
            }
        }
        if workspace.connection == .ready {
            entries.append(.init(name: "Project Settings…", detail: "Projects", icon: "folder") { [weak self] in
                self?.openProjectSettings()
            })
            if let target = workspace.projectActionTarget, let project = workspace.selectedProject {
                entries += workspace.projectActions(project).map { action in
                    .init(name: "Run \(action.draft.name)", detail: "Project Action", icon: action.draft.icon.symbol) { [weak self] in
                        self?.showWorkspace()
                        self?.conversation.runProjectAction(action, target: target)
                    }
                }
            }
            if let target = workspace.repository {
                entries.append(.init(name: "Source Control…", detail: "⌘⌥G", icon: "arrow.triangle.branch") { [weak self] in
                    self?.showSourceControl()
                })
                if conversation.canChooseBranch {
                    entries.append(.init(name: "Choose Branch…", detail: "⌘⌥B", icon: "arrow.triangle.branch") { [weak self] in
                        self?.showBranches()
                    })
                }
                if workspace.canChangeRepository(target) && workspace.can("orchestration:operate") {
                    entries.append(.init(name: "Thread from Pull Request…", detail: target.project.name,
                                         icon: "arrow.triangle.pull") { [weak self] in self?.checkoutPullRequest() })
                }
            }
            if inspector.canShow(.browser) {
                entries.append(.init(name: "Browser", detail: "⌘⌥3", icon: "globe") { [weak self] in self?.showInspector(.browser) })
            }
            if workspace.fileSearchScope != nil {
                entries.append(.init(name: "Find Files…", detail: "Current checkout", icon: "doc") { [weak self] in
                    self?.findWorkspaceFiles()
                })
                entries.append(.init(name: "Find in Files…", detail: "Current checkout", icon: "magnifyingglass") { [weak self] in
                    self?.findWorkspaceContents()
                })
            }
            entries.append(.init(name: "Toggle Activity Filter", detail: "Sidebar", icon: "waveform.path") {
                [weak self] in self?.toggleActivity()
            })
            entries.append(.init(name: workspace.isShowingArchive ? "All Threads" : "Archive", detail: "View", icon: "archivebox") {
                [weak self] in self?.showArchive()
            })
            entries += workspace.data.orderedProjects.filter { !$0.archived }.map { project in
                .init(name: project.name, detail: "Project", icon: "folder", kind: .project) { [weak self] in
                    self?.workspace.showArchive(false)
                    self?.workspace.select(.project(project.id))
                    self?.showWorkspace()
                }
            }
            entries += paletteThreadEntries()
        }
        palette.open(entries, mode: mode, over: window)
    }

    private func paletteThreadEntries() -> [QuickOpen.Entry] {
        guard workspace.can("orchestration:read") else { return [] }
        let threads = workspace.isShowingArchive ? workspace.data.archived : workspace.data.threads
        return threads.values.filter(workspace.data.isListed).sorted { $0.updatedAt > $1.updatedAt }.map { thread in
            let keywords = [thread.branch, thread.model["model"].string].compactMap { $0 } +
                thread.pullRequests.flatMap { [$0.repository, "#\($0.number)"] }
            return .init(name: thread.title, detail: workspace.data.projects[thread.projectId]?.name ?? "Thread", icon: "bubble.left",
                         kind: .thread(thread.id), keywords: keywords) { [weak self] in
                guard let self else { return }
                workspace.select(.thread(thread.id))
                showWorkspace()
            }
        }
    }

    private func toggleInspector(_ tab: InspectorController.Tab) {
        guard let item = inspectorItem else { return }
        if !sideChatPresented, !relationshipsPresented, !item.isCollapsed, inspector.selectedTab == tab {
            item.isCollapsed = true
            inspector.hide()
            markInspector(nil)
        } else {
            showInspector(tab)
        }
    }

    private func showInspector(_ tab: InspectorController.Tab, opening reference: WorkspaceFileReference? = nil) {
        guard let item = inspectorItem, inspector.canShow(tab) else { return }
        showWorkspace()
        workspace.hideSideChat()
        hideRelatedConversations()
        item.isCollapsed = false
        inspector.show(tab, opening: reference)
        markInspector(tab)
    }

    private func markInspector(_ tab: InspectorController.Tab?) {
        rail.filesButton.isMarked = tab == .files
        conversation.markInspector(tab)
    }

    private func openSideChatLink(_ id: String) -> Bool {
        guard let reference = workspace.sideChatReference(to: id) else { return false }
        guard let parent = workspace.data.threads[reference.parentID] ?? workspace.data.archived[reference.parentID] else {
            showError("The main conversation is unavailable.")
            return true
        }
        showWorkspace()
        if workspace.selectedThread?.id != parent.id {
            workspace.showArchive(parent.archived)
            workspace.select(.thread(parent.id))
        }
        if workspace.presentSideChat(reference) { sideChats.conversation.focusComposer() }
        return true
    }

    private func syncSideChatPane(_ change: Workspace.Change) {
        guard let item = inspectorItem else { return }
        if page == .conversation, workspace.sideChat != nil {
            if !sideChatPresented {
                hideRelatedConversations()
                if sideChats.parent == nil { installSideChatPane() }
                inspector.hide()
                inspector.view.isHidden = true
                markInspector(nil)
                sideChatPresented = true
                sideChats.view.isHidden = false
                sideChats.conversation.setWorkspaceVisible(true)
                item.minimumThickness = 356
                item.preferredThicknessFraction = 0.35
                fitAuxiliaryPane(356)
                item.isCollapsed = false
                conversation.markSideChat(true)
                sideChats.render(.all)
            } else {
                sideChats.render(change)
            }
        } else if sideChatPresented {
            sideChatPresented = false
            sideChats.conversation.setWorkspaceVisible(false)
            sideChats.view.isHidden = true
            inspector.view.isHidden = false
            item.isCollapsed = true
            item.minimumThickness = 240
            item.preferredThicknessFraction = 0.28
            window.contentMinSize = NSSize(width: 690, height: 520)
            conversation.markSideChat(false)
        }
    }

    private func installSideChatPane() {
        auxiliaryContent.addChild(sideChats)
        fill(sideChats.view, in: auxiliaryContent.view)
        sideChats.onSelect = { [weak self] id in _ = self?.openSideChatLink(id) }
        sideChats.onClose = { [weak self] in self?.closeSideChat() }
        sideChats.conversation.onError = conversation.onError
        sideChats.conversation.onShowUsageLimits = conversation.onShowUsageLimits
        sideChats.conversation.onVoiceSettings = conversation.onVoiceSettings
        sideChats.conversation.onOpenCitation = conversation.onOpenCitation
        sideChats.conversation.onOpenSideChat = conversation.onOpenSideChat
        sideChats.conversation.onOpenWorkspaceFile = { [weak self] reference, context in
            guard let self, workspace.sideChat?.threadID == context.threadID,
                  workspace.environment?.id == context.environmentID, workspace.workspacePath == context.root else { return }
            showInspector(.files, opening: reference)
        }
    }

    private func fitAuxiliaryPane(_ paneWidth: CGFloat) {
        let sidebarWidth = sidebarItem?.isCollapsed == false ? 211.0 : 0
        let width = WorkspaceStyle.railWidth + sidebarWidth + 420 + paneWidth + 4
        window.contentMinSize = NSSize(width: width, height: 520)
        guard window.frame.width < width else { return }
        var frame = window.frame
        frame.size.width = width
        if let visible = window.screen?.visibleFrame {
            frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - width))
        }
        window.setFrame(frame, display: true)
    }

    @objc private func showRelatedConversations() {
        guard page == .conversation, workspace.threadRelationshipScope != nil, let item = inspectorItem else { return }
        if relationshipsPresented {
            hideRelatedConversations()
            return
        }
        workspace.hideSideChat()
        inspector.hide()
        inspector.view.isHidden = true
        markInspector(nil)
        if relationships.parent == nil {
            auxiliaryContent.addChild(relationships)
            fill(relationships.view, in: auxiliaryContent.view)
            relationships.onClose = { [weak self] in self?.hideRelatedConversations() }
            relationships.onOpen = { [weak self] target in self?.openRelationship(target) }
        }
        relationshipsPresented = true
        relationships.view.isHidden = false
        item.minimumThickness = 318
        item.preferredThicknessFraction = 0.31
        fitAuxiliaryPane(318)
        item.isCollapsed = false
        window.contentView?.layoutSubtreeIfNeeded()
        let width = split.splitView.bounds.width
        let paneWidth = min(380, max(318, width * 0.31))
        split.splitView.setPosition(width - paneWidth, ofDividerAt: split.splitViewItems.count - 2)
        relationships.setPresented(true)
    }

    private func hideRelatedConversations() {
        guard relationshipsPresented, let item = inspectorItem else { return }
        relationshipsPresented = false
        relationships.setPresented(false)
        relationships.view.isHidden = true
        inspector.view.isHidden = false
        item.isCollapsed = true
        item.minimumThickness = 240
        item.preferredThicknessFraction = 0.28
        window.contentMinSize = NSSize(width: 690, height: 520)
    }

    private func openRelationship(_ target: RelatedThreadTarget) {
        guard let scope = workspace.threadRelationshipScope else { return }
        guard let environmentID = target.environmentID, environmentID != workspace.currentServerID else {
            if !openSideChatLink(target.threadID) {
                perform { try await self.workspace.openRelatedThread(target.threadID) }
            }
            return
        }
        perform {
            let destination = try await self.resolveRelatedEnvironment(environmentID)
            guard self.workspace.threadRelationshipScope == scope else { return }
            self.hideRelatedConversations()
            self.workspace.connect(to: destination, opening: target)
        }
    }

    private func openCitation(_ citation: AssistantCitation) {
        pendingCitation = nil
        showWorkspace()
        if workspace.currentServerID == citation.environmentID {
            perform {
                if !self.openSideChatLink(citation.threadID) {
                    try await self.workspace.openRelatedThread(citation.threadID)
                }
                self.revealCurrentCitation(citation)
            }
            return
        }
        let connection = workspace.connectionID
        let selection = workspace.selection
        perform {
            let destination = try await self.resolveRelatedEnvironment(citation.environmentID)
            guard self.workspace.connectionID == connection, self.workspace.selection == selection else { return }
            self.pendingCitation = (citation, destination.id)
            self.workspace.connect(to: destination, opening: .init(threadID: citation.threadID, environmentID: citation.environmentID))
        }
    }

    private func advanceCitationNavigation() {
        guard let pendingCitation else { return }
        if workspace.environment?.id != pendingCitation.environmentID || workspace.connection == .needsPairing || page != .conversation {
            self.pendingCitation = nil
            return
        }
        guard workspace.connection == .ready, workspace.currentServerID == pendingCitation.citation.environmentID,
              let selected = workspace.selectedThread else { return }
        self.pendingCitation = nil
        if selected.id == pendingCitation.citation.threadID { revealCurrentCitation(pendingCitation.citation) }
    }

    private func revealCurrentCitation(_ citation: AssistantCitation) {
        if sideChatPresented, workspace.sideChat?.threadID == citation.threadID { sideChats.conversation.openCitationSource(citation) }
        else if workspace.selectedThread?.id == citation.threadID { conversation.openCitationSource(citation) }
    }

    private func resolveRelatedEnvironment(_ id: String) async throws -> SavedEnvironment {
        let accountID = connectAccount?.identity?.id
        if let saved = workspace.environments.first(where: {
            $0.canonicalID == id && ($0.relay == nil || $0.relay?.accountID == accountID)
        }) { return saved }
        if let accountID, let relayClient,
           let linked = try? await relayClient.environments(accountID: accountID),
           connectAccount?.identity?.id == accountID,
           let environment = linked.first(where: { $0.canonicalID == id }) { return environment }
        let unresolved = workspace.environments.filter { $0.relay == nil && $0.canonicalID == nil }
        let found = await withTaskGroup(of: SavedEnvironment?.self, returning: SavedEnvironment?.self) { group in
            for saved in unresolved {
                group.addTask {
                    guard let descriptor = try? await EnvironmentAPI(origin: saved.origin).http("/.well-known/t3/environment", timeout: 5),
                          descriptor["environmentId"].string == id else { return nil }
                    var resolved = saved
                    resolved.serverID = id
                    return resolved
                }
            }
            for await result in group {
                if let result { group.cancelAll(); return result }
            }
            return nil
        }
        if let found { return found }
        throw ClientError.message("Connect the related environment in Settings to open this conversation.")
    }

    private func closeSideChat() {
        guard let reference = workspace.sideChat else { return }
        let connection = workspace.connectionID
        workspace.hideSideChat()
        conversation.focusComposer()
        if let connection, workspace.can("orchestration:operate") {
            perform { try await self.workspace.removeSideChat(reference, connection: connection, onlyIfUnused: true) }
        }
    }

    @objc private func openSettings() {
        let controller = settingsController()
        controller.render()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openT3Connect() { settingsController().showT3Connect() }
    @objc private func openSharingAccess() { settingsController().showSharingAccess() }
    @objc private func openProviderSettings() { settingsController().showProviders() }
    @objc private func openNotificationSettings() { settingsController().showNotifications() }
    @objc private func openDeviceSettings() { settingsController().showDevices() }
    @objc private func openBrowserSettings() { settingsController().showBrowser() }
    @objc private func openVoiceSettings() { settingsController().showVoice() }
    @objc private func openUsageSettings() { settingsController().showUsage() }
    @objc private func openProjectSettings() { settingsController().showProjects(workspace.selectedProject?.id) }

    private func settingsController() -> SettingsController {
        if let settings { return settings }
        let controller = SettingsController(workspace: workspace, account: connectAccount, relay: relayClient, notifications: notifications)
        controller.onPair = { [weak self] in self?.pairEnvironment() }
        controller.onAddProject = { [weak self] in
            guard let self else { return }
            window.makeKeyAndOrderFront(nil)
            addProject()
        }
        controller.onScheduled = { [weak self] in
            guard let self else { return }
            showScheduled()
            window.makeKeyAndOrderFront(nil)
        }
        controller.onError = { [weak self] message in self?.showError(message) }
        settings = controller
        return controller
    }

    @objc private func pairEnvironment() {
        let alert = NSAlert()
        alert.messageText = "Pair an environment"
        alert.informativeText = "Paste a pairing link from T3 Code, or enter the server address and a pairing code."
        let address = NSTextField()
        address.placeholderString = "Pairing link or server address"
        address.setAccessibilityLabel("Pairing Link or Server Address")
        let code = NSSecureTextField()
        code.placeholderString = "Pairing code (for server address)"
        code.setAccessibilityLabel("Pairing Code")
        let form = column([address, code], spacing: 8, alignment: .width)
        form.frame.size = NSSize(width: 330, height: 58)
        alert.accessoryView = form
        alert.addButton(withTitle: "Pair Environment")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = address
        alert.beginSheetModal(for: NSApp.keyWindow ?? window) { [weak self] result in
            guard let self, result == .alertFirstButtonReturn else { return }
            do { workspace.pair(try PairingTarget(address: address.stringValue, code: code.stringValue)) }
            catch { showError(error.localizedDescription) }
        }
    }

    @objc private func startLocalServer() {
        guard !localServer.isStarting else { return }
        conversation.setStartingLocal(true)
        perform {
            defer { self.conversation.setStartingLocal(false) }
            let target = try await self.localServer.start()
            self.workspace.pair(target, persistent: false)
        }
    }

    @objc private func newThread() {
        guard workspace.can("orchestration:operate") else { return }
        showWorkspace()
        let active = workspace.selectedProject.flatMap { $0.archived ? nil : $0 }
        let project = active ?? workspace.data.projects.values.filter { !$0.archived }.min(by: Project.precedes)
        guard let project else { addProject(); return }
        workspace.showArchive(false)
        workspace.select(.project(project.id))
        conversation.focusComposer()
    }

    @objc private func addProject() {
        guard workspace.can("orchestration:operate"), let scope = workspace.projectOnboardingScope, window.attachedSheet == nil else { return }
        let controller = ProjectOnboardingController(workspace: workspace, scope: scope)
        projectOnboarding = controller
        controller.onClose = { [weak self, weak controller] in
            if self?.projectOnboarding === controller { self?.projectOnboarding = nil }
        }
        controller.onAdded = { [weak self] warning in
            guard let self else { return }
            showWorkspace()
            conversation.focusComposer()
            if let warning { showError(warning) }
        }
        controller.present(in: window)
    }

    private func threadAction(_ id: String, _ command: String) {
        if command == "guest-share" {
            guard workspace.data.threads[id]?.archived == false else { return }
            workspace.showArchive(false)
            workspace.select(.thread(id))
            showWorkspace()
            conversation.openGuestShare()
        } else if command == "schedule", let thread = workspace.data.threads[id] {
            showScheduled()
            scheduled.createTask(fromThread: thread)
        } else if command == "rename", let thread = workspace.data.threads[id] {
            let alert = NSAlert()
            alert.messageText = "Rename thread"
            let name = NSTextField(string: thread.title)
            name.frame.size = NSSize(width: 300, height: 24)
            alert.accessoryView = name
            alert.addButton(withTitle: "Rename Thread")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = name
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self, response == .alertFirstButtonReturn else { return }
                let title = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return }
                perform { try await self.workspace.dispatch("thread.metadata.update", threadId: id, ["title": .string(title)]) }
            }
        } else {
            perform {
                try await self.workspace.dispatch(command, threadId: id)
                if self.workspace.selection == .thread(id), command == "thread.archive" || command == "thread.unarchive" {
                    self.workspace.select(nil)
                }
            }
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await action() }
            catch { showError(error.localizedDescription) }
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "T3 Code"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: NSApp.keyWindow ?? window)
    }
}
