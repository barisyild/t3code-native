import AppKit
import UserNotifications

@MainActor
final class ThreadNotifications: NSObject, UNUserNotificationCenterDelegate {
    enum Channel: String, CaseIterable {
        case inApp, dock, sound, system

        var title: String {
            switch self {
            case .inApp: "In-app alerts"
            case .dock: "Dock badge"
            case .sound: "Play a sound"
            case .system: "System notifications"
            }
        }
    }

    private struct Banner {
        let view: NSView
        let expiration: Task<Void, Never>
    }

    private let defaults: UserDefaults?
    private let stack = column([], spacing: 8, alignment: .trailing)
    private weak var host: NSView?
    private var environmentID: String?
    private var tracker = ThreadNoticeTracker()
    private var unread: Set<ThreadNotice.Target> = []
    private var banners: [ThreadNotice.Target: Banner] = [:]
    private var requests: [ThreadNotice.Target: String] = [:]
    private var nativeCenter: UNUserNotificationCenter?
    private lazy var completedSound = NSSound(named: NSSound.Name("Glass"))
    private lazy var attentionSound = NSSound(named: NSSound.Name("Tink"))

    private(set) var channels: Set<Channel>
    var onSettingsChange: (() -> Void)?
    var onOpen: ((ThreadNotice.Target) -> Void)?
    var isViewing: ((ThreadNotice.Target) -> Bool)?

    init(persistent: Bool) {
        let defaults: UserDefaults? = persistent ? .standard : nil
        self.defaults = defaults
        channels = Set((defaults?.stringArray(forKey: "threadNotificationChannels") ?? []).compactMap(Channel.init(rawValue:)))
        super.init()
    }

    func install(in host: NSView) {
        self.host = host
        if channels.contains(.system) { _ = try? systemCenter() }
    }

    func set(_ channel: Channel, enabled: Bool) {
        guard channels.contains(channel) != enabled else { return }
        if enabled { channels.insert(channel) }
        else { channels.remove(channel) }
        defaults?.set(channels.map(\.rawValue).sorted(), forKey: "threadNotificationChannels")
        if !enabled {
            switch channel {
            case .inApp: clearBanners()
            case .dock: clearDock()
            case .system: clearSystemRequests()
            case .sound: break
            }
        }
        if channels.isEmpty { tracker = ThreadNoticeTracker() }
        onSettingsChange?()
    }

