import AppKit

@MainActor
final class ComposerUsageLimits: NSView {
    private lazy var button = ActionButton("Usage limits", symbol: "circle.dashed", iconOnly: true, style: .subtle) { [weak self] in
        self?.togglePreview()
    }
    private lazy var viewAll = ActionButton("View all", symbol: "arrow.right", style: .subtle) { [weak self] in
        self?.close()
        self?.onViewAll?()
    }
    private let document = UsageQuotaDocument()
    private lazy var scroll = scroller(for: document)
    private var preview: UsageLimitPreview?
    private var accounts: [UsageLimitAccount] = []
    private var card: UsageLimitsCard?
    private var desiredHeight: CGFloat = 0
    private var eventMonitor: Any?
    private var resizeObserver: NSObjectProtocol?
    private var deactivateObserver: NSObjectProtocol?
    weak var presentationView: NSView?
    var onOpen: (() -> Void)?
    var onViewAll: (() -> Void)?

    init() {
        super.init(frame: .zero)
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
        isHidden = true
        viewAll.imagePosition = .imageTrailing
        viewAll.setContentCompressionResistancePriority(.required, for: .horizontal)
        viewAll.widthAnchor.constraint(equalToConstant: 78).isActive = true
        viewAll.heightAnchor.constraint(equalToConstant: 22).isActive = true
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        fill(button, in: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { close() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func layout() {
        super.layout()
        positionCard()
    }

    func render(_ next: UsageLimitPreview?, accounts: [UsageLimitAccount], available: Bool) {
        let reportsChanged = self.accounts != accounts
        let hidden = !available
        guard preview != next || reportsChanged || isHidden != hidden else { return }
        preview = next
        self.accounts = accounts
        isHidden = hidden
        guard available else { close(); return }
        let used = next?.windows.first?.used
        button.image = used.map(Self.ring) ?? WorkspaceStyle.symbol("circle.dashed", size: 15)
        let name = next?.model ?? next?.provider ?? "Current model"
        let status = used.map { "\(Self.percent($0)) used" } ?? "Limits unavailable"
        button.toolTip = "\(name) · \(status)"
        button.setAccessibilityHelp(button.toolTip)
        if card != nil && reportsChanged { updateCard() }
    }

    func close() {
        card?.removeFromSuperview()
        card = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver) }
        resizeObserver = nil
        deactivateObserver = nil
    }

    private func togglePreview() {
        if card != nil { close(); return }
        guard let window, let host = presentationView, host.window === window else { return }
        let card = UsageLimitsCard()
        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.group)
        card.setAccessibilityLabel("Plan usage limits")
        host.addSubview(card, positioned: .above, relativeTo: nil)
        self.card = card
        let heading = label("Plan usage limits", size: 12.5, weight: .medium, color: WorkspaceStyle.secondary)
        let divider = Surface(WorkspaceStyle.outline)
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        fill(column([row([heading, NSView(), viewAll], spacing: 7), divider, scroll], spacing: 9, alignment: .width),
             in: card.body, inset: 13)
        updateCard()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, let card = self.card else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { close(); return nil }
            } else if event.window !== self.window ||
                        (!card.bounds.contains(card.convert(event.locationInWindow, from: nil)) &&
                         !button.bounds.contains(button.convert(event.locationInWindow, from: nil))) {
                close()
            }
            return event
        }
        resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.window?.contentView?.layoutSubtreeIfNeeded()
                self?.positionCard()
            }
        }
        deactivateObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.close() }
        }
        onOpen?()
    }

    private func updateCard() {
        guard card != nil else { return }
        let offset = scroll.contentView.bounds.origin
        document.subviews.forEach { $0.removeFromSuperview() }
        var rows: [NSView] = []
        var height: CGFloat = 0
        for account in accounts {
            if !rows.isEmpty {
                let divider = Surface(WorkspaceStyle.outline)
                divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
                rows.append(divider)
                height += 1
            }
            let title = account.detail.isEmpty ? account.title : "\(account.title) · \(account.detail)"
            let heading = label(title, size: 12, weight: .medium, color: WorkspaceStyle.ink)
            heading.toolTip = title
            heading.heightAnchor.constraint(equalToConstant: 19).isActive = true
            rows.append(heading)
            height += 19
            for window in account.windows {
                let reset = window.resetsAt.map { "Resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
                let amount = label("\(Self.percent(window.used)) used", size: 11.5, weight: .medium, color: WorkspaceStyle.ink)
                amount.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
                amount.setContentCompressionResistancePriority(.required, for: .horizontal)
                let name = label(window.previewLabel, size: 12, color: WorkspaceStyle.ink)
                name.toolTip = window.previewLabel
                let resetLabel = label(reset, size: 11, color: WorkspaceStyle.muted)
                resetLabel.toolTip = reset
                let meter = UsageQuotaMeter(used: window.used)
                meter.heightAnchor.constraint(equalToConstant: 4).isActive = true
                let line = column([row([name, NSView(), resetLabel, amount], spacing: 7), meter], spacing: 5, alignment: .width)
                line.heightAnchor.constraint(equalToConstant: 25).isActive = true
                rows.append(line)
                height += 25
            }
            if let notice = account.notice {
                let message = NSTextField(wrappingLabelWithString: notice)
                message.font = .systemFont(ofSize: 11.5)
                message.textColor = WorkspaceStyle.muted
                message.maximumNumberOfLines = 4
                message.toolTip = notice
                message.heightAnchor.constraint(equalToConstant: 56).isActive = true
                rows.append(message)
                height += 56
            }
            if let external = account.externalUsage {
                let link = ActionButton(external.label, symbol: "arrow.up.right", style: .subtle) {
                    NSWorkspace.shared.open(external.url)
                }
                let line = row([link, NSView()])
                line.heightAnchor.constraint(equalToConstant: 22).isActive = true
                rows.append(line)
                height += 22
            }
        }
        if rows.isEmpty {
            rows.append(label("No usage limits reported by this environment.", size: 11.5, color: WorkspaceStyle.muted))
            height = 25
        }
        fill(column(rows, spacing: 8, alignment: .width), in: document)
        desiredHeight = min(390, height + CGFloat(max(0, rows.count - 1)) * 8 + 75)
        positionCard()
        card?.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: offset)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func positionCard() {
        guard let card, let host = card.superview else { return }
        let margin: CGFloat = 12
        let gap: CGFloat = 4
        let anchor = host.convert(bounds, from: self)
        let width = min(414, max(0, host.bounds.width - 2 * margin))
        let x = min(max(anchor.maxX + 8 - width, host.bounds.minX + margin), host.bounds.maxX - margin - width)
        let above = host.isFlipped ? anchor.minY - host.bounds.minY : host.bounds.maxY - anchor.maxY
        let below = host.isFlipped ? host.bounds.maxY - anchor.maxY : anchor.minY - host.bounds.minY
        let placeAbove = above >= below
        let room = max(0, (placeAbove ? above : below) - margin - gap)
        let height = min(desiredHeight, room)
        let y: CGFloat
        if placeAbove {
            y = host.isFlipped ? anchor.minY - gap - height : anchor.maxY + gap
        } else {
            y = host.isFlipped ? anchor.maxY + gap : anchor.minY - gap - height
        }
        card.pointsUp = !placeAbove
        card.frame = NSRect(x: x, y: y, width: width, height: height)
        card.pointerX = anchor.midX - x
        card.needsLayout = true
        card.needsDisplay = true
    }

    private static func percent(_ value: Double) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(0...1)))
    }

    private static func ring(used: Double) -> NSImage {
        NSImage(size: NSSize(width: 17, height: 17), flipped: false) { rect in
            let track = NSBezierPath(ovalIn: rect.insetBy(dx: 2.5, dy: 2.5))
            WorkspaceStyle.muted.withAlphaComponent(0.42).setStroke()
            track.lineWidth = 2
            track.stroke()
            if used > 0 {
                let arc = used == 100 ? NSBezierPath(ovalIn: rect.insetBy(dx: 2.5, dy: 2.5)) : NSBezierPath()
                if used < 100 {
                    arc.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: 6,
                                  startAngle: 90, endAngle: 90 - 3.6 * used, clockwise: true)
                }
                arc.lineWidth = 2.25
                arc.lineCapStyle = .round
                WorkspaceStyle.quota.setStroke()
                arc.stroke()
            }
            return true
        }
    }
}

