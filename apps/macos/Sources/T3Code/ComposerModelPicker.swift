import AppKit

@MainActor
final class ComposerModelPicker: NSView, NSPopoverDelegate {
    private struct MenuState: Equatable {
        let family: ComposerProvider?
        let available: Set<ComposerProvider>
        let groups: [ComposerModels.Group]
        let details: ComposerModels.GroupKey?
        let selection: Wire
    }

    private lazy var trigger = ActionButton("Model settings", style: .subtle) { [weak self] in self?.toggle() }
    private let popoverAnchor = NSView()
    private let options = ComposerOptionsView()
    private lazy var icons = Dictionary(uniqueKeysWithValues: ComposerProvider.allCases.map { ($0, WorkspaceStyle.providerIcon($0)) })
    private var catalog = ComposerModels(providers: [])
    private var selection: Wire = .null
    private var preferred: Wire = .null
    private var modelOptions = ComposerModelOptions()
    private var promptEffort = false
    private var showingModels = false
    private var browsing: ComposerProvider?
    private var details: ComposerModels.GroupKey?
    private var rendered: MenuState?
    private var popover: NSPopover?
    var onPickModel: ((Wire) -> Void)?
    var onPickOption: ((String, Wire?) -> Void)?

    var canOpen: Bool { trigger.isEnabled }

