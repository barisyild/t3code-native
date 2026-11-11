import AppKit
import UniformTypeIdentifiers

@MainActor
final class DevicePane: NSViewController {
    private let workspace: Workspace
    private let devices = NSPopUpButton()
    private let canvas = DeviceCanvas()
    private lazy var rtc: DeviceWebRTCView = {
        let view = DeviceWebRTCView()
        view.onExpiredClose = { [workspace] target, id in try? await workspace.endDeviceCapture(target, sessionID: id) }
        return view
    }()
    private let display = NSView()
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let notice = NSTextField(wrappingLabelWithString: "")
    private lazy var open = ActionButton("Open", symbol: "play", style: .subtle) { [weak self] in self?.openSelected() }
    private lazy var refresh = button("Refresh Devices", "arrow.clockwise") {
        [weak self] in self?.refreshDevices()
    }
    private lazy var home = button("Home", "house") { [weak self] in self?.enqueue(.button(.home)) }
    private lazy var back = button("Back", "chevron.left") { [weak self] in self?.enqueue(.button(.back)) }
    private lazy var recents = button("App Switcher", "square.on.square") { [weak self] in self?.enqueue(.button(.recents)) }
    private lazy var lock = button("Lock Screen", "lock") { [weak self] in self?.enqueue(.button(.power)) }
    private lazy var rotate = button("Rotate", "rotate.right") { [weak self] in self?.enqueue(.rotate) }
    private lazy var screenshot = button("Save Screenshot", "camera") { [weak self] in self?.captureScreenshot() }
    private lazy var more = button("Device Actions", "ellipsis") { [weak self] in self?.showActions() }
    private lazy var footer = row([home, back, recents, lock, rotate, NSView(), screenshot], spacing: 4)
    private var scope: DeviceScope?
    private var state: DeviceState?
    private var isPresented = false
    private var listed: [DeviceSummary] = []
    private var selected: DeviceKey?
    private var locallyClosed: DeviceKey?
    private var viewing: DeviceTarget?
    private var stateTask: Task<Void, Never>?
    private var probed = false
    private var operationID: UUID?
    private var stream: DeviceStream?
    private var streamID: UUID?
    private var streamTask: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var inputs: [DeviceInput] = []
    private var videoReady = false
    private var usesWebRTC = false
    private var streamFailure: String?
    private var failure: String?
    private var capturing = false
    private var tools: DeviceToolsSheet?
    var onError: ((String) -> Void)?
    var onManageHosts: (() -> Void)? { didSet { render() } }

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = Surface(WorkspaceStyle.navigation)
        devices.isBordered = false
        devices.setAccessibilityLabel("Select Device")
        devices.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        devices.target = self
        devices.action = #selector(pickDevice)
        canvas.onInput = { [weak self] in self?.enqueue($0) }
        fill(canvas, in: display)
        hint.alignment = .center
        hint.font = .systemFont(ofSize: 12.5)
        hint.textColor = WorkspaceStyle.muted
        hint.maximumNumberOfLines = 4
        display.addSubview(hint)
        hint.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: display.centerXAnchor),
            hint.centerYAnchor.constraint(equalTo: display.centerYAnchor),
            hint.widthAnchor.constraint(lessThanOrEqualTo: display.widthAnchor, constant: -30),
        ])
        notice.font = .systemFont(ofSize: 11.5)
        notice.maximumNumberOfLines = 3
        let header = row([devices, NSView(), open, refresh, more], spacing: 5)
        fill(column([header, notice, display, footer], spacing: 7, alignment: .width), in: view)
        render()
    }

    func setPresented(_ presented: Bool) {
        guard isPresented != presented else {
            if presented { sync() }
            return
        }
        isPresented = presented
        if presented { sync() }
        else { resetScope(nil) }
    }

    func sync() {
        guard isPresented else { return }
        let next = workspace.deviceScope
        if scope != next { resetScope(next) }
        render()
    }

    private func resetScope(_ next: DeviceScope?) {
        stateTask?.cancel()
        stateTask = nil
        stopViewing()
        scope = next
        state = nil
        selected = nil
        locallyClosed = nil
        operationID = nil
        probed = false
        failure = nil
        if let next { subscribe(next) }
    }

    private func subscribe(_ scope: DeviceScope) {
        guard stateTask == nil else { return }
        stateTask = Task { [weak self, workspace] in
            do {
                try await workspace.watchDevices(scope) { frames in
                    guard let self, self.scope == scope, !Task.isCancelled else { return }
                    for frame in frames {
                        if let state = DeviceState(frame) { self.accept(state) }
                    }
                    if !self.probed, self.operationID == nil,
                       self.state?.hostStatus != "disabled", self.state?.onboardingCompleted == true {
                        self.probed = true
                        self.run({ try await workspace.listDevices(scope, inspectOnly: false) }, apply: self.accept)
                    }
                }
            } catch {
                guard let self, self.scope == scope, !Task.isCancelled else { return }
                self.failure = error.localizedDescription
                self.stateTask = nil
                self.render()
            }
        }
    }

    private func accept(_ next: DeviceState) {
        guard next.revision >= (state?.revision ?? -1) else { return }
        if let locallyClosed, !next.sessions.contains(where: { $0.threadID == scope?.threadID && $0.key == locallyClosed }) {
            self.locallyClosed = nil
        }
        state = next
        if let selected, next.device(selected) == nil { self.selected = nil }
        if selected == nil, let scope {
            selected = next.sessions.first(where: { $0.threadID == scope.threadID && $0.key != locallyClosed })?.key
        }
        if selected == nil { selected = next.devices.first?.key }
        updateViewing()
        render()
    }

    private var selectedDevice: DeviceSummary? { selected.flatMap { state?.device($0) } }
    private var target: DeviceTarget? {
        guard let scope, let device = selectedDevice, let host = state?.host(for: device.key) else { return nil }
        return .init(scope: scope, key: device.key, platform: device.platform, hostKind: host.kind)
    }
    private var hasSession: Bool {
        guard let target, target.key != locallyClosed else { return false }
        return state?.sessions.contains { $0.threadID == target.scope.threadID && $0.key == target.key } == true
    }
    private var canOperate: Bool { scope != nil && workspace.can("orchestration:operate") }
    private var needsSetup: Bool { state?.hostStatus == "disabled" || state?.onboardingCompleted == false }
    private var canConfigure: Bool { scope != nil && workspace.can("settings:write") }
    private var retryableHosts: [DeviceHost] {
        guard let state, state.supportsHostRetry, canOperate else { return [] }
        return state.hosts.filter {
            state.hostStatuses[$0.id]?.status == "failed" || ($0.kind == .local && state.hostStatus == "failed")
        }
    }

    private func updateViewing() {
        let next = hasSession ? target : nil
        guard viewing != next else { return }
        stopViewing()
        if let next { startViewing(next) }
    }

    @objc private func pickDevice() {
        selected = devices.selectedItem?.representedObject as? DeviceKey
        failure = nil
        updateViewing()
        render()
    }

    private func openSelected() {
        if needsSetup {
            configure(["enabled": .bool(true), "onboardingCompleted": .bool(true)])
            return
        }
        guard let target, canOperate, !hasSession, workspace.selectedThread?.archived == false else { return }
        run({ [workspace] in try await workspace.openDevice(target) }) { session in
            self.locallyClosed = nil
            self.selected = session.key
            self.updateViewing()
        }
    }

    private func refreshDevices(retryHost: String? = nil) {
        guard let scope else { return }
        probed = true
        subscribe(scope)
        if let target = viewing, streamFailure != nil || (canOperate && !canvas.acceptsInput) {
            stopViewing()
            startViewing(target)
        }
        run({ [workspace] in try await workspace.listDevices(scope, inspectOnly: false, retryHost: retryHost) }, apply: accept)
    }

    private func disconnect(powerOff: Bool) {
        guard let target, hasSession, canOperate, !powerOff || selectedDevice?.physical == false else { return }
        run({ [workspace] in try await workspace.closeDevice(target, shutdown: powerOff) }) {
            if self.hasSession { self.locallyClosed = target.key }
            self.updateViewing()
        }
    }

    private func configure(_ fields: Payload) {
        guard let scope, canConfigure else { return }
        run({ [workspace] in try await workspace.configureDevices(scope, fields: fields) }, apply: accept)
    }

    private func run<Result>(_ action: @escaping @MainActor () async throws -> Result, apply: @escaping (Result) -> Void) {
        guard operationID == nil, let scope else { return }
        let id = UUID()
        operationID = id
        failure = nil
        render()
        Task { [weak self] in
            do {
                let result = try await action()
                guard let self, self.scope == scope, operationID == id else { return }
                apply(result)
            } catch {
                guard let self, self.scope == scope, operationID == id else { return }
                failure = error.localizedDescription
            }
            guard let self, self.scope == scope, operationID == id else { return }
            operationID = nil
            render()
        }
    }

    private func startViewing(_ target: DeviceTarget) {
        viewing = target
        canvas.avcc = target.avcc
        canvas.platform = target.platform
        let id = UUID()
        streamID = id
        waitForVideo(id)
        streamTask = Task { [weak self, workspace] in
            for attempt in 0...1 {
                guard let self, streamID == id, !Task.isCancelled else { return }
                do {
                    let access = try await workspace.deviceMedia(target)
                    guard streamID == id, !Task.isCancelled else { return }
                    let stream = DeviceStream(access: access, canOperate: canOperate)
                    self.stream = stream
                    try await stream.watch { [weak self] event in
                        await self?.receive(event, access: access, id: id)
                    }
                    return
                } catch {
                    guard streamID == id, !Task.isCancelled else { return }
                    if attempt == 1 {
                        let message = (error as? DeviceMediaFailure)?.errorDescription ??
                            (error as? ClientError)?.errorDescription ?? "The device stream could not connect."
                        failStream(message)
                        return
                    }
                    canvas.acceptsInput = false
                    resetInput()
                    stopWebRTC()
                    if videoReady {
                        videoReady = false
                        waitForVideo(id)
                        render()
                    }
                    do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
                }
            }
        }
        render()
    }

    private func waitForVideo(_ id: UUID) {
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(18)) } catch { return }
            guard let self, streamID == id, !videoReady else { return }
            failStream("No video received from the device.")
        }
    }

    private func failStream(_ message: String) {
        streamTask?.cancel()
        deadline?.cancel()
        streamID = nil
        resetInput()
        stopWebRTC()
        canvas.acceptsInput = false
        streamFailure = message
        render()
    }

    private func stopViewing() {
        streamID = nil
        streamTask?.cancel()
        deadline?.cancel()
        streamTask = nil
        deadline = nil
        stream = nil
        resetInput()
        videoReady = false
        streamFailure = nil
        stopWebRTC()
        canvas.reset()
        viewing = nil
    }

    private func resetInput() {
        sendTask?.cancel()
        sendTask = nil
        inputs.removeAll()
    }

    private func stopWebRTC() {
        guard usesWebRTC else { return }
        rtc.stop()
        rtc.isHidden = true
        usesWebRTC = false
        canvas.setWebRTC(false)
    }

    private func receive(_ event: DeviceStream.Event, access: DeviceMediaAccess, id: UUID) {
        guard streamID == id else { return }
        switch event {
        case .image(let image):
            canvas.display(image)
            ready()
        case .video(let sample):
            if canvas.display(sample) { ready() }
        case .screen(let screen): canvas.configure(screen)
        case .input(let ready):
            canvas.acceptsInput = ready && canOperate
            render()
        case .resetVideo: canvas.resetVideo(removeImage: false)
        case .webRTC(let settings):
            if rtc.superview == nil {
                display.addSubview(rtc, positioned: .below, relativeTo: canvas)
                rtc.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    rtc.leadingAnchor.constraint(equalTo: display.leadingAnchor),
                    rtc.trailingAnchor.constraint(equalTo: display.trailingAnchor),
                    rtc.topAnchor.constraint(equalTo: display.topAnchor),
                    rtc.bottomAnchor.constraint(equalTo: display.bottomAnchor),
                ])
            }
            usesWebRTC = true
            rtc.isHidden = false
            canvas.setWebRTC(true)
            rtc.onFrame = { [weak self] size in
                guard let self, streamID == id else { return }
                canvas.setWebRTC(true, size: size)
                ready()
            }
            rtc.onFailure = { [weak self] message in
                if self?.streamID == id { self?.failStream(message) }
            }
            rtc.start(access: access, settings: settings)
        }
    }

    private func ready() {
        guard !videoReady else { return }
        videoReady = true
        deadline?.cancel()
        deadline = nil
        render()
    }

    private func enqueue(_ input: DeviceInput) {
        guard canOperate, canvas.acceptsInput, let stream, let id = streamID else { return }
        if input.isTouchMove, inputs.last?.isTouchMove == true { inputs[inputs.count - 1] = input; return }
        if inputs.count >= 128 {
            guard let move = inputs.firstIndex(where: \.isTouchMove) else {
                if !input.isTouchMove { failStream("Device input fell behind. Refresh to reconnect.") }
                return
            }
            inputs.remove(at: move)
        }
        inputs.append(input)
        guard sendTask == nil else { return }
        sendTask = Task { [weak self] in
            guard let self else { return }
            defer { if streamID == id && !Task.isCancelled { sendTask = nil } }
            while streamID == id, !Task.isCancelled, !inputs.isEmpty {
                let next = inputs.removeFirst()
                do { try await stream.send(next) }
                catch {
                    if streamID == id && !Task.isCancelled { failStream("The device stopped accepting input. Refresh to reconnect.") }
                    return
                }
            }
        }
    }

    private func showActions() {
        let menu = NSMenu()
        if let target = viewing {
            if target.hostKind.hasHostTools { menu.addItem(menuItem("Device Tools…", target: self, action: #selector(openTools))) }
            if canOperate {
                menu.addItem(menuItem("Disconnect Device", target: self, action: #selector(disconnectAction)))
                if selectedDevice?.physical == false {
                    menu.addItem(menuItem("Power Off Simulator", target: self, action: #selector(powerOff)))
                }
            }
        }
        for host in retryableHosts {
            let item = menuItem("Retry \(host.name)", target: self, action: #selector(retryHost(_:)))
            item.representedObject = host.id
            menu.addItem(item)
        }
        if let state, canConfigure, !needsSetup {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let access = menuItem("Allow Agent Device Access", target: self, action: #selector(toggleAgentAccess))
            access.state = state.agentAccessEnabled ? .on : .off
            menu.addItem(access)
            menu.addItem(menuItem("Disable Device Support", target: self, action: #selector(disableDevices)))
        }
        if onManageHosts != nil {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(menuItem("Device Settings…", target: self, action: #selector(manageHosts)))
        }
        if !menu.items.isEmpty { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height), in: more) }
    }

    @objc private func retryHost(_ item: NSMenuItem) { refreshDevices(retryHost: item.representedObject as? String) }
    @objc private func disconnectAction() { disconnect(powerOff: false) }
    @objc private func powerOff() { disconnect(powerOff: true) }
    @objc private func manageHosts() { onManageHosts?() }
    @objc private func toggleAgentAccess() {
        if let state { configure(["agentAccessEnabled": .bool(!state.agentAccessEnabled)]) }
    }
    @objc private func disableDevices() {
        configure(["enabled": .bool(false), "agentAccessEnabled": .bool(false)])
    }

    @objc private func openTools() {
        guard let target = viewing, let window = view.window, window.attachedSheet == nil else { return }
        let tools = DeviceToolsSheet(workspace: workspace, target: target)
        self.tools = tools
        tools.onClose = { [weak self] in self?.tools = nil }
        tools.present(in: window)
    }

    private func captureScreenshot() {
        guard !capturing, let target = viewing, let window = view.window, window.attachedSheet == nil else { return }
        capturing = true
        let name = selectedDevice?.name ?? "Device"
        render()
        Task { [weak self, workspace] in
            guard let self else { return }
            defer { capturing = false; render() }
            do {
                let access = try await workspace.deviceMedia(target)
                let data = try await access.screenshot()
                guard viewing == target, isPresented, window.attachedSheet == nil else { return }
                guard let image = DeviceMediaAccess.image(data),
                      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    throw DeviceMediaFailure.invalidFrame
                }
                let save = NSSavePanel()
                save.title = "Save Device Screenshot"
                save.nameFieldStringValue = "\(name).png"
                save.allowedContentTypes = [.png]
                save.beginSheetModal(for: window) { [weak self] result in
                    guard result == .OK, let url = save.url else { return }
                    do { try png.write(to: url, options: .atomic) }
                    catch { self?.onError?(error.localizedDescription) }
                }
            } catch { onError?(error.localizedDescription) }
        }
    }

    private func render() {
        guard isViewLoaded else { return }
        let devices = self.devices
        let options = state?.devices ?? []
        if listed != options || devices.numberOfItems == 0 {
            listed = options
            devices.removeAllItems()
            for device in options {
                let host = state?.host(for: device.key)?.name ?? device.platform.title
                let item = NSMenuItem(title: "\(device.name) · \(host)", action: nil, keyEquivalent: "")
                item.representedObject = device.key
                devices.menu?.addItem(item)
            }
            if options.isEmpty { devices.addItem(withTitle: "No devices") }
        }
        if let selected { devices.select(devices.itemArray.first { $0.representedObject as? DeviceKey == selected }) }
        let idle = operationID == nil
        devices.isEnabled = !options.isEmpty && idle
        let opening = state?.bootingDevices.contains { $0.threadID == scope?.threadID && $0.key == selected } == true
        open.title = needsSetup ? "Enable Devices" : opening || !idle ? "Working…" :
            selectedDevice?.booted == false ? "Boot" : "Open"
        open.setAccessibilityLabel(open.title)
        open.isHidden = hasSession
        open.isEnabled = idle && !opening && (needsSetup ? canConfigure :
            target != nil && canOperate && workspace.selectedThread?.archived == false)
        refresh.isEnabled = scope != nil && idle
        footer.isHidden = viewing == nil
        for control in [home, back, recents, lock, rotate] { control.isEnabled = canvas.acceptsInput && canOperate }
        back.isHidden = viewing?.platform != .android
        rotate.isHidden = viewing?.platform != .ios
        screenshot.isEnabled = viewing != nil && !capturing
        more.isEnabled = idle && (viewing?.hostKind.hasHostTools == true || (viewing != nil && canOperate) ||
            !retryableHosts.isEmpty || (state != nil && canConfigure && !needsSetup) || onManageHosts != nil)
        canvas.isHidden = viewing == nil
        notice.stringValue = failure ?? streamFailure ?? ""
        notice.isHidden = notice.stringValue.isEmpty
        notice.textColor = WorkspaceStyle.negative
        let message: String
        if scope == nil { message = "Open a conversation to use a device." }
        else if state == nil { message = "Connecting to device hosts…" }
        else if needsSetup { message = "Enable device support on this environment to see its simulators and emulators." }
        else if opening { message = "Booting \(selectedDevice?.name ?? "device")…" }
        else if viewing != nil { message = videoReady ? "" : "Connecting to the device screen…" }
        else if options.isEmpty {
            message = state?.hostDetail ?? state?.hosts.flatMap(\.platforms).compactMap(\.reason).first ?? "No devices reported by this environment."
        } else { message = "Open a device to view its screen." }
        hint.stringValue = message
        hint.isHidden = message.isEmpty || streamFailure != nil
    }

    private func button(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> ActionButton {
        let button = ActionButton(title, symbol: symbol, iconOnly: true, style: .subtle, action: action)
        button.widthAnchor.constraint(equalToConstant: 25).isActive = true
        button.heightAnchor.constraint(equalToConstant: 25).isActive = true
        return button
    }
}
