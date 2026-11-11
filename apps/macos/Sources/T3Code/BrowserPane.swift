import AppKit
import UniformTypeIdentifiers

@MainActor
final class BrowserPane: NSViewController, NSTextFieldDelegate {
    private struct Context: Hashable {
        let environmentID: String
        let threadId: String
    }

    private struct PendingInput {
        let payload: Payload
        let generation: Int
    }

    private struct DownloadTarget: Hashable {
        let context: Context
        let tabId: String
    }

    private let workspace: Workspace
    private let tabPicker = NSPopUpButton()
    private let address = NSTextField()
    private let canvas = BrowserCanvas()
    private lazy var recordings: BrowserRecordingController = {
        let controller = BrowserRecordingController(directory: workspace.browserRecordingDirectory)
        controller.onChange = { [weak self] in self?.recordingChanged() }
        controller.onPreview = { [weak self] clip in self?.showRecording(clip) }
        return controller
    }()
    private let controlLabel = label(size: 11, color: WorkspaceStyle.muted)
    private let profileLabel = label(size: 11, color: WorkspaceStyle.muted)
    private let profileIcon = NSImageView()
    private lazy var profileSummary = row([profileIcon, profileLabel], spacing: 4)
    private let placeholder = label(size: 12, color: WorkspaceStyle.muted)
    private let notice = label(size: 11, color: WorkspaceStyle.accent)
    private lazy var previous = tool("Go Back", "chevron.left") { [weak self] in self?.send(["type": .string("history"), "delta": .int(-1)]) }
    private lazy var next = tool("Go Forward", "chevron.right") { [weak self] in self?.send(["type": .string("history"), "delta": .int(1)]) }
    private lazy var reload = tool("Reload", "arrow.clockwise") { [weak self] in self?.reloadPage() }
    private lazy var open = tool("New Browser Tab", "plus") { [weak self] in self?.newTab() }
    private lazy var newTabProfiles: ActionButton = {
        let button = ActionButton("New Browser Tab in Profile", symbol: "chevron.down", iconOnly: true, style: .subtle) {
            [weak self] in self?.showNewTabProfiles()
        }
        button.widthAnchor.constraint(equalToConstant: 16).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }()
    private lazy var close = tool("Close Browser Tab", "xmark") { [weak self] in self?.closeTab() }
    private lazy var displayOptions = tool("Browser Display Options", "rectangle.inset.filled") { [weak self] in self?.showDisplayOptions() }
    private lazy var record = tool("Start Browser Recording", "record.circle") { [weak self] in self?.toggleRecording() }
    private lazy var captureOptions: ActionButton = {
        let button = ActionButton("Browser Capture Options", symbol: "chevron.down", iconOnly: true, style: .subtle) {
            [weak self] in self?.showCaptureOptions()
        }
        button.widthAnchor.constraint(equalToConstant: 16).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }()
    private lazy var take = ActionButton("Take Control", style: .subtle) { [weak self] in self?.toggleControl() }
    private lazy var respond = ActionButton("Respond…", style: .subtle) { [weak self] in self?.answerDialog() }
    private lazy var choose = ActionButton("Choose Files…", style: .subtle) { [weak self] in self?.chooseFiles() }
    private lazy var save = ActionButton("Save Download…", style: .subtle) { [weak self] in self?.saveDownload() }
    private lazy var retry = ActionButton("Try Again", style: .subtle) { [weak self] in self?.retryConnection() }
    private lazy var localServers = tool("Open Local Server", "server.rack") { [weak self] in self?.localServerMenu() }
    private var actions: NSStackView?

    private var context: Context?
    private var tabs = BrowserTabs()
    private var selected: String?
    private var selectionByThread: [Context: String] = [:]
    private var requestedTab: String?
    private var presented = false
    private var eventTask: Task<Void, Never>?
    private var listTask: Task<Void, Never>?
    private var serverTask: Task<Void, Never>?
    private var browserTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var mutation: Task<Void, Never>?
    private var transfer: Task<Void, Never>?
    private var stream: BrowserStream?
    private var streamTab: String?
    private var streamID = UUID()
    private var pendingInput: [PendingInput] = []
    private var control: BrowserControl?
    private var chooser: BrowserFileChooser?
    private var downloads: [DownloadTarget: [BrowserDownload]] = [:]
    private var discovered: [Wire] = []
    private var acceptsClipboard = false
    private var hasFrame = false
    private var latestFrame: CGImage?
    private var failed = false
    private var message: String?
    private var renderedAddress: String?
    private var renderedTab: String?
    private var mediaPreview: BrowserMediaPreview?
    private var regionEditor: BrowserRegionEditor?
    private var screenshotTask: Task<Void, Never>?
    private lazy var latestScreenshot = BrowserScreenshot.latest(in: workspace.browserScreenshotDirectory)
    private var finishingCaptureBeforeQuit = false

    var onReveal: (() -> Void)?
    var onManageProfiles: (() -> Void)? { didSet { syncBrowserPreferences() } }
    var onRecordingChange: ((Bool) -> Void)?
    var onAttachRecording: ((BrowserRecordingClip) throws -> Void)?
    var onAttachImage: ((PickedAttachment, BrowserTabTarget?) throws -> Void)?
    var onCaptureError: ((String) -> Void)?