    init() {
        super.init(frame: .zero)
        trigger.font = .systemFont(ofSize: 12.5, weight: .medium)
        trigger.imagePosition = .imageLeading
        trigger.cell?.lineBreakMode = .byTruncatingTail
        trigger.heightAnchor.constraint(equalToConstant: 28).isActive = true
        trigger.widthAnchor.constraint(lessThanOrEqualToConstant: 192).isActive = true
        trigger.isEnabled = false
        addSubview(popoverAnchor)
        popoverAnchor.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            popoverAnchor.trailingAnchor.constraint(equalTo: trailingAnchor),
            popoverAnchor.topAnchor.constraint(equalTo: topAnchor),
            popoverAnchor.bottomAnchor.constraint(equalTo: bottomAnchor),
            popoverAnchor.widthAnchor.constraint(equalToConstant: 24),
        ])
        fill(trigger, in: self)
        options.onPick = { [weak self] id, value in self?.onPickOption?(id, value) }
        options.onBrowseModels = { [weak self] in self?.showModels() }
        options.onBrowseProviders = { [weak self] anchor in
            guard let self, canOpen else { return }
            providerMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height), in: anchor)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func render(catalog: ComposerModels, selection: Wire, preferred: Wire, options: ComposerModelOptions, enabled: Bool, promptEffort: Bool) {
        self.catalog = catalog
        self.selection = selection
        self.preferred = preferred
        modelOptions = options
        self.promptEffort = promptEffort
        let family = catalog.family(for: selection)
        let name = catalog.pickerTitle(for: selection) ?? "Select model"
        let effort = options.reasoningTitle(promptEffort: promptEffort)
        let value = [name, effort].compactMap { $0 }.joined(separator: " ")
        let available = enabled && (selection != .null || ComposerProvider.allCases.contains(where: catalog.isAvailable))
        let title = NSMutableAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
            .foregroundColor: available ? WorkspaceStyle.ink : WorkspaceStyle.muted,
        ])
        title.append(NSAttributedString(string: effort.map { " \($0)  ⌄" } ?? "  ⌄", attributes: [
            .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: WorkspaceStyle.muted,
        ]))
        if !trigger.attributedTitle.isEqual(to: title) { trigger.attributedTitle = title }
        let icon = family.flatMap { icons[$0] } ?? WorkspaceStyle.symbol("cpu", size: 14)
        if trigger.image !== icon { trigger.image = icon }
        trigger.toolTip = family.map { "\($0.title) · \(value)" } ?? value
        trigger.setAccessibilityValue(value)
        trigger.isEnabled = available
        if !canOpen { close() }
        else if popover?.isShown == true { updateMenu() }
    }

    func show() {
        guard canOpen, trigger.window != nil, popover?.isShown != true else { return }
        showingModels = false
        browsing = nil
        details = nil
        let controller = NSViewController()
        controller.view = Surface(WorkspaceStyle.modelPanel)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = controller
        self.popover = popover
        rendered = nil
        updateMenu()
        popover.show(relativeTo: popoverAnchor.bounds, of: popoverAnchor, preferredEdge: .maxY)
    }

    func close() {
        let closing = popover
        popover = nil
        rendered = nil
        closing?.close()
    }

    func popoverDidClose(_ notification: Notification) {
        if let closed = notification.object as? NSPopover, closed === popover {
            popover = nil
            rendered = nil
        }
    }

    private func toggle() {
        if popover?.isShown == true { close() }
        else { show() }
    }

    private func updateMenu() {
        guard let popover, let controller = popover.contentViewController else { return }
        let available = Set(ComposerProvider.allCases.filter(catalog.isAvailable))
        let current = catalog.family(for: selection)
        if !showingModels {
            options.render(modelOptions, modelName: catalog.pickerTitle(for: selection) ?? "Select model",
                           provider: current, icon: current.flatMap { icons[$0] } ?? trigger.image ?? NSImage(),
                           canBrowseProviders: !available.isEmpty, enabled: canOpen, promptEffort: promptEffort,
                           effortContext: modelWithoutOptions(selection))
            let content = controller.view
            let inset: CGFloat = 9
            if options.superview !== content {
                content.subviews.forEach { $0.removeFromSuperview() }
                fill(options, in: content, inset: inset)
            }
            let size = NSSize(width: 248, height: options.preferredHeight + 2 * inset)
            if popover.contentSize != size {
                controller.preferredContentSize = size
                popover.contentSize = size
            }
            rendered = nil
            return
        }

        if let browsing, browsing != current && !available.contains(browsing) {
            self.browsing = current
            details = nil
        }
        let listing = browsing.flatMap { family in
            family == current ? nil : catalog.defaultSelection(for: family, preferred: preferred)
        } ?? selection
        let groups = catalog.groups(preserving: modelWithoutOptions(listing))
        let group = details.flatMap { key in groups.first { $0.key == key } }
        let state = MenuState(family: browsing, available: available, groups: groups, details: group?.key,
                              selection: modelWithoutOptions(selection))
        guard state != rendered else { return }
        rendered = state

        let controls: [NSView] = ComposerProvider.allCases.map { family in
            let selected = browsing == family
            let button = ActionButton(family.title, iconOnly: true, style: .subtle) { [weak self] in self?.browse(family) }
            button.image = icons[family]
            button.imagePosition = .imageOnly
            button.isEnabled = available.contains(family)
            button.setAccessibilityValue(selected ? "Selected" : nil)
            let segment = Surface(selected ? WorkspaceStyle.composer : .clear,
                                  border: selected ? WorkspaceStyle.outline : nil, radius: 8)
            segment.widthAnchor.constraint(equalToConstant: 33).isActive = true
            segment.heightAnchor.constraint(equalToConstant: 28).isActive = true
            fill(button, in: segment)
            return segment
        }
        let leading: NSView
        if let group {
            let back = ActionButton("Models", symbol: "chevron.left", style: .subtle) { [weak self] in
                self?.details = nil
                self?.updateMenu()
            }
            back.font = .systemFont(ofSize: 12)
            leading = row([back, label(group.title, size: 12, weight: .semibold, color: WorkspaceStyle.ink)], spacing: 8)
        } else {
            let back = ActionButton("Models", symbol: "chevron.left", style: .subtle) { [weak self] in
                self?.showingModels = false
                self?.updateMenu()
            }
            back.setAccessibilityLabel("Back to model settings")
            leading = back
        }
        let header = row([leading, NSView()] + controls, spacing: 4)
        header.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let rows = group.map(versionRows) ?? familyRows(groups)
        let listHeight = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * 2
        let list = column(rows.map(\.view), spacing: 2, alignment: .width)
        let body = listHeight > 211 ? scrollingList(list, height: 211) : list
        let sections: [NSView] = [header, divider(), body]
        let layout = column(sections, spacing: 7, alignment: .width)
        let inset: CGFloat = 11
        let width: CGFloat = 306
        layout.widthAnchor.constraint(equalToConstant: width - 2 * inset).isActive = true
        let height = 2 * inset + 29 + min(listHeight, 211) + CGFloat(sections.count - 1) * 7
        let content = controller.view
        content.subviews.forEach { $0.removeFromSuperview() }
        fill(layout, in: content, inset: inset)
        controller.preferredContentSize = NSSize(width: width, height: height)
        popover.contentSize = controller.preferredContentSize
    }

    private func modelWithoutOptions(_ model: Wire) -> Wire {
        guard var fields = model.object else { return model }
        fields["options"] = nil
        return .object(fields)
    }

    private func providerMenu() -> NSMenu {
        let menu = NSMenu(title: "Providers")
        menu.autoenablesItems = false
        let current = catalog.family(for: selection)
        for family in ComposerProvider.allCases {
            let item = menuItem(family.title, target: self, action: #selector(chooseProvider(_:)))
            item.image = icons[family]
            item.representedObject = family.rawValue
            item.state = current == family ? .on : .off
            item.isEnabled = catalog.isAvailable(family)
            menu.addItem(item)
        }
        return menu
    }

    @objc private func chooseProvider(_ item: NSMenuItem) {
        guard let value = item.representedObject as? String, let family = ComposerProvider(rawValue: value),
              catalog.isAvailable(family) else { return }
        showModels(for: family)
    }

    private func showModels(for family: ComposerProvider? = nil) {
        guard canOpen else { return }
        showingModels = true
        browsing = family ?? catalog.family(for: selection) ?? ComposerProvider.allCases.first(where: catalog.isAvailable)
        details = nil
        updateMenu()
    }

    private func browse(_ family: ComposerProvider) {
        guard catalog.isAvailable(family), family != browsing || details != nil else { return }
        browsing = family
        details = nil
        updateMenu()
    }

    private func familyRows(_ groups: [ComposerModels.Group]) -> [(view: NSView, height: CGFloat)] {
        guard !groups.isEmpty else {
            let note = label("No models available", size: 12, color: WorkspaceStyle.muted)
            note.heightAnchor.constraint(equalToConstant: 29).isActive = true
            return [(note, 29)]
        }
        var rows: [(NSView, CGFloat)] = []
        var instance: String?
        let titles = Dictionary(grouping: groups, by: \.title)
        for group in groups {
            guard let first = group.choices.first else { continue }
            if let heading = group.instanceTitle, heading != instance {
                let account = label(heading, size: 11, weight: .medium, color: WorkspaceStyle.muted)
                account.heightAnchor.constraint(equalToConstant: 18).isActive = true
                rows.append((account, 18))
            }
            instance = group.instanceTitle
            let active = group.choices.first { isSelected($0.selection) }
            let multiple = group.choices.count > 1
            let duplicated = titles[group.title]?.filter { $0.instanceTitle == group.instanceTitle }.count ?? 0
            let detail = duplicated > 1 ? first.selection["model"].string : (active ?? first).version
            let button = menuRow(group.title, detail: detail, symbol: multiple ? "chevron.right" : active != nil ? "checkmark" : nil,
                                 selected: active != nil) { [weak self] in
                guard let self else { return }
                if multiple {
                    details = group.key
                    updateMenu()
                } else { pick(first.selection) }
            }
            rows.append((button, 30))
        }
        return rows
    }

    private func versionRows(_ group: ComposerModels.Group) -> [(view: NSView, height: CGFloat)] {
        let versions = Dictionary(grouping: group.choices, by: \.version)
        return group.choices.map { choice in
            let selected = isSelected(choice.selection)
            let duplicate = (versions[choice.version]?.count ?? 0) > 1
            let button = menuRow(choice.version ?? choice.pickerTitle,
                                 detail: duplicate ? choice.selection["model"].string : nil,
                                 symbol: selected ? "checkmark" : nil, selected: selected) { [weak self] in
                self?.pick(choice.selection)
            }
            button.toolTip = choice.pickerTitle
            return (button, 30)
        }
    }

    private func isSelected(_ model: Wire) -> Bool {
        ComposerModels.instanceID(model) == ComposerModels.instanceID(selection) && model["model"] == selection["model"]
    }

    private func pick(_ model: Wire) {
        guard canOpen else { return }
        showingModels = false
        if !isSelected(model) { onPickModel?(model) }
        updateMenu()
    }

    private func menuRow(_ title: String, detail: String?, symbol: String?, selected: Bool,
                         action: @escaping () -> Void) -> ActionButton {
        let button = ActionButton(title, iconOnly: true, style: .subtle, action: action)
        button.isMarked = selected
        button.setAccessibilityValue(selected ? "Selected" : nil)
        button.setAccessibilityHelp(detail)
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let name = label(title, size: 12.5, weight: selected ? .medium : .regular, color: WorkspaceStyle.ink)
        let version = label(detail ?? "", size: 11.5, color: selected ? WorkspaceStyle.modelFocus : WorkspaceStyle.muted)
        let mark = symbol.map {
            WorkspaceStyle.icon($0, size: 10, tint: $0 == "checkmark" ? WorkspaceStyle.modelFocus : WorkspaceStyle.muted) as NSView
        } ?? NSView()
        mark.widthAnchor.constraint(equalToConstant: 12).isActive = true
        let content = ModelMenuRowContent()
        content.setAccessibilityElement(false)
        fill(row([name, NSView(), version, mark], spacing: 7), in: content, inset: 6)
        fill(content, in: button)
        return button
    }

    private func divider() -> NSView {
        let divider = Surface(WorkspaceStyle.outline)
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return divider
    }

    private func scrollingList(_ list: NSView, height: CGFloat) -> NSView {
        let document = ModelMenuDocument()
        let scroll = scroller(for: document)
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: height),
        ])
        fill(list, in: document)
        return scroll
    }

}

private final class ModelMenuRowContent: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class ModelMenuDocument: NSView {
    override var isFlipped: Bool { true }
}