    func authorizeSystemNotifications() async throws -> Bool {
        let center = try systemCenter()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional: return true
        case .notDetermined: return try await center.requestAuthorization(options: [.alert])
        default: return false
        }
    }

    func setEnvironment(_ id: String?) {
        guard environmentID != id else { return }
        environmentID = id
        tracker = ThreadNoticeTracker()
        clearBanners()
        clearBackground()
    }

    func receive(_ update: Workspace.ThreadShellChange, data: WorkspaceData) {
        guard let environmentID, !channels.isEmpty else { return }
        for change in tracker.receive(update, environmentID: environmentID, data: data) {
            switch change {
            case .present(let notice): present(notice)
            case .dismiss(let target): dismiss(target)
            }
        }
    }

    func clearBackground() {
        clearDock()
        clearSystemRequests()
    }

    func dismissBanner(_ target: ThreadNotice.Target) {
        guard let banner = banners.removeValue(forKey: target) else { return }
        banner.expiration.cancel()
        stack.removeArrangedSubview(banner.view)
        banner.view.removeFromSuperview()
        if banners.isEmpty { stack.removeFromSuperview() }
    }

    private func present(_ notice: ThreadNotice) {
        dismissBanner(notice.target)
        if channels.contains(.sound) {
            let sound = notice.kind == .completed ? completedSound : attentionSound
            if sound?.isPlaying == false { sound?.play() }
        }
        if let window = host?.window, NSApp.isActive, window.isVisible, !window.isMiniaturized {
            if channels.contains(.inApp), isViewing?(notice.target) != true { showBanner(notice) }
            return
        }
        if channels.contains(.dock), unread.insert(notice.target).inserted { updateDock() }
        if channels.contains(.system) { deliver(notice) }
    }

    private func dismiss(_ target: ThreadNotice.Target) {
        dismissBanner(target)
        if unread.remove(target) != nil { updateDock() }
        removeRequest(target)
    }

    private func clearBanners() {
        for target in Array(banners.keys) { dismissBanner(target) }
    }

    private func clearDock() {
        guard !unread.isEmpty else { return }
        unread.removeAll()
        updateDock()
    }

    private func updateDock() { NSApp.dockTile.badgeLabel = unread.isEmpty ? nil : String(unread.count) }

    private func showBanner(_ notice: ThreadNotice) {
        guard let host else { return }
        if banners.count == 3, let last = stack.arrangedSubviews.last,
           let oldest = banners.first(where: { $0.value.view === last })?.key { dismissBanner(oldest) }
        if stack.superview == nil {
            host.addSubview(stack, positioned: .above, relativeTo: nil)
            stack.translatesAutoresizingMaskIntoConstraints = false
            let width = stack.widthAnchor.constraint(equalToConstant: 330)
            width.priority = .defaultHigh
            NSLayoutConstraint.activate([
                width,
                stack.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, constant: -28),
                stack.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),
                stack.topAnchor.constraint(equalTo: host.topAnchor, constant: 56),
            ])
        }
        let target = notice.target
        let card = Surface(WorkspaceStyle.navigation, border: WorkspaceStyle.outline, radius: 11)
        let title = label(notice.kind.title, size: 12.5, weight: .semibold, color: WorkspaceStyle.ink)
        let thread = label(notice.title, size: 12, color: WorkspaceStyle.secondary)
        thread.toolTip = notice.title
        let open = ActionButton("Open Chat", style: .subtle) { [weak self] in
            self?.dismissBanner(target)
            self?.onOpen?(target)
        }
        let close = ActionButton("Dismiss Notification", symbol: "xmark", iconOnly: true, style: .subtle) { [weak self] in
            self?.dismissBanner(target)
        }
        let (symbol, color): (String, NSColor) = switch notice.kind {
        case .completed: ("checkmark.circle.fill", WorkspaceStyle.positive)
        case .approval: ("lock.shield", WorkspaceStyle.quota)
        case .input, .guest: ("text.bubble", WorkspaceStyle.modelFocus)
        case .failed: ("exclamationmark.circle.fill", WorkspaceStyle.negative)
        case .limited: ("exclamationmark.circle", WorkspaceStyle.quota)
        }
        let icon = WorkspaceStyle.icon(symbol, size: 15, tint: color)
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        open.setContentHuggingPriority(.required, for: .horizontal)
        close.setContentHuggingPriority(.required, for: .horizontal)
        let message = column([title, thread], spacing: 3, alignment: .width)
        let content = row([icon, message, open, close], spacing: 9)
        content.distribution = .fill
        fill(content, in: card, inset: 11)
        stack.insertArrangedSubview(card, at: 0)
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let expiration = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) }
            catch { return }
            self?.dismissBanner(target)
        }
        banners[target] = Banner(view: card, expiration: expiration)
        NSAccessibility.post(element: card, notification: .announcementRequested, userInfo: [
            .announcement: "\(notice.kind.title). \(notice.title)", .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
    }

    private func systemCenter() throws -> UNUserNotificationCenter {
        if let nativeCenter { return nativeCenter }
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            throw ClientError.message("Open the T3 Code AppKit bundle to use system notifications.")
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        nativeCenter = center
        return center
    }

    private func deliver(_ notice: ThreadNotice) {
        guard let center = try? systemCenter() else { return }
        let target = notice.target
        removeRequest(target)
        let id = UUID().uuidString
        requests[target] = id
        let content = UNMutableNotificationContent()
        content.title = notice.kind.title
        content.body = notice.title
        content.userInfo = ["environmentID": target.environmentID, "threadID": target.threadID]
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        Task { [weak self] in
            guard self?.requests[target] == id else { return }
            do {
                try await center.add(request)
                if self?.requests[target] != id { center.removeDeliveredNotifications(withIdentifiers: [id]) }
            } catch {
                if self?.requests[target] == id { self?.requests.removeValue(forKey: target) }
            }
        }
    }

    private func removeRequest(_ target: ThreadNotice.Target) {
        if let id = requests.removeValue(forKey: target) { removeRequests([id]) }
    }

    private func clearSystemRequests() {
        guard !requests.isEmpty else { return }
        let ids = Array(requests.values)
        requests.removeAll()
        removeRequests(ids)
    }

    private func removeRequests(_ ids: [String]) {
        nativeCenter?.removePendingNotificationRequests(withIdentifiers: ids)
        nativeCenter?.removeDeliveredNotifications(withIdentifiers: ids)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let environment = info["environmentID"] as? String, let thread = info["threadID"] as? String else { return }
        await openSystemNotification(.init(environmentID: environment, threadID: thread))
    }

    private func openSystemNotification(_ target: ThreadNotice.Target) {
        guard target.environmentID == environmentID, channels.contains(.system) else { return }
        dismiss(target)
        onOpen?(target)
    }
}