    private var tab: BrowserTab? { tabs.tabs.first { $0.id == selected } }
    private var canOperate: Bool { context != nil && workspace.can("preview:operate") }
    private var hasControl: Bool { canOperate && control?.canOperate == true && control?.owner == .you }
    private var canAdjustDisplay: Bool { presented && canOperate && tab != nil && mutation == nil }
    var canShowDisplayOptions: Bool { presented && tab != nil }
    private var recordingKey: BrowserTabTarget.Key? {
        guard let context, let selected else { return nil }
        return .init(environmentID: context.environmentID, threadID: context.threadId, tabID: selected)
    }
    private var tabRecordingPhase: BrowserRecordingController.Phase { recordings.phase(for: recordingKey) }
    private var stopRecordingKey: BrowserTabTarget.Key? {
        if let recordingKey, tabRecordingPhase == .starting || tabRecordingPhase == .recording { return recordingKey }
        let targets = recordings.stoppableTargets
        return targets.count == 1 ? targets.first?.key : nil
    }
    private var hasCapturableFrame: Bool {
        presented && canOperate && tab != nil && stream != nil && streamTab == selected && latestFrame != nil && !failed
    }
    var canStartRecording: Bool { hasCapturableFrame && tabRecordingPhase == .idle }
    var canCaptureScreenshot: Bool { hasCapturableFrame && screenshotTask == nil && regionEditor == nil }
    var canAnnotateRegion: Bool {
        hasCapturableFrame && onAttachImage != nil && workspace.can("orchestration:operate") &&
            regionEditor == nil && screenshotTask == nil
    }
    var hasLatestScreenshot: Bool { latestScreenshot != nil }
    var canStopRecording: Bool { stopRecordingKey != nil }
    var canStopAllRecordings: Bool { recordings.stoppableTargets.count > 1 }
    var hasPendingCapture: Bool { recordings.isBusy || screenshotTask != nil }
    var hasLatestRecording: Bool { recordings.latest != nil }
    private var downloadTarget: DownloadTarget? {
        guard let context, let selected else { return nil }
        return DownloadTarget(context: context, tabId: selected)
    }

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView()
        tabPicker.setAccessibilityLabel("Browser Tabs")
        tabPicker.target = self
        tabPicker.action = #selector(pickedTab)
        tabPicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        address.placeholderString = "Address or search"
        address.setAccessibilityLabel("Browser Address")
        address.target = self
        address.action = #selector(submitAddress)
        address.delegate = self
        address.usesSingleLineMode = true
        address.lineBreakMode = .byTruncatingMiddle
        address.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let tabBar = row([tabPicker, row([open, newTabProfiles], spacing: 0), close, localServers], spacing: 3)
        let navigation = row([previous, next, reload, address], spacing: 3)

