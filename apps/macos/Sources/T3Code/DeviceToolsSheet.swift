import AppKit

@MainActor
final class DeviceToolsSheet: NSWindowController {
    private struct Choice {
        let control: NSPopUpButton
        let setting: String
        let action: String
    }

    private let workspace: Workspace
    private let target: DeviceTarget
    private let notice = NSTextField(wrappingLabelWithString: "")
    private let foreground = label(size: 11.5, color: WorkspaceStyle.muted)
    private let app = NSTextField()
    private let address = NSTextField()
    private let latitude = NSTextField()
    private let longitude = NSTextField()
    private let permission = NSPopUpButton()
    private let push = NSTextField()
    private lazy var reload = ActionButton("Refresh", symbol: "arrow.clockwise", style: .subtle) { [weak self] in self?.load() }
    private lazy var done = ActionButton("Done", style: .subtle) { [weak self] in
        guard let window = self?.window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }
    private var choices: [Choice] = []
    private var toggles: [String: NSButton] = [:]
    private var controls: [NSControl] = []
    private var task: Task<Void, Never>?
    private var loaded = false
    var onClose: (() -> Void)?

    init(workspace: Workspace, target: DeviceTarget) {
        self.workspace = workspace
        self.target = target
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 530, height: 525),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Device Tools"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 460, height: 310)
        notice.font = .systemFont(ofSize: 11.5)
        notice.maximumNumberOfLines = 3
        done.keyEquivalent = "\u{1b}"
        let content = Surface(WorkspaceStyle.navigation)
        window.contentView = content
        fill(column([label("Device Tools", size: 17, weight: .semibold, color: WorkspaceStyle.ink),
                     notice, settingsScroll(), row([reload, NSView(), done])], spacing: 10, alignment: .width), in: content, inset: 16)
        setBusy(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present(in parent: NSWindow) {
        guard let window, parent.attachedSheet == nil else { return }
        parent.beginSheet(window) { [weak self] _ in
            self?.task?.cancel()
            self?.onClose?()
        }
        load()
    }

    private func settingsScroll() -> NSView {
        let ios = target.platform == .ios
        let launch = action("Launch") { [weak self] in self?.actOnApp("launchApp") }
        let terminate = action("Terminate") { [weak self] in self?.actOnApp("terminateApp") }
        let open = action("Open URL") { [weak self] in
            guard let self else { return }
            let url = address.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard URLComponents(string: url)?.scheme != nil else { show("Enter a URL with a scheme.", error: true); return }
            perform("openUrl", ["url": .string(url)])
        }
        let setLocation = action("Set Location") { [weak self] in self?.changeLocation() }
        let clearLocation = action("Clear") { [weak self] in self?.perform("clearLocation") }
        let shake = action("Shake Device") { [weak self] in self?.perform("shake") }
        let fields: [(String, NSTextField)] = [
            ("App identifier", app), ("URL", address), ("Latitude", latitude), ("Longitude", longitude), ("Push JSON payload", push),
        ]
        for (name, field) in fields {
            field.placeholderString = name
            field.setAccessibilityLabel(name)
            controls.append(field)
        }
        var display = [
            choice("Appearance", setting: "appearance", action: "setAppearance", values: ["light", "dark"]),
            choice("Text Size", setting: "textSize", action: "setTextSize", values: ["small", "default", "large", "extra-large"]),
            toggle("Reduce Motion", key: "reduceMotion"),
        ]
        if ios {
            display += [
                choice("Orientation", setting: "orientation", action: "setOrientation", values: DeviceScreenConfig.Orientation.allCases.map(\.rawValue)),
                choice("Color Filter", setting: "colorFilter", action: "setColorFilter", values: ["none", "grayscale", "red-green", "green-red", "blue-yellow"]),
                choice("Liquid Glass", setting: "liquidGlass", action: "setLiquidGlass", values: ["clear", "tinted"]),
                toggle("Increase Contrast", key: "increaseContrast"), toggle("Reduce Transparency", key: "reduceTransparency"),
                toggle("Show Borders", key: "showBorders"), toggle("VoiceOver", key: "voiceOver"),
            ]
        } else { display.append(toggle("Network", key: "networkEnabled")) }
        let permissions = ["camera", "microphone", "photos", "contacts", "calendar", "reminders",
                           "location", "notifications", "motion", "media-library", "faceid"]
        for name in permissions { permission.addItem(withTitle: name) }
        permission.setAccessibilityLabel("Permission")
        controls.append(permission)
        let decisions = ["grant", "revoke", "reset"].map { decision in
            action(decision.capitalized) { [weak self] in
                guard let self, let appID = appID(), let value = permission.titleOfSelectedItem else { return }
                perform("setPermission", ["appId": .string(appID), "permission": .string(value), "decision": .string(decision)])
            }
        }
        let sendPush = action("Send Push") { [weak self] in
            guard let self, let appID = appID(),
                  let payload = try? JSONDecoder().decode(Wire.self, from: Data(push.stringValue.utf8)), payload.object != nil else {
                self?.show("Enter an app identifier and a JSON object for the push payload.", error: true)
                return
            }
            perform("sendPush", ["appId": .string(appID), "payload": payload])
        }
        let body = column([
            heading("App"), foreground, row([app, launch, terminate]), row([address, open]),
            heading("Display"),
        ] + display + [
            heading("Location"), row([latitude, longitude, setLocation] + (ios ? [clearLocation] : [])),
            heading("Permissions for App Identifier"), row([permission] + decisions + [NSView()]),
        ] + (ios ? [heading("Simulator Events"), row([push, sendPush, shake])] : []), spacing: 9, alignment: .width)
        let document = DeviceToolsDocument()
        let scroll = scroller(for: document)
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        fill(body, in: document, inset: 3)
        return scroll
    }

    private func heading(_ text: String) -> NSView { label(text, size: 12.5, weight: .semibold, color: WorkspaceStyle.ink) }

    private func action(_ title: String, _ handler: @escaping () -> Void) -> ActionButton {
        let button = ActionButton(title, style: .subtle, action: handler)
        controls.append(button)
        return button
    }

    private func choice(_ title: String, setting: String, action: String, values: [String]) -> NSView {
        let menu = NSPopUpButton()
        menu.setAccessibilityLabel(title)
        menu.target = self
        menu.action = #selector(changeChoice(_:))
        for value in values {
            let item = NSMenuItem(title: value.replacingOccurrences(of: "_", with: " ").capitalized, action: nil, keyEquivalent: "")
            item.representedObject = value
            menu.menu?.addItem(item)
        }
        choices.append(.init(control: menu, setting: setting, action: action))
        controls.append(menu)
        return row([label(title, size: 12), NSView(), menu])
    }

    private func toggle(_ title: String, key: String) -> NSView {
        let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(changeToggle(_:)))
        toggles[key] = button
        controls.append(button)
        return row([button, NSView()])
    }

