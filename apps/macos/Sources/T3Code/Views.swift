import AppKit

@MainActor
final class ActionButton: NSButton {
    enum Style { case system, subtle, send, capsule, filled }

    var actionBlock: () -> Void
    var isMarked = false { didSet { if oldValue != isMarked { needsDisplay = true } } }
    private let style: Style
    private var hoverArea: NSTrackingArea?
    private var hovered = false

    init(_ title: String, symbol: String? = nil, iconOnly: Bool = false, style: Style = .system,
         action: @escaping () -> Void) {
        actionBlock = action
        self.style = style
        super.init(frame: .zero)
        self.title = iconOnly ? "" : title
        bezelStyle = .rounded
        if let symbol {
            image = WorkspaceStyle.symbol(symbol, size: iconOnly ? 13 : 12)
            imagePosition = iconOnly ? .imageOnly : .imageLeading
        }
        if style != .system {
            isBordered = false
            font = .systemFont(ofSize: 13)
            contentTintColor = usesInvertedTint ? WorkspaceStyle.canvas : WorkspaceStyle.secondary
        }
        if hasCapsuleShape {
            font = .systemFont(ofSize: 12, weight: style == .filled ? .semibold : .medium)
            imageHugsTitle = true
            focusRingType = .exterior
        }
        if iconOnly { toolTip = title }
        setAccessibilityLabel(title)
        target = self
        self.action = #selector(performAction)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isEnabled: Bool {
        didSet {
            if usesInvertedTint { contentTintColor = isEnabled ? WorkspaceStyle.canvas : WorkspaceStyle.muted }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        guard style == .subtle || hasCapsuleShape else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        hoverArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        switch style {
        case .send:
            let size = max(0, min(bounds.width, bounds.height) - 2)
            let circle = NSRect(x: bounds.midX - size / 2, y: bounds.midY - size / 2, width: size, height: size)
            (isEnabled ? WorkspaceStyle.ink : WorkspaceStyle.selection).setFill()
            NSBezierPath(ovalIn: circle).fill()
        case .subtle where isEnabled && (isMarked || hovered || isHighlighted):
            WorkspaceStyle.selection.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        case .capsule:
            let path = capsulePath
            let fill = isEnabled && (hovered || isHighlighted) ? WorkspaceStyle.bubble : WorkspaceStyle.navigation
            fill.setFill()
            path.fill()
            WorkspaceStyle.outline.setStroke()
            path.lineWidth = 1
            path.stroke()
        case .filled:
            let fill = isEnabled ? (hovered || isHighlighted ? WorkspaceStyle.secondary : WorkspaceStyle.ink) : WorkspaceStyle.selection
            fill.setFill()
            capsulePath.fill()
        default: break
        }
        super.draw(dirtyRect)
    }

    private var hasCapsuleShape: Bool { style == .capsule || style == .filled }
    private var usesInvertedTint: Bool { style == .send || style == .filled }

    private var capsulePath: NSBezierPath {
        let frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = max(0, frame.height / 2)
        return NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
    }

    override var focusRingMaskBounds: NSRect {
        hasCapsuleShape ? bounds : super.focusRingMaskBounds
    }

    override func drawFocusRingMask() {
        if hasCapsuleShape { capsulePath.fill() }
        else { super.drawFocusRingMask() }
    }

    @objc private func performAction() { actionBlock() }
}

@MainActor
func label(_ text: String = "", size: CGFloat = 13, weight: NSFont.Weight = .regular,
           color: NSColor = .labelColor) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: size, weight: weight)
    label.textColor = color
    label.lineBreakMode = .byTruncatingTail
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
}

@MainActor
func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = spacing
    return stack
}

@MainActor
func column(_ views: [NSView], spacing: CGFloat = 8, alignment: NSLayoutConstraint.Attribute = .leading) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = alignment == .width ? .leading : alignment
    stack.spacing = spacing
    if alignment == .width {
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }
    return stack
}

@MainActor
func fill(_ child: NSView, in parent: NSView, inset: CGFloat = 0) {
    parent.addSubview(child)
    child.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
        child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
        child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
        child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset),
    ])
}

@MainActor
final class Surface: NSView {
    let color: NSColor
    let border: NSColor?
    let radius: CGFloat

    init(_ color: NSColor, border: NSColor? = nil, radius: CGFloat = 0) {
        self.color = color
        self.border = border
        self.radius = radius
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let rect = border == nil ? bounds : bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        color.setFill()
        path.fill()
        if let border {
            border.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
func scroller(for document: NSView, horizontal: Bool = false, using scroll: NSScrollView = NSScrollView()) -> NSScrollView {
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = horizontal
    scroll.autohidesScrollers = true
    scroll.automaticallyAdjustsContentInsets = false
    scroll.documentView = document
    return scroll
}

@MainActor
func textScroller(_ text: NSTextView, editable: Bool = false) -> NSScrollView {
    text.isEditable = editable
    text.isSelectable = true
    text.isRichText = false
    text.drawsBackground = false
    text.isVerticallyResizable = true
    text.isHorizontallyResizable = false
    text.autoresizingMask = [.width]
    text.textContainer?.widthTracksTextView = true
    return scroller(for: text)
}

@MainActor
func menuItem(_ title: String, target: AnyObject, action: Selector, key: String = "",
              modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.target = target
    item.keyEquivalentModifierMask = modifiers
    return item
}
