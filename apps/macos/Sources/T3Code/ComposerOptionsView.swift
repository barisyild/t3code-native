import AppKit

@MainActor
final class ComposerOptionsView: NSStackView {
    private struct Pick {
        let optionID: String
        let value: Wire?
    }

    private let reasoning = NSPopUpButton(frame: .zero, pullsDown: true)
    private let speed = NSPopUpButton(frame: .zero, pullsDown: true)
    private let ticks = NSStackView()
    private let track = Surface(WorkspaceStyle.composer, radius: 12)
    private let separator = Surface(WorkspaceStyle.outline)
    private let filler = NSView()
    private var effortWidth: NSLayoutConstraint?
    private lazy var effort = column([
        row([label("Effort", size: 11.5, weight: .medium, color: WorkspaceStyle.secondary), NSView(), reasoning], spacing: 4),
        track,
    ], spacing: 4, alignment: .width)
    private lazy var overflow = ActionButton("More model options", symbol: "slider.horizontal.3", iconOnly: true, style: .subtle) {
        [weak self] in self?.showOptions()
    }
    private var model = ComposerModelOptions()
    private var enabled = false
    private var promptEffort = false
    var onPick: ((String, Wire?) -> Void)?

    var preferredHeight: CGFloat { isHidden ? 0 : track.isHidden ? 28 : 50 }

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 7
        distribution = .fill
        for popup in [reasoning, speed] {
            popup.isBordered = false
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: 12, weight: .medium)
            popup.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        reasoning.heightAnchor.constraint(equalToConstant: 22).isActive = true
        reasoning.contentTintColor = WorkspaceStyle.modelFocus
        speed.imagePosition = .imageOnly
        for control in [speed as NSView, overflow] {
            control.widthAnchor.constraint(equalToConstant: 29).isActive = true
            control.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        ticks.orientation = .horizontal
        ticks.alignment = .centerY
        ticks.distribution = .fillEqually
        ticks.spacing = 0
        track.heightAnchor.constraint(equalToConstant: 24).isActive = true
        fill(ticks, in: track)
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 28).isActive = true
        for view in [effort as NSView, filler, separator, speed, overflow] { addArrangedSubview(view) }
        effortWidth = effort.widthAnchor.constraint(equalTo: widthAnchor)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func render(_ next: ComposerModelOptions, enabled: Bool, promptEffort: Bool, visible: Bool) {
        let hidden = !visible || next.descriptors.isEmpty
        guard model != next || self.enabled != enabled || self.promptEffort != promptEffort || isHidden != hidden else { return }
        model = next
        self.enabled = enabled
        self.promptEffort = promptEffort
        isHidden = hidden
        guard visible else { return }
        effort.isHidden = model.reasoning == nil
        filler.isHidden = !effort.isHidden
        configure(reasoning, option: model.reasoning)
        configure(speed, option: model.speed)
        updateTicks()
        overflow.isHidden = extraOptions.isEmpty
        overflow.isEnabled = enabled
        separator.isHidden = effort.isHidden || (speed.isHidden && overflow.isHidden)
        let trailing = (speed.isHidden ? 0 : 36) + (overflow.isHidden ? 0 : 36) + (separator.isHidden ? 0 : 8)
        effortWidth?.constant = -CGFloat(trailing)
        effortWidth?.isActive = !effort.isHidden
    }

    private var extraOptions: [ComposerModelOption] {
        model.descriptors.filter { $0.id != model.reasoning?.id && $0.id != model.speed?.id }
    }

    private func isPromptControlled(_ option: ComposerModelOption) -> Bool {
        promptEffort && option.id == model.reasoning?.id
    }

    private func title(for option: ComposerModelOption) -> String {
        isPromptControlled(option) ? "Ultrathink" : model.title(for: option)
    }

    private func configure(_ popup: NSPopUpButton, option: ComposerModelOption?) {
        popup.isHidden = option == nil
        guard let option else { return }
        let title = title(for: option)
        let menu = menu(for: option)
        let caption = NSMenuItem(title: option.isSpeed ? "" : title, action: nil, keyEquivalent: "")
        if option.isSpeed {
            let value = model.override(for: option) ?? option.defaultValue
            let fast = value == .bool(true) || value == .string("fast") || value == .string("priority")
            caption.image = WorkspaceStyle.symbol(fast ? "bolt.fill" : "bolt", size: 14)
            popup.contentTintColor = fast ? WorkspaceStyle.modelFocus : WorkspaceStyle.secondary
        }
        menu.insertItem(caption, at: 0)
        popup.menu = menu
        popup.selectItem(at: 0)
        let name = option.isSpeed ? "Speed" : "Effort"
        popup.setAccessibilityLabel(name)
        popup.setAccessibilityValue(title)
        let detail = "\(name) · \(title)"
        let explanation = isPromptControlled(option) ? "Ultrathink is set by your prompt." : option.description
        popup.toolTip = explanation.map { detail + "\n" + $0 } ?? detail
        popup.isEnabled = enabled && !isPromptControlled(option)
    }

    private func updateTicks() {
        ticks.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let option = model.reasoning else { track.isHidden = true; return }
        let levels = option.effortLevels
        track.isHidden = levels.isEmpty || isPromptControlled(option)
        guard !track.isHidden else { return }
        let lit = model.effortDots(for: option)?.lit ?? 0
        for (index, level) in levels.enumerated() {
            let current = index == lit - 1
            let symbol = current ? "circle.inset.filled" : index < lit ? "circle.fill" : "circle"
            let dot = ActionButton(level.title, symbol: symbol, iconOnly: true, style: .subtle) { [weak self] in
                guard let self, enabled, !isPromptControlled(option) else { return }
                onPick?(option.id, level.value)
            }
            dot.image = WorkspaceStyle.symbol(symbol, size: current ? 11 : 7, weight: .semibold)
            dot.contentTintColor = index < lit ? WorkspaceStyle.modelFocus : WorkspaceStyle.muted
            dot.heightAnchor.constraint(equalToConstant: 24).isActive = true
            dot.isEnabled = enabled
            dot.setAccessibilityLabel("\(level.title) effort")
            dot.setAccessibilityValue(current ? "Selected" : nil)
            dot.toolTip = level.description ?? "\(level.title) effort"
            ticks.addArrangedSubview(dot)
        }
    }

    private func menu(for option: ComposerModelOption) -> NSMenu {
        let menu = NSMenu(title: option.title)
        menu.autoenablesItems = false
        let override = model.override(for: option)
        menu.addItem(choice("Use Provider Default", option: option, value: nil, selected: override == nil,
                            description: option.description))
        menu.addItem(.separator())
        for candidate in option.choices {
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

    private func showOptions() {
        guard enabled else { return }
        let menu = NSMenu(title: "Model options")
        menu.autoenablesItems = false
        for option in extraOptions {
            let item = NSMenuItem(title: "\(option.title) · \(title(for: option))", action: nil, keyEquivalent: "")
            item.submenu = self.menu(for: option)
            item.toolTip = option.description
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: overflow.bounds.height), in: overflow)
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? Pick, enabled,
              let option = model.descriptors.first(where: { $0.id == pick.optionID }), !isPromptControlled(option) else { return }
        onPick?(pick.optionID, pick.value)
    }
}
