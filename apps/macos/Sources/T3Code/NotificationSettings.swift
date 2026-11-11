import AppKit

@MainActor
final class NotificationSettingsController: NSViewController {
    private let notifications: ThreadNotifications
    private let status = label(size: 12, color: WorkspaceStyle.muted)
    private var controls: [ThreadNotifications.Channel: NSSwitch] = [:]
    private var requesting = false

    init(notifications: ThreadNotifications) {
        self.notifications = notifications
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = Surface(WorkspaceStyle.navigation)
        let description = label("Get updates when a conversation finishes or needs your attention.", size: 12, color: WorkspaceStyle.secondary)
        let options: [NSView] = ThreadNotifications.Channel.allCases.map { channel in
            let toggle = NSSwitch()
            toggle.target = self
            toggle.action = #selector(toggleChannel(_:))
            toggle.setAccessibilityLabel(channel.title)
            controls[channel] = toggle
            return row([label(channel.title, size: 12, color: WorkspaceStyle.ink), NSView(), toggle])
        }
        fill(column([description] + options + [status, NSView()], spacing: 13, alignment: .width), in: view, inset: 20)
        render()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        render()
    }

    private func render() {
        for (channel, toggle) in controls { toggle.state = notifications.channels.contains(channel) ? .on : .off }
        controls[.system]?.isEnabled = !requesting
        status.isHidden = status.stringValue.isEmpty
    }

    @objc private func toggleChannel(_ sender: NSSwitch) {
        guard let channel = controls.first(where: { $0.value === sender })?.key else { return }
        let enabled = sender.state == .on
        if channel != .system || !enabled {
            if channel == .system { status.stringValue = "" }
            notifications.set(channel, enabled: enabled)
            render()
            return
        }
        requesting = true
        status.stringValue = "Waiting for macOS…"
        render()
        Task { [weak self] in
            guard let self else { return }
            defer {
                requesting = false
                render()
            }
            do {
                let allowed = try await notifications.authorizeSystemNotifications()
                status.stringValue = allowed ? "" : "Allow T3 Code notifications in System Settings, then enable this option."
                if allowed { notifications.set(.system, enabled: true) }
            } catch {
                status.stringValue = error.localizedDescription
            }
        }
    }
}
