import AppKit
import QuartzCore

@MainActor
final class ComposerOptionsView: NSStackView {
    private struct Pick {
        let optionID: String
        let value: Wire?
    }

    private static let sliderHeight: CGFloat = 32

    private let header = NSView()
    private lazy var headerHeight = header.heightAnchor.constraint(equalToConstant: 40)
    private let slider = EffortSlider(frame: .zero)
    private let speed = NSPopUpButton(frame: .zero, pullsDown: true)
    private lazy var providerButton: ActionButton = ActionButton("Change provider", iconOnly: true, style: .subtle) { [weak self] in
        guard let self else { return }
        onBrowseProviders?(providerButton)
    }
    private lazy var readout = EffortReadout { [weak self] in self?.showEffortMenu() }
    private lazy var modelButton = ActionButton("Choose model", style: .subtle) { [weak self] in
        self?.onBrowseModels?()
    }
    private var model = ComposerModelOptions()
    private var enabled = false
    private var promptEffort = false
    private var effortContext: Wire = .null
    var onPick: ((String, Wire?) -> Void)?
    var onBrowseModels: (() -> Void)?
    var onBrowseProviders: ((NSView) -> Void)?

    var preferredHeight: CGFloat {
        headerHeight.constant + (slider.isHidden ? 0 : spacing + Self.sliderHeight)
    }

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 4
        speed.isBordered = false
        speed.controlSize = .small
        speed.imagePosition = .imageOnly
        (speed.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        providerButton.imagePosition = .imageOnly
        modelButton.font = .systemFont(ofSize: 12)
        modelButton.image = WorkspaceStyle.symbol("chevron.right", size: 8, weight: .medium)
        modelButton.imagePosition = .imageTrailing
        modelButton.cell?.lineBreakMode = .byTruncatingTail
        modelButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        readout.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for button in [providerButton as NSView, speed] {
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        let titles = column([readout, modelButton], spacing: 1, alignment: .centerX)
        for view in [providerButton as NSView, titles, speed] {
            header.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        slider.minValue = 0
        slider.allowsTickMarkValuesOnly = true
        slider.focusRingType = .exterior
        slider.setAccessibilityLabel("Effort level")
        slider.target = self
        slider.action = #selector(pickEffort(_:))
        addArrangedSubview(header)
        addArrangedSubview(slider)
        NSLayoutConstraint.activate([
            header.widthAnchor.constraint(equalTo: widthAnchor),
            headerHeight,
            slider.widthAnchor.constraint(equalTo: widthAnchor),
            slider.heightAnchor.constraint(equalToConstant: Self.sliderHeight),
            providerButton.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            providerButton.topAnchor.constraint(equalTo: header.topAnchor),
            speed.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            speed.topAnchor.constraint(equalTo: header.topAnchor),
            titles.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            titles.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titles.leadingAnchor.constraint(greaterThanOrEqualTo: providerButton.trailingAnchor, constant: 4),
            titles.trailingAnchor.constraint(lessThanOrEqualTo: speed.leadingAnchor, constant: -4),
            readout.widthAnchor.constraint(lessThanOrEqualTo: titles.widthAnchor),
            readout.heightAnchor.constraint(equalToConstant: 21),
            modelButton.widthAnchor.constraint(lessThanOrEqualTo: titles.widthAnchor),
            modelButton.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func render(_ next: ComposerModelOptions, modelName: String, provider: ComposerProvider?, icon: NSImage,
                canBrowseProviders: Bool, enabled: Bool, promptEffort: Bool, effortContext: Wire) {
        if modelButton.title != modelName { modelButton.title = modelName }
        modelButton.toolTip = modelName
        modelButton.setAccessibilityValue(modelName)
        modelButton.isEnabled = enabled
        if providerButton.image !== icon { providerButton.image = icon }
        providerButton.setAccessibilityValue(provider?.title)
        providerButton.isEnabled = enabled && canBrowseProviders
        let contextChanged = self.effortContext != effortContext
        guard contextChanged || model != next || self.enabled != enabled || self.promptEffort != promptEffort else { return }
        model = next
        self.enabled = enabled
        self.promptEffort = promptEffort
        self.effortContext = effortContext
        renderEffort(animated: !contextChanged)
        renderSpeed()
    }

    private var extraOptions: [ComposerModelOption] {
        let ultracode = promptEffort ? nil : model.ultracodeToggle?.id
        return model.descriptors.filter { $0.id != model.reasoning?.id && $0.id != model.speed?.id && $0.id != ultracode }
    }

    private func isPromptControlled(_ option: ComposerModelOption) -> Bool {
        promptEffort && option.id == model.reasoning?.id
    }

    private func title(for option: ComposerModelOption) -> String {
        isPromptControlled(option) ? (model.reasoningTitle(promptEffort: true) ?? option.title) : model.title(for: option)
    }

    private func renderEffort(animated: Bool) {
        readout.isHidden = model.reasoning == nil
        headerHeight.constant = readout.isHidden ? 27 : 40
        guard let option = model.reasoning else { slider.isHidden = true; return }
        let title = title(for: option)
        let locked = isPromptControlled(option)
        let levels = model.effortLevels(for: option)
        let lit = model.effortDots(for: option)?.lit ?? 0
        readout.toolTip = locked ? "Ultrathink is set by your prompt." : option.description
        readout.render(title, levels: locked || lit == 0 ? [] : levels.map(\.title),
                       index: max(0, lit - 1), color: locked ? WorkspaceStyle.secondary : WorkspaceStyle.modelFocus,
                       animated: animated)
        readout.isEnabled = enabled && (!locked || !extraOptions.isEmpty)

        slider.isHidden = locked || levels.count < 2
        guard !slider.isHidden else { return }
        slider.render(levelCount: levels.count, index: lit > 0 ? lit - 1 : nil, enabled: enabled, animated: animated)
        slider.setAccessibilityValueDescription(title)
    }

    private func renderSpeed() {
        let option = model.speed
        let extras = model.reasoning == nil ? extraOptions : []
        speed.isHidden = option == nil && extras.isEmpty
        guard !speed.isHidden else { return }
        let menu = option.map(menu(for:)) ?? NSMenu(title: "Model options")
        menu.autoenablesItems = false
        appendOptions(extras, to: menu)
        let caption = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let value = option.flatMap { model.override(for: $0) ?? $0.defaultValue }
        let fast = value == .bool(true) || value == .string("fast") || value == .string("priority")
        let symbol = fast ? "bolt.fill" : "bolt"
        caption.image = WorkspaceStyle.symbol(option == nil ? "slider.horizontal.3" : symbol, size: 14)
        speed.contentTintColor = fast ? WorkspaceStyle.modelFocus : WorkspaceStyle.secondary
        menu.insertItem(caption, at: 0)
        speed.menu = menu
        speed.selectItem(at: 0)
        let title = option.map { model.title(for: $0) }
        speed.setAccessibilityLabel(option == nil ? "Model options" : "Speed")
        speed.setAccessibilityValue(title)
        let detail = title.map { "Speed · \($0)" } ?? "Model options"
        speed.toolTip = option?.description.map { detail + "\n" + $0 } ?? detail
        speed.isEnabled = enabled
    }

    private func showEffortMenu() {
        guard readout.isEnabled, let menu = effortMenu() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: readout.bounds.height), in: readout)
    }

    private func effortMenu() -> NSMenu? {
        guard let option = model.reasoning else { return nil }
        let menu = menu(for: option)
        appendOptions(extraOptions, to: menu)
        return menu
    }

    @objc private func pickEffort(_ sender: NSSlider) {
        guard enabled, let option = model.reasoning, !isPromptControlled(option) else { return }
        let levels = model.effortLevels(for: option)
        let index = sender.integerValue
        guard levels.indices.contains(index) else { return }
        onPick?(option.id, levels[index].value)
    }

    private func menu(for option: ComposerModelOption) -> NSMenu {
        let menu = NSMenu(title: option.title)
        menu.autoenablesItems = false
        let override = model.override(for: option)
        menu.addItem(choice("Use Provider Default", option: option, value: nil, selected: override == nil,
                            description: option.description))
        menu.addItem(.separator())
        let choices = isPromptControlled(option) ? option.choices : model.choices(for: option)
        for candidate in choices {
            menu.addItem(choice(candidate.title, option: option, value: candidate.value,
                                selected: override == candidate.value, description: candidate.description))
        }
        return menu
    }

    private func choice(_ title: String, option: ComposerModelOption, value: Wire?, selected: Bool,
                        description: String?) -> NSMenuItem {
        let item = menuItem(title, target: self, action: #selector(pick(_:)))
        item.representedObject = Pick(optionID: option.id, value: value)
        item.state = selected ? .on : .off
        item.toolTip = description
        item.isEnabled = enabled && !isPromptControlled(option)
        return item
    }

    private func appendOptions(_ options: [ComposerModelOption], to menu: NSMenu) {
        if !options.isEmpty && !menu.items.isEmpty { menu.addItem(.separator()) }
        for option in options {
            let item = NSMenuItem(title: "\(option.title) · \(title(for: option))", action: nil, keyEquivalent: "")
            item.submenu = self.menu(for: option)
            item.toolTip = option.description
            menu.addItem(item)
        }
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? Pick, enabled,
              let option = model.descriptors.first(where: { $0.id == pick.optionID }), !isPromptControlled(option) else { return }
        onPick?(pick.optionID, pick.value)
    }
}

@MainActor
private final class EffortReadout: NSControl {
    private let button: ActionButton
    private let words = CALayer()
    private var titles: [String] = []
    private var labels: [CATextLayer] = []
    private var selectedIndex = 0
    private let titleFont = NSFont.systemFont(ofSize: 14, weight: .medium)
    private var textColor = WorkspaceStyle.modelFocus

    init(action: @escaping () -> Void) {
        button = ActionButton("Effort", iconOnly: true, style: .subtle, action: action)
        super.init(frame: .zero)
        wantsLayer = true
        words.masksToBounds = true
        layer?.addSublayer(words)
        fill(button, in: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isEnabled: Bool { didSet { button.isEnabled = isEnabled } }

    override var intrinsicContentSize: NSSize {
        let width = titles.map { ($0 as NSString).size(withAttributes: [.font: titleFont]).width }.max() ?? 0
        return NSSize(width: ceil(width) + 10, height: 21)
    }

    func render(_ title: String, levels: [String], index: Int, color: NSColor, animated: Bool) {
        let next = levels.isEmpty ? [title] : levels
        let index = levels.isEmpty ? 0 : index
        let previous = selectedIndex
        let sameLevels = titles == next
        selectedIndex = index
        button.setAccessibilityValue(title)
        button.toolTip = toolTip
        textColor = color
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !sameLevels {
            titles = next
            words.sublayers = nil
            labels = next.map { word in
                let label = CATextLayer()
                label.string = word
                label.font = titleFont
                label.fontSize = titleFont.pointSize
                label.alignmentMode = .center
                words.addSublayer(label)
                return label
            }
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
        CATransaction.commit()
        updateColors()
        if !animated || !sameLevels || index != previous {
            positionLabels(animated: animated && sameLevels && window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for label in labels { label.foregroundColor = textColor.cgColor }
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        let size = bounds.size
        guard words.frame.size != size else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        words.frame = bounds
        CATransaction.commit()
        positionLabels(animated: false)
    }

    private func positionLabels(animated: Bool) {
        let scale = window?.backingScaleFactor ?? 2
        let lineHeight = ceil(titleFont.ascender - titleFont.descender)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, label) in labels.enumerated() {
            let position = words.bounds.midY + CGFloat(selectedIndex - index) * lineHeight * 0.67
            let opacity: Float = index == selectedIndex ? 1 : 0
            let previous = label.presentation() ?? label
            let startY = previous.position.y
            let startOpacity = previous.opacity
            label.contentsScale = scale
            label.bounds.size = NSSize(width: words.bounds.width, height: lineHeight)
            label.position = CGPoint(x: words.bounds.midX, y: position)
            label.opacity = opacity
            if animated {
                label.add(effortSpring("position.y", from: startY, to: position, stiffness: 300, damping: 27), forKey: "roll")
                label.add(effortSpring("opacity", from: startOpacity, to: opacity, stiffness: 300, damping: 27), forKey: "fade")
            } else {
                label.removeAllAnimations()
            }
        }
        CATransaction.commit()
    }
}

@MainActor
private func effortSpring(_ keyPath: String, from: Any, to: Any, stiffness: CGFloat, damping: CGFloat) -> CASpringAnimation {
    let animation = CASpringAnimation(keyPath: keyPath)
    animation.mass = 1
    animation.stiffness = stiffness
    animation.damping = damping
    animation.fromValue = from
    animation.toValue = to
    animation.duration = animation.settlingDuration
    return animation
}

@MainActor
private final class EffortSlider: NSSlider {
    private let rail = CALayer()
    private let fill = CALayer()
    private let inactiveDots = CAShapeLayer()
    private let activeDots = CAShapeLayer()
    private let thumb = CALayer()
    private var selectedIndex: Int?
    private var laidOutTickCount = 0
    private var dragOffset: CGFloat?
    private var draggedX: CGFloat?
    private var pressed = false
    private var hovered = false
    private var tracking: NSTrackingArea?

    override var knobThickness: CGFloat { 28 }

    private var railFrame: NSRect {
        NSRect(x: bounds.minX, y: bounds.midY - 12, width: bounds.width, height: 24)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        rail.cornerRadius = 12
        rail.masksToBounds = true
        rail.borderWidth = 0.5
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        fill.masksToBounds = true
        thumb.bounds.size = CGSize(width: 28, height: 28)
        thumb.cornerRadius = 14
        thumb.borderWidth = 0.5
        fill.isHidden = true
        thumb.isHidden = true
        rail.addSublayer(inactiveDots)
        rail.addSublayer(fill)
        fill.addSublayer(activeDots)
        layer?.addSublayer(rail)
        layer?.addSublayer(thumb)
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func render(levelCount: Int, index: Int?, enabled: Bool, animated: Bool) {
        let levelsChanged = levelCount != numberOfTickMarks
        let selectionChanged = index != selectedIndex
        let animate = animated && selectionChanged && selectedIndex != nil && index != nil && !levelsChanged &&
            dragOffset == nil && canAnimate
        selectedIndex = index
        if !animated || levelsChanged { resetPointer() }
        if levelsChanged {
            maxValue = Double(levelCount - 1)
            numberOfTickMarks = levelCount
            needsLayout = true
        }
        if integerValue != (index ?? 0) { integerValue = index ?? 0 }
        if isEnabled != enabled {
            isEnabled = enabled
            if !enabled { resetPointer() }
            updateColors()
        }
        if selectionChanged || levelsChanged || !animated { updateIndicator(animated: animate) }
    }

    override func layout() {
        super.layout()
        let frame = railFrame
        guard frame != rail.frame || laidOutTickCount != numberOfTickMarks else { return }
        laidOutTickCount = numberOfTickMarks
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rail.frame = frame
        fill.position = CGPoint(x: 0, y: rail.bounds.midY)
        inactiveDots.frame = rail.bounds
        activeDots.frame = rail.bounds
        let marks = CGMutablePath()
        let steps = CGFloat(max(1, numberOfTickMarks - 1))
        for index in 0..<numberOfTickMarks {
            let x = position(CGFloat(index) / steps, in: rail.bounds)
            marks.addEllipse(in: CGRect(x: x - 2, y: rail.bounds.midY - 2, width: 4, height: 4))
        }
        inactiveDots.path = marks
        activeDots.path = marks
        CATransaction.commit()
        updateIndicator(animated: false)
    }

    override func draw(_ dirtyRect: NSRect) {}

    override var focusRingMaskBounds: NSRect { railFrame }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: railFrame, xRadius: 12, yRadius: 12).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        tracking = area
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) { updateHover(with: event) }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        updateThumbScale()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        pressed = true
        let point = convert(event.locationInWindow, from: nil)
        let visibleThumb = (thumb.presentation() ?? thumb).frame
        if !thumb.isHidden, visibleThumb.contains(point) {
            let x = (thumb.presentation() ?? thumb).position.x
            dragOffset = point.x - x
            draggedX = x
            updateIndicator(animated: false)
        } else { select(at: point.x) }
        updateThumbScale()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, let dragOffset else { return }
        let x = convert(event.locationInWindow, from: nil).x - dragOffset
        draggedX = min(position(1, in: bounds), max(position(0, in: bounds), x))
        select(at: x)
        updateIndicator(animated: false)
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragging = draggedX != nil
        resetPointer()
        if wasDragging { updateIndicator(animated: canAnimate) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            resetPointer()
            updateIndicator(animated: false)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .leftArrow, .downArrow: _ = step(by: -1)
        case .rightArrow, .upArrow: _ = step(by: 1)
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformIncrement() -> Bool { step(by: 1) }

    override func accessibilityPerformDecrement() -> Bool { step(by: -1) }

    private func select(at x: CGFloat) {
        let start = position(0, in: bounds)
        let end = position(1, in: bounds)
        let fraction = Double((x - start) / max(1, end - start))
        select(minValue + fraction * (maxValue - minValue))
    }

    private func step(by amount: Double) -> Bool {
        guard isEnabled else { return false }
        select(selectedIndex == nil ? minValue : doubleValue + amount)
        return true
    }

    private func select(_ value: Double) {
        let tick = closestTickMarkValue(toValue: min(maxValue, max(minValue, value)))
        guard tick != doubleValue || selectedIndex == nil else { return }
        doubleValue = tick
        sendAction(action, to: target)
    }

    private func updateIndicator(animated: Bool) {
        let progress = CGFloat(selectedIndex ?? 0) / CGFloat(max(1, numberOfTickMarks - 1))
        let x = draggedX ?? position(progress, in: rail.frame)
        let width = max(0, x - rail.frame.minX)
        let previousWidth = (fill.presentation() ?? fill).bounds.width
        let previousX = (thumb.presentation() ?? thumb).position.x
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.bounds.size = CGSize(width: width, height: rail.bounds.height)
        thumb.position = CGPoint(x: x, y: rail.frame.midY)
        fill.isHidden = selectedIndex == nil
        thumb.isHidden = selectedIndex == nil
        CATransaction.commit()
        if animated {
            fill.add(effortSpring("bounds.size.width", from: previousWidth, to: width, stiffness: 300, damping: 27),
                     forKey: "bounds.size.width")
            thumb.add(effortSpring("position.x", from: previousX, to: x, stiffness: 300, damping: 27), forKey: "position.x")
        } else {
            stopAnimations()
        }
    }

    private var canAnimate: Bool {
        window != nil && rail.bounds.width > 0 && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func updateHover(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let next = isEnabled && !thumb.isHidden && (thumb.presentation() ?? thumb).frame.contains(point)
        guard hovered != next else { return }
        hovered = next
        updateThumbScale()
    }

    private func resetPointer() {
        dragOffset = nil
        draggedX = nil
        pressed = false
        hovered = false
        updateThumbScale()
    }

    private func updateThumbScale() {
        let raised = isEnabled && (pressed || hovered)
        let scale: CGFloat = canAnimate && raised ? 32 / 28 : 1
        let before = thumb.presentation()?.transform.m11 ?? thumb.transform.m11
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumb.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
        if canAnimate && before != scale {
            thumb.add(effortSpring("transform.scale", from: before, to: scale,
                                   stiffness: raised ? 420 : 220, damping: raised ? 38 : 26), forKey: "scale")
        } else { thumb.removeAnimation(forKey: "scale") }
    }

    private func stopAnimations() {
        fill.removeAnimation(forKey: "bounds.size.width")
        thumb.removeAnimation(forKey: "position.x")
    }

    private func updateColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            rail.backgroundColor = WorkspaceStyle.ink.withAlphaComponent(0.10).cgColor
            rail.borderColor = WorkspaceStyle.ink.withAlphaComponent(0.08).cgColor
            fill.backgroundColor = WorkspaceStyle.effortFill.withAlphaComponent(isEnabled ? 1 : 0.45).cgColor
            inactiveDots.fillColor = WorkspaceStyle.secondary.withAlphaComponent(0.40).cgColor
            activeDots.fillColor = NSColor.white.withAlphaComponent(0.45).cgColor
            thumb.backgroundColor = NSColor.white.withAlphaComponent(isEnabled ? 1 : 0.6).cgColor
            thumb.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
        }
        CATransaction.commit()
    }

    private func position(_ fraction: CGFloat, in bounds: NSRect) -> CGFloat {
        let inset = min(13, bounds.width / 2)
        return bounds.minX + inset + fraction * (bounds.width - 2 * inset)
    }
}