    @objc private func changeChoice(_ sender: NSPopUpButton) {
        guard let choice = choices.first(where: { $0.control === sender }),
              let value = sender.selectedItem?.representedObject as? String else { return }
        perform(choice.action, ["value": .string(value)])
    }

    @objc private func changeToggle(_ sender: NSButton) {
        guard let key = toggles.first(where: { $0.value === sender })?.key else { return }
        perform("setToggle", ["setting": .string(key), "value": .bool(sender.state == .on)])
    }

    private func appID() -> String? {
        let value = app.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { show("Enter an app identifier.", error: true); return nil }
        return value
    }

    private func actOnApp(_ type: String) {
        if let id = appID() { perform(type, ["appId": .string(id)]) }
    }

    private func changeLocation() {
        guard let lat = Double(latitude.stringValue.replacingOccurrences(of: ",", with: ".")),
              let long = Double(longitude.stringValue.replacingOccurrences(of: ",", with: ".")),
              (-90...90).contains(lat), (-180...180).contains(long) else {
            show("Enter a valid latitude and longitude.", error: true)
            return
        }
        perform("setLocation", ["latitude": .double(lat), "longitude": .double(long)])
    }

    private func load() { run { try await self.workspace.deviceDetail(self.target) } }

    private func perform(_ type: String, _ fields: Payload = [:]) {
        guard loaded, workspace.can("orchestration:operate") else { return }
        run { try await self.workspace.deviceAction(self.target, fields: fields.merging(["type": .string(type)]) { _, new in new }) }
    }

    private func run(_ read: @escaping @MainActor () async throws -> Wire) {
        guard task == nil else { return }
        setBusy(true)
        show("Reading device settings…")
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil; setBusy(false) }
            do {
                let value = try await read()
                guard !Task.isCancelled else { return }
                loaded = true
                update(value)
                show("")
            } catch {
                if !Task.isCancelled { show(error.localizedDescription, error: true) }
            }
        }
    }

    private func update(_ detail: Wire) {
        let settings = detail["settings"]
        for choice in choices {
            if let value = settings[choice.setting].string {
                choice.control.select(choice.control.itemArray.first { $0.representedObject as? String == value })
            }
        }
        for (key, control) in toggles { control.state = settings[key].bool == true ? .on : .off }
        let id = detail["foregroundApp"]["id"].string
        foreground.stringValue = id.map { "Foreground app · \($0)" } ?? "No foreground app reported."
        if app.stringValue.isEmpty, let id { app.stringValue = id }
        latitude.stringValue = settings["location"]["latitude"].double.map { String($0) } ?? ""
        longitude.stringValue = settings["location"]["longitude"].double.map { String($0) } ?? ""
    }

    private func setBusy(_ busy: Bool) {
        let enabled = !busy && loaded && workspace.deviceScope == target.scope && workspace.can("orchestration:operate")
        for control in controls { control.isEnabled = enabled }
        reload.isEnabled = !busy
    }

    private func show(_ message: String, error: Bool = false) {
        notice.stringValue = message
        notice.textColor = error ? WorkspaceStyle.negative : WorkspaceStyle.muted
        notice.isHidden = message.isEmpty
    }
}

private final class DeviceToolsDocument: NSView {
    override var isFlipped: Bool { true }
}