        let page = Surface(WorkspaceStyle.canvas, border: WorkspaceStyle.outline, radius: 7)
        page.heightAnchor.constraint(greaterThanOrEqualToConstant: 105).isActive = true
        fill(canvas, in: page, inset: 1)
        canvas.onSize = { [weak self] _ in self?.scheduleResize() }
        canvas.onInput = { [weak self] input in self?.send(input) }
        canvas.onCopyRequest = { [weak self] in self?.acceptsClipboard = true }
        placeholder.maximumNumberOfLines = 5
        placeholder.lineBreakMode = .byWordWrapping
        placeholder.alignment = .center
        page.addSubview(placeholder)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: page.centerYAnchor),
            placeholder.leadingAnchor.constraint(greaterThanOrEqualTo: page.leadingAnchor, constant: 12),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: page.trailingAnchor, constant: -12),
        ])

        notice.maximumNumberOfLines = 4
        notice.lineBreakMode = .byWordWrapping
        let actionRow = row([respond, choose, save, retry, NSView()], spacing: 5)
        actions = actionRow
        profileIcon.contentTintColor = WorkspaceStyle.muted
        profileIcon.setAccessibilityElement(false)
        profileIcon.widthAnchor.constraint(equalToConstant: 12).isActive = true
        profileIcon.heightAnchor.constraint(equalToConstant: 12).isActive = true
        let footer = row([controlLabel, NSView(), profileSummary, take, displayOptions,
                          row([record, captureOptions], spacing: 0)], spacing: 6)
        fill(column([tabBar, navigation, page, notice, actionRow, footer], spacing: 6, alignment: .width), in: view)
        render()
    }

    func setPresented(_ visible: Bool) {
        guard visible != presented else { return }
        presented = visible
        if visible {
            _ = view
            sync()
            watchLocalServers()
            updateStream()
        } else {
            stopStream()
            serverTask?.cancel()
            serverTask = nil
            discovered = []
        }
        render()
    }

    func sync() {
        recordings.sync(connection: workspace.connectionID)
        let nextContext: Context?
        if workspace.can("orchestration:read"), let environmentID = workspace.environment?.id,
           case .thread(let id) = workspace.selection { nextContext = Context(environmentID: environmentID, threadId: id) }
        else { nextContext = nil }
        guard context != nextContext else { syncBrowserPreferences(); return }
        stopStream()
        eventTask?.cancel()
        listTask?.cancel()
        mutation?.cancel()
        transfer?.cancel()
        serverTask?.cancel()
        eventTask = nil
        listTask = nil
        mutation = nil
        transfer = nil
        serverTask = nil
        context = nextContext
        tabs = BrowserTabs()
        selected = nil
        requestedTab = nextContext.flatMap { selectionByThread[$0] }
        discovered = []
        message = nil
        failed = false
        if let nextContext { observe(nextContext) }
        if presented { watchLocalServers() }
        render()
    }

    func shutdown() {
        stopStream()
        eventTask?.cancel()
        listTask?.cancel()
        serverTask?.cancel()
        mutation?.cancel()
        transfer?.cancel()
        screenshotTask?.cancel()
        mediaPreview?.close()
    }

    private func observe(_ context: Context) {
        eventTask?.cancel()
        eventTask = Task {
            do {
                try await workspace.subscribe("subscribePreviewEvents", [:], onSubscribe: {
                    self.loadTabs()
                }) { frames in
                    guard self.context == context else { return }
                    var reveal: String?
                    var changed = false
                    for frame in frames {
                        switch tabs.apply(frame, threadId: context.threadId) {
                        case .ignored: break
                        case .refresh: loadTabs()
                        case .changed(let requested):
                            changed = true
                            reveal = requested ?? reveal
                        }
                    }
                    if let reveal { requestedTab = reveal }
                    if changed && tabs.loaded { syncSelection() }
                    if reveal != nil { onReveal?() }
                }
                throw ClientError.disconnected
            } catch {
                guard !Task.isCancelled, self.context == context else { return }
                eventTask = nil
                message = "The browser tab list is disconnected. \(error.localizedDescription)"
                failed = true
                render()
            }
        }
    }

    private func loadTabs(selecting id: String? = nil) {
        guard let context, let connection = workspace.connectionID else { return }
        if let id { requestedTab = id }
        if listTask != nil && id == nil { return }
        listTask?.cancel()
        listTask = Task {
            defer { if !Task.isCancelled, self.context == context { listTask = nil } }
            do {
                try await reconcileTabs(context, connection: connection)
            } catch {
                guard !Task.isCancelled, self.context == context, workspace.connectionID == connection else { return }
                message = error.localizedDescription
                failed = true
                render()
            }
        }
    }

    private func reconcileTabs(_ context: Context, connection: UUID) async throws {
        for _ in 0..<4 {
            guard !Task.isCancelled, self.context == context, workspace.connectionID == connection else { return }
            let snapshot = try await workspace.request("preview.list", ["threadId": .string(context.threadId)])
            guard !Task.isCancelled, self.context == context, workspace.connectionID == connection else { return }
            if try tabs.reconcile(snapshot) {
                syncSelection()
                return
            }
        }
        throw ClientError.message("Browser tabs changed while loading. Try again.")
    }

    private func syncSelection() {
        let ids = tabs.tabs.map(\.id)
        if let requestedTab, ids.contains(requestedTab) {
            selected = requestedTab
            self.requestedTab = nil
        } else if selected.map(ids.contains) != true { selected = ids.last }
        if let context, let selected { selectionByThread[context] = selected }
        if let context {
            downloads = downloads.filter { $0.key.context != context || ids.contains($0.key.tabId) }
        }
        updateStream()
        render()
    }

    private func watchLocalServers() {
        guard presented, let context, serverTask == nil else { return }
        serverTask = Task {
            try? await workspace.subscribe("subscribeDiscoveredLocalServers", [:]) { frames in
                guard self.context == context, presented, let frame = frames.last else { return }
                discovered = frame["servers"].array
                render()
            }
        }
    }

    private func updateStream() {
        let target = presented ? tab?.id : nil
        guard target != streamTab else { return }
        stopStream()
        guard let target, let context else { return }
        streamTab = target
        message = nil
        failed = false
        let streamID = self.streamID
        browserTask = Task { [weak self, workspace] in
            var attempts = 0
            while !Task.isCancelled {
                do {
                    let api = try workspace.browserAPI(for: context.environmentID)
                    let client = try await api.browserStream(threadId: context.threadId, tabId: target,
                                                             interactive: workspace.can("preview:operate"))
                    guard !Task.isCancelled, self?.streamID == streamID else { await client.stop(); return }
                    self?.stream = client
                    try await client.watch { [weak self] event in await self?.receive(event, streamID: streamID) }
                    try Task.checkCancellation()
                    throw BrowserStreamError.disconnected
                } catch {
                    guard !Task.isCancelled, self?.streamID == streamID else { return }
                    switch error {
                    case BrowserStreamError.gone:
                        self?.finishStream(error)
                        self?.loadTabs()
                        return
                    case BrowserStreamError.setup, ClientError.http(401, _), ClientError.http(403, _), ClientError.http(404, _):
                        self?.finishStream(error)
                        return
                    default: break
                    }
                    attempts += 1
                    if attempts >= 3 { self?.finishStream(error); return }
                    self?.resetControl()
                    self?.render()
                    do { try await Task.sleep(for: .milliseconds(450 * attempts)) }
                    catch { return }
                }
            }
        }
    }

    private func finishStream(_ error: any Error) {
        resetControl()
        message = error.localizedDescription
        failed = true
        render()
    }

    private func resetControl() {
        stream = nil
        control = nil
        chooser = nil
        acceptsClipboard = false
        inputTask?.cancel()
        inputTask = nil
        resizeTask?.cancel()
        pendingInput.removeAll()
        canvas.acceptsInput = false
    }

    private func stopStream() {
        streamID = UUID()
        streamTab = nil
        browserTask?.cancel()
        browserTask = nil
        if let stream { Task { await stream.stop() } }
        resetControl()
        hasFrame = false
        latestFrame = nil
        canvas.viewport = .zero
        canvas.display(nil)
    }

    private func receive(_ event: BrowserStream.Event, streamID: UUID) {
        guard self.streamID == streamID else { return }
        switch event {
        case .image(let image):
            latestFrame = image
            canvas.display(image)
            if !hasFrame { hasFrame = true; render() }
        case .viewport(let size): canvas.viewport = size
        case .pointer: break
        case .control(let next):
            let ownershipChanged = control?.generation != next.generation
            control = next
            if ownershipChanged { pendingInput.removeAll(); acceptsClipboard = false }
            canvas.acceptsInput = hasControl
            if hasControl && ownershipChanged { scheduleResize() }
            render()
        case .clipboard(let text):
            if acceptsClipboard && hasControl {
                acceptsClipboard = false
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        case .popup(let id): loadTabs(selecting: id)
        case .fileChooser(let value): chooser = value; render()
        case .fileChooserClosed(let id):
            if chooser?.id == id { chooser = nil; render() }
        case .download(let download):
            if let context, let tabId = streamTab {
                let key = DownloadTarget(context: context, tabId: tabId)
                downloads[key, default: []].removeAll { $0.id == download.id }
                downloads[key, default: []].append(download)
                render()
            }
        }
    }

    private func send(_ payload: Payload) {
        guard let stream, let control, control.canOperate, canOperate,
              payload["type"] == .string("takeControl") || hasControl else { return }
        let input = PendingInput(payload: payload, generation: control.generation)
        let hover = payload["type"] == .string("mouse") && payload["action"] == .string("move") && payload["buttons"] == .int(0)
        if hover, let last = pendingInput.last, last.payload["action"] == .string("move"), last.payload["buttons"] == .int(0) {
            pendingInput[pendingInput.count - 1] = input
            return
        }
        guard pendingInput.count < 256 else {
            if !hover { Task { await stream.stop() } }
            return
        }
        pendingInput.append(input)
        if let recordingKey {
            recordings.observeInput(payload, key: recordingKey, viewport: canvas.viewport)
        }
        guard inputTask == nil else { return }
        inputTask = Task {
            while !Task.isCancelled, !pendingInput.isEmpty {
                let input = pendingInput.removeFirst()
                do { try await stream.send(input.payload, generation: input.generation) }
                catch { await stream.stop(); break }
            }
            if !Task.isCancelled { inputTask = nil }
        }
    }

    private func scheduleResize() {
        resizeTask?.cancel()
        guard hasControl else { return }
        let width = min(3_840, Int(canvas.bounds.width))
        let height = min(2_160, Int(canvas.bounds.height))
        guard width >= 100, height >= 100 else { return }
        resizeTask = Task {
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return }
            send(["type": .string("resize"), "width": .int(width), "height": .int(height)])
        }
    }

    func focusAddress() {
        guard presented, canOperate else { return }
        view.window?.makeFirstResponder(address)
        address.selectText(nil)
    }

    @objc private func pickedTab() {
        guard let id = tabPicker.selectedItem?.representedObject as? String else { return }
        requestedTab = id
        syncSelection()
    }

    @objc private func submitAddress() {
        guard canOperate else { return }
        do {
            let url = try BrowserAddress.resolve(address.stringValue, search: workspace.browserPreferences.search)
            message = nil
            if tab == nil { openTab(url: url) }
            else if hasControl {
                send(["type": .string("navigate"), "url": .string(url)])
                view.window?.makeFirstResponder(canvas)
            } else { message = "Take control of this tab before navigating." }
        } catch { message = error.localizedDescription }
        render()
    }

    func openActionPreview(_ address: String) {
        do { openTab(url: try BrowserAddress.resolve(address, allowsSearch: false)) }
        catch { message = error.localizedDescription; render() }
    }

    func newTab() {
        if presented { openTab(url: nil) }
    }

    func startRecording() {
        guard canStartRecording, let context, let connection = workspace.connectionID, let tab, let latestFrame else { return }
        do {
            let api = try workspace.browserAPI(for: context.environmentID)
            let target = BrowserTabTarget(environmentID: context.environmentID, connection: connection,
                                                threadID: context.threadId, tabID: tab.id, title: tab.displayName)
            message = nil
            recordings.start(target, api: api, image: latestFrame, preferences: workspace.browserPreferences.recording)
        } catch {
            message = error.localizedDescription
            render()
        }
    }

    func stopRecording() {
        if let stopRecordingKey { recordings.stop(stopRecordingKey) }
    }
    func stopAllRecordings() { recordings.stopAll() }
    func previewLatestRecording() { recordings.previewLatest() }
    func finishCaptureBeforeQuit() async {
        finishingCaptureBeforeQuit = true
        await recordings.finishBeforeQuit()
        await screenshotTask?.value
    }

    private func toggleRecording() {
        if let recordingKey, tabRecordingPhase == .starting || tabRecordingPhase == .recording {
            recordings.stop(recordingKey)
        } else {
            startRecording()
        }
    }

    private func recordingChanged() {
        onRecordingChange?(recordings.isBusy)
        render()
    }

    private func showRecording(_ clip: BrowserRecordingClip) {
        let attach = onAttachRecording.map { handler in { try handler(clip) } }
        showMedia(file: clip.file, subject: clip.target?.title, content: .recording, onAttach: attach)
    }

    private func showMedia(file: URL, subject: String?, content: BrowserMediaPreview.Content, onAttach: (() throws -> Void)?) {
        guard !finishingCaptureBeforeQuit else { return }
        mediaPreview?.close()
        let preview = BrowserMediaPreview(file: file, subject: subject, content: content, onAttach: onAttach)
        preview.onClose = { [weak self] in self?.mediaPreview = nil }
        mediaPreview = preview
        preview.present()
    }

    private func captureSnapshot() -> BrowserSnapshot? {
        guard hasCapturableFrame, let context, let connection = workspace.connectionID, let tab, let latestFrame else { return nil }
        let target = BrowserTabTarget(environmentID: context.environmentID, connection: connection,
                                      threadID: context.threadId, tabID: tab.id, title: tab.displayName)
        return BrowserSnapshot(image: latestFrame, target: target, address: tab.url)
    }

    @objc func captureScreenshot() {
        guard canCaptureScreenshot, let snapshot = captureSnapshot() else { return }
        let directory = workspace.browserScreenshotDirectory
        message = nil
        screenshotTask = Task { [weak self] in
            do {
                let screenshot = try await BrowserScreenshot.save(snapshot, in: directory)
                try Task.checkCancellation()
                self?.latestScreenshot = screenshot
                self?.showScreenshot(screenshot, image: snapshot.image)
            } catch {
                if !Task.isCancelled { self?.captureFailed(error.localizedDescription) }
            }
            self?.screenshotTask = nil
            self?.render()
        }
        render()
    }

    @objc func previewLatestScreenshot() {
        guard screenshotTask == nil, let screenshot = latestScreenshot else { return }
        screenshotTask = Task { [weak self] in
            do {
                let image = try await screenshot.loadImage()
                try Task.checkCancellation()
                self?.showScreenshot(screenshot, image: image)
            } catch {
                if !Task.isCancelled { self?.captureFailed(error.localizedDescription) }
            }
            self?.screenshotTask = nil
            self?.render()
        }
        render()
    }

    private func showScreenshot(_ screenshot: BrowserScreenshot, image: CGImage) {
        let attach = onAttachImage.map { handler in { try handler(PickedAttachment(url: screenshot.file), screenshot.target) } }
        showMedia(file: screenshot.file, subject: screenshot.target?.title, content: .screenshot(image), onAttach: attach)
    }

    private func captureFailed(_ error: String) {
        if presented { message = error }
        else { onCaptureError?(error) }
    }

    @objc func annotateRegion() {
        guard canAnnotateRegion, let snapshot = captureSnapshot(), let onAttachImage,
              let window = view.window, window.attachedSheet == nil else { return }
        let editor = BrowserRegionEditor(snapshot: snapshot) { file in try onAttachImage(file, snapshot.target) }
        editor.onClose = { [weak self] in
            self?.regionEditor = nil
            self?.render()
        }
        regionEditor = editor
        editor.present(in: window)
        render()
    }

    private func showCaptureOptions() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let screenshot = menuItem("Take Browser Screenshot", target: self, action: #selector(captureScreenshot))
        screenshot.isEnabled = canCaptureScreenshot
        menu.addItem(screenshot)
        let annotation = menuItem("Annotate Browser Region…", target: self, action: #selector(annotateRegion))
        annotation.isEnabled = canAnnotateRegion
        menu.addItem(annotation)
        let latest = menuItem("Latest Browser Screenshot…", target: self, action: #selector(previewLatestScreenshot))
        latest.isEnabled = hasLatestScreenshot && screenshotTask == nil
        menu.addItem(latest)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: captureOptions.bounds.height), in: captureOptions)
    }

    func showNewTabProfiles() {
        guard presented else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        if canOperate, mutation == nil, workspace.supportsServerBrowser {
            let preferences = workspace.browserPreferences
            for profile in preferences.profiles {
                let item = menuItem(profile.name, target: self, action: #selector(openTabInProfile(_:)))
                item.representedObject = profile.id
                item.image = WorkspaceStyle.symbol(profile.kind == .incognito ? "eye.slash" : "person.crop.circle", size: 11)
                item.state = profile.id == preferences.defaultProfileID ? .on : .off
                item.isEnabled = workspace.clearingBrowserProfileID != profile.id
                menu.addItem(item)
            }
        }
        if onManageProfiles != nil {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(menuItem("Browser Settings…", target: self, action: #selector(manageProfiles)))
        }
        if !menu.items.isEmpty {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: newTabProfiles.bounds.height), in: newTabProfiles)
        }
    }

    @objc private func openTabInProfile(_ item: NSMenuItem) {
        if let id = item.representedObject as? String { openTab(url: nil, profileID: id) }
    }

    @objc private func manageProfiles() { onManageProfiles?() }

    private func openTab(url: String?, profileID: String? = nil) {
        guard canOperate, let context, let connection = workspace.connectionID, mutation == nil else { return }
        let preferences = workspace.browserPreferences
        if let profileID, !workspace.supportsServerBrowser || preferences.profile(profileID) == nil {
            message = "This profile is unavailable. Choose a profile for a new tab."
            render()
            return
        }
        let chosen = workspace.supportsServerBrowser ? profileID ?? preferences.defaultProfileID : nil
        message = nil
        mutation = Task {
            var openedTab: String?
            defer {
                if !Task.isCancelled, self.context == context {
                    mutation = nil
                    render()
                    if url == nil, let openedTab, selected == openedTab { focusAddress() }
                }
            }
            do {
                guard !Task.isCancelled, self.context == context, workspace.connectionID == connection else { return }
                if let chosen, workspace.clearingBrowserProfileID == chosen {
                    throw ClientError.message("Browser data is being cleared for this profile.")
                }
                var input: Payload = ["threadId": .string(context.threadId), "runtime": .string("server")]
                if let url { input["url"] = .string(url) }
                if let chosen { input["profileId"] = .string(chosen) }
                if preferences.display.viewport != .fill { input["viewport"] = preferences.display.viewport.wire }
                let result = try await workspace.request("preview.open", input)
                guard !Task.isCancelled, self.context == context, workspace.connectionID == connection else { return }
                let id = try result.requireString("tabId")
                openedTab = id
                let adjustments = preferences.display.newTabAdjustments
                var adjustmentError: String?
                if !adjustments.isEmpty {
                    do {
                        try await requestDisplayAdjustment(adjustments, tabID: id, context: context)
                    } catch {
                        adjustmentError = "Could not apply the new tab’s display settings. \(error.localizedDescription)"
                    }
                }
                guard !Task.isCancelled, self.context == context, workspace.connectionID == connection else { return }
                requestedTab = id
                listTask?.cancel()
                listTask = nil
                try await reconcileTabs(context, connection: connection)
                if !Task.isCancelled, self.context == context, workspace.connectionID == connection, let adjustmentError {
                    message = adjustmentError
                }
            } catch {
                if !Task.isCancelled, self.context == context, workspace.connectionID == connection {
                    message = error.localizedDescription
                }
            }
        }
        render()
    }

    func syncBrowserPreferences() {
        guard isViewLoaded else { return }
        let preferences = workspace.browserPreferences
        newTabProfiles.isEnabled = onManageProfiles != nil || (canOperate && mutation == nil && workspace.supportsServerBrowser)
        open.isEnabled = canOperate && mutation == nil && workspace.clearingBrowserProfileID != preferences.defaultProfileID
        let tip = workspace.supportsServerBrowser ? "New Browser Tab in \(preferences.defaultProfile.name)" : "New Browser Tab"
        if open.toolTip != tip {
            open.toolTip = tip
            open.setAccessibilityHelp(tip)
        }
        let name: String?
        if let tab {
            if let id = tab.profileID { name = preferences.profile(id)?.name ?? "Custom profile" }
            else if tab.isolatedAgent { name = "Agent session" }
            else { name = workspace.supportsServerBrowser ? BrowserProfile.standard.name : nil }
        } else { name = nil }
        if profileLabel.toolTip != name || profileSummary.isHidden != (name == nil) {
            let privateSession = tab?.profileID == BrowserProfile.incognito.id || tab?.isolatedAgent == true
            profileIcon.image = WorkspaceStyle.symbol(privateSession ? "eye.slash" : "person.crop.circle", size: 11)
            profileLabel.stringValue = name ?? ""
            profileLabel.toolTip = name
            profileSummary.isHidden = name == nil
            profileLabel.setAccessibilityLabel(name.map { "Browser profile \($0)" })
        }
    }

    private func closeTab() {
        guard canOperate, let context, let tab, mutation == nil else { return }
        mutation = Task {
            defer { if !Task.isCancelled, self.context == context { mutation = nil; render() } }
            do {
                _ = try await workspace.request("preview.close", ["threadId": .string(context.threadId), "tabId": .string(tab.id)])
                if !Task.isCancelled, self.context == context { loadTabs() }
            } catch { if !Task.isCancelled, self.context == context { message = error.localizedDescription } }
        }
        render()
    }

    private func reloadPage() {
        if failed { retryConnection() }
        else { send(["type": .string("reload")]) }
    }

    private func retryConnection() {
        guard let context else { return }
        failed = false
        message = nil
        if eventTask == nil { observe(context) }
        else { loadTabs() }
        stopStream()
        updateStream()
        render()
    }

    private func toggleControl() {
        let action = hasControl ? "releaseControl" : "takeControl"
        send(["type": .string(action)])
        message = nil
        render()
    }

    func showDisplayOptions() {
        guard presented, let display = tab?.display else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let viewport = NSMenuItem(title: "Viewport", action: nil, keyEquivalent: "")
        viewport.submenu = BrowserViewportMenu.make(current: display.viewport, enabled: canAdjustDisplay && hasControl,
                                                    target: self, select: #selector(pickViewport(_:)), custom: #selector(editViewport))
        menu.addItem(viewport)

        let zoomMenu = NSMenu(title: "Zoom")
        zoomMenu.autoenablesItems = false
        for zoom in BrowserZoom.levels {
            let item = menuItem(zoom.title, target: self, action: #selector(pickZoom(_:)))
            item.representedObject = zoom
            item.state = display.zoom == zoom ? .on : .off
            item.isEnabled = canAdjustDisplay
            zoomMenu.addItem(item)
        }
        let zoom = NSMenuItem(title: "Zoom", action: nil, keyEquivalent: "")
        zoom.submenu = zoomMenu
        menu.addItem(zoom)

        let appearanceMenu = NSMenu(title: "Page Appearance")
        appearanceMenu.autoenablesItems = false
        for appearance in BrowserPageAppearance.allCases {
            let item = menuItem(appearance.title, target: self, action: #selector(pickAppearance(_:)))
            item.representedObject = appearance
            item.state = display.appearance == appearance ? .on : .off
            item.isEnabled = canAdjustDisplay
            appearanceMenu.addItem(item)
        }
        let appearance = NSMenuItem(title: "Page Appearance", action: nil, keyEquivalent: "")
        appearance.submenu = appearanceMenu
        menu.addItem(appearance)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: displayOptions.bounds.height), in: displayOptions)
    }

    @objc private func pickViewport(_ item: NSMenuItem) {
        if let setting = item.representedObject as? BrowserViewportSetting { setViewport(setting) }
    }

    @objc private func editViewport() {
        guard canAdjustDisplay, hasControl, let tab, let connection = workspace.connectionID, let window = view.window else { return }
        let streamID = self.streamID
        Task { [weak self] in
            guard let size = await BrowserViewportEditor.chooseSize(tab.display.viewport.size, in: window),
                  let self, self.streamID == streamID, workspace.connectionID == connection else { return }
            setViewport(.fixed(size, presetID: nil))
        }
    }

    private func setViewport(_ setting: BrowserViewportSetting) {
        guard canAdjustDisplay, hasControl, tab?.display.viewport != setting else { return }
        send(["type": .string("viewport"), "setting": setting.wire])
        if setting == .fill { scheduleResize() }
    }

    func canZoom(_ direction: BrowserZoom.Direction) -> Bool {
        canAdjustDisplay && tab?.display.zoom.step(direction) != nil
    }

    func zoom(_ direction: BrowserZoom.Direction) {
        if let level = tab?.display.zoom.step(direction) { changeZoom(level) }
    }

    @objc private func pickZoom(_ item: NSMenuItem) {
        if let zoom = item.representedObject as? BrowserZoom { changeZoom(zoom) }
    }

    private func changeZoom(_ zoom: BrowserZoom) {
        if tab?.display.zoom != zoom { adjustDisplay(["zoomFactor": .double(zoom.factor)]) }
    }

    @objc private func pickAppearance(_ item: NSMenuItem) {
        if let appearance = item.representedObject as? BrowserPageAppearance, tab?.display.appearance != appearance {
            adjustDisplay(["colorScheme": .string(appearance.rawValue)])
        }
    }

    private func requestDisplayAdjustment(_ fields: Payload, tabID: String, context: Context) async throws {
        var input = fields
        input["threadId"] = .string(context.threadId)
        input["tabId"] = .string(tabID)
        _ = try await workspace.request("preview.adjust", input, timeout: .seconds(15))
    }

    private func adjustDisplay(_ fields: Payload) {
        guard canAdjustDisplay, let context, let connection = workspace.connectionID, let id = tab?.id else { return }
        message = nil
        mutation = Task {
            defer { if !Task.isCancelled, self.context == context { mutation = nil; render() } }
            do {
                guard !Task.isCancelled, self.context == context, workspace.connectionID == connection else { return }
                try await requestDisplayAdjustment(fields, tabID: id, context: context)
                try await reconcileTabs(context, connection: connection)
            } catch {
                if !Task.isCancelled, self.context == context, workspace.connectionID == connection, selected == id {
                    message = error.localizedDescription
                }
            }
        }
        render()
    }

    private func localServerMenu() {
        let menu = NSMenu()
        for server in discovered {
            guard let url = server["url"].string else { continue }
            let item = menuItem(url, target: self, action: #selector(openLocalServer(_:)))
            item.representedObject = url
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: localServers.bounds.height), in: localServers)
    }

    @objc private func openLocalServer(_ item: NSMenuItem) {
        if let url = item.representedObject as? String { openTab(url: url) }
    }

    private func answerDialog() {
        guard hasControl, let dialog = control?.dialog, let window = view.window else { return }
        let streamID = self.streamID
        let alert = NSAlert()
        alert.messageText = "Browser dialog"
        alert.informativeText = String(dialog.message.prefix(2_000))
        let input = NSTextField(string: dialog.defaultValue)
        if dialog.type == "prompt" {
            input.frame.size = NSSize(width: 280, height: 24)
            alert.accessoryView = input
            alert.window.initialFirstResponder = input
        }
        alert.addButton(withTitle: "OK")
        if dialog.type != "alert" { alert.addButton(withTitle: "Cancel") }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.streamID == streamID, control?.dialog == dialog else { return }
            let accept = response == .alertFirstButtonReturn
            var payload: Payload = ["type": .string("dialog"), "accept": .bool(accept)]
            if accept && dialog.type == "prompt" { payload["promptText"] = .string(input.stringValue) }
            send(payload)
        }
    }

    private func chooseFiles() {
        guard hasControl, let context, let id = selected, let chooser, let window = view.window, transfer == nil else { return }
        let streamID = self.streamID
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = chooser.multiple
        panel.prompt = "Upload"
        let types = chooser.accept.split(separator: ",").compactMap { spec -> UTType? in
            let value = spec.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix(".") { return UTType(filenameExtension: String(value.dropFirst())) }
            switch value {
            case "image/*": return .image
            case "audio/*": return .audio
            case "video/*": return .movie
            default: return UTType(mimeType: value)
            }
        }
        panel.allowedContentTypes = types
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.streamID == streamID, self.chooser?.id == chooser.id, hasControl else { return }
            let files = response == .OK ? panel.urls : []
            transfer = Task {
                defer { if !Task.isCancelled, self.context == context { transfer = nil; render() } }
                do {
                    let api = try workspace.browserAPI(for: context.environmentID)
                    try await api.uploadBrowserFiles(files, threadId: context.threadId, tabId: id, chooserId: chooser.id)
                } catch { if !Task.isCancelled, self.context == context { message = error.localizedDescription } }
            }
            render()
        }
    }

    private func saveDownload() {
        guard let target = downloadTarget, let download = downloads[target]?.first,
              let window = view.window, transfer == nil else { return }
        let context = target.context
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (download.name as NSString).lastPathComponent
        panel.prompt = "Save"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, self.context == context, let destination = panel.url else { return }
            transfer = Task {
                defer { if !Task.isCancelled, self.context == context { transfer = nil; render() } }
                do {
                    let api = try workspace.browserAPI(for: context.environmentID)
                    let file = try await api.downloadBrowserFile(threadId: context.threadId, tabId: target.tabId, downloadId: download.id)
                    defer { try? FileManager.default.removeItem(at: file) }
                    try Task.checkCancellation()
                    let manager = FileManager.default
                    let staged = destination.deletingLastPathComponent().appendingPathComponent(".t3-download-\(UUID().uuidString)")
                    defer { try? manager.removeItem(at: staged) }
                    try manager.moveItem(at: file, to: staged)
                    if manager.fileExists(atPath: destination.path) {
                        _ = try manager.replaceItemAt(destination, withItemAt: staged)
                    } else { try manager.moveItem(at: staged, to: destination) }
                    downloads[target]?.removeAll { $0.id == download.id }
                } catch { if !Task.isCancelled, self.context == context { message = error.localizedDescription } }
            }
            render()
        }
    }

    private func tool(_ name: String, _ symbol: String, action: @escaping () -> Void) -> ActionButton {
        let button = ActionButton(name, symbol: symbol, iconOnly: true, style: .subtle, action: action)
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 25).isActive = true
        return button
    }

    private func render() {
        guard isViewLoaded else { return }
        let tab = self.tab
        let titles = tabs.tabs.isEmpty ? ["No browser tabs"] : tabs.tabs.map(\.displayName)
        if tabPicker.itemArray.map(\.title) != titles ||
            tabPicker.itemArray.compactMap({ $0.representedObject as? String }) != tabs.tabs.map(\.id) {
            tabPicker.removeAllItems()
            for tab in tabs.tabs {
                let item = NSMenuItem(title: tab.displayName, action: nil, keyEquivalent: "")
                item.representedObject = tab.id
                tabPicker.menu?.addItem(item)
            }
            if tabs.tabs.isEmpty { tabPicker.addItem(withTitle: "No browser tabs") }
        }
        if let index = tabs.tabs.firstIndex(where: { $0.id == selected }) { tabPicker.selectItem(at: index) }
        tabPicker.isEnabled = !tabs.tabs.isEmpty
        let currentAddress = tab?.url ?? ""
        if renderedTab != selected {
            renderedTab = selected
            renderedAddress = currentAddress
            address.stringValue = currentAddress
        } else if renderedAddress != currentAddress {
            renderedAddress = currentAddress
            if address.currentEditor() == nil { address.stringValue = currentAddress }
        }
        address.toolTip = currentAddress.isEmpty ? nil : currentAddress
        address.isEnabled = canOperate && mutation == nil
        close.isEnabled = canOperate && mutation == nil && tab != nil
        localServers.isEnabled = canOperate && mutation == nil && !discovered.isEmpty
        previous.isEnabled = hasControl && tab?.canGoBack == true
        next.isEnabled = hasControl && tab?.canGoForward == true
        reload.isEnabled = hasControl || failed
        displayOptions.isEnabled = canShowDisplayOptions
        displayOptions.toolTip = tab.map { "\($0.display.viewport.title) · \($0.display.zoom.title) · \($0.display.appearance.title)" }
            ?? "Browser Display Options"
        take.isHidden = control?.canOperate != true
        take.title = hasControl ? "Release Control" : "Take Control"
        take.setAccessibilityLabel(hasControl ? "Release Control" : "Take Control")
        switch control?.owner {
        case .you: controlLabel.stringValue = "Controlling"
        case .agent: controlLabel.stringValue = "Agent controls"
        case .otherViewer: controlLabel.stringValue = "Other viewer"
        case .unclaimed: controlLabel.stringValue = control?.canOperate == true ? "Watching" : "Read-only"
        case nil: controlLabel.stringValue = tab == nil ? "Browser on the host" : failed ? "Disconnected" : "Connecting…"
        }
        if control?.canOperate == false { controlLabel.stringValue = "Read-only" }
        let targets = recordings.activeTargets
        let phase = tabRecordingPhase
        let statusTarget = targets.first { $0.key == recordingKey } ?? (targets.count == 1 ? targets.first : nil)
        let recordingMessage: String? = switch recordings.phase(for: statusTarget?.key) {
        case .starting: "Starting browser recording…"
        case .recording: statusTarget.map { "Recording \($0.title)" }
        case .finishing: "Saving browser recording…"
        case .idle where targets.count > 1: "\(targets.count) browser recordings active"
        case .idle: recordings.notice
        }
        let recordTitle = switch phase {
        case .idle: "Start Browser Recording"
        case .starting, .recording: "Stop Browser Recording"
        case .finishing: "Saving Browser Recording"
        }
        if record.accessibilityLabel() != recordTitle {
            record.image = WorkspaceStyle.symbol(phase == .idle ? "record.circle" : "stop.circle.fill")
            record.contentTintColor = phase == .idle ? WorkspaceStyle.secondary : WorkspaceStyle.negative
            record.setAccessibilityLabel(recordTitle)
            record.toolTip = recordTitle
        }
        record.isEnabled = canStartRecording || phase == .starting || phase == .recording
        captureOptions.isEnabled = canCaptureScreenshot || canAnnotateRegion || hasLatestScreenshot
        notice.stringValue = message ?? recordingMessage ?? tab?.failure ?? ""
        notice.isHidden = notice.stringValue.isEmpty
        placeholder.isHidden = hasFrame
        placeholder.stringValue = context == nil ? "Select a conversation to use its Browser." :
            failed ? "The host’s browser is unavailable." : !tabs.loaded ? "Loading browser tabs…" :
            tab == nil ? (canOperate ? "Enter an address to open a page on the host." : "No browser tabs are open in this conversation.") :
            "Connecting to the host’s browser…"
        respond.isHidden = !hasControl || control?.dialog == nil
        choose.isHidden = !hasControl || chooser == nil
        save.isHidden = (downloadTarget.flatMap { downloads[$0] } ?? []).isEmpty
        choose.isEnabled = transfer == nil
        save.isEnabled = transfer == nil
        retry.isHidden = !failed
        actions?.isHidden = respond.isHidden && choose.isHidden && save.isHidden && retry.isHidden
        syncBrowserPreferences()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if let renderedAddress, address.stringValue.isEmpty { address.stringValue = renderedAddress }
    }
}