@MainActor
private final class UsageLimitsCard: NSView {
    let body = NSView()
    var pointerX: CGFloat = 0
    var pointsUp = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height, .minXMargin, .minYMargin]
        body.autoresizingMask = [.width, .height]
        addSubview(body)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        body.frame = NSRect(x: 0, y: pointsUp ? 0 : 8, width: bounds.width, height: max(0, bounds.height - 8))
        super.layout()
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: body.frame, xRadius: 12, yRadius: 12)
        WorkspaceStyle.selection.setFill()
        shape.fill()
        WorkspaceStyle.outline.setStroke()
        shape.lineWidth = 1
        shape.stroke()
        let x = min(max(17, pointerX), max(17, bounds.width - 17))
        let base = pointsUp ? body.frame.maxY : body.frame.minY
        let tip = pointsUp ? bounds.maxY : bounds.minY
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: x - 7, y: base))
        arrow.line(to: NSPoint(x: x, y: tip))
        arrow.line(to: NSPoint(x: x + 7, y: base))
        arrow.close()
        WorkspaceStyle.selection.setFill()
        arrow.fill()
        let edge = NSBezierPath()
        edge.move(to: NSPoint(x: x - 7, y: base))
        edge.line(to: NSPoint(x: x, y: tip))
        edge.line(to: NSPoint(x: x + 7, y: base))
        WorkspaceStyle.outline.setStroke()
        edge.lineWidth = 1
        edge.stroke()
    }
}

private final class UsageQuotaDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class UsageQuotaMeter: NSView {
    let used: Double

    init(used: Double) {
        self.used = used
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        WorkspaceStyle.muted.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        guard used > 0 else { return }
        let filled = NSRect(x: 0, y: 0, width: bounds.width * used / 100, height: bounds.height)
        WorkspaceStyle.quota.setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }
}
