import AppKit

@MainActor
final class ConversationActivityLine: NSView {
    private let icon = WorkspaceStyle.icon("ellipsis", size: 12, tint: WorkspaceStyle.secondary)
    private let title = label(size: 12, weight: .medium, color: WorkspaceStyle.secondary)
    private let detail = label(size: 12, color: WorkspaceStyle.muted)
    private var activity: ThreadLiveActivity?

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        let content = row([icon, title, detail, NSView()], spacing: 7)
        content.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        icon.widthAnchor.constraint(equalToConstant: 15).isActive = true
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        heightAnchor.constraint(equalToConstant: 22).isActive = true
        fill(content, in: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func render(_ next: ThreadLiveActivity?) {
        guard activity != next else { return }
        if activity?.symbol != next?.symbol, let symbol = next?.symbol {
            icon.image = WorkspaceStyle.symbol(symbol, size: 12, weight: .medium)
        }
        activity = next
        isHidden = next == nil
        title.stringValue = next?.title ?? ""
        detail.stringValue = next?.detail ?? ""
        detail.isHidden = next?.detail == nil
        detail.toolTip = next?.detail
    }
}
