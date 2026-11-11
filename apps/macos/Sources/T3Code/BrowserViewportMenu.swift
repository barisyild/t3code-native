import AppKit

@MainActor
enum BrowserViewportMenu {
    static func make(current: BrowserViewportSetting, enabled: Bool, target: AnyObject,
                     select: Selector, custom: Selector) -> NSMenu {
        let menu = NSMenu(title: "Viewport")
        menu.autoenablesItems = false
        func choice(_ title: String, _ setting: BrowserViewportSetting, selected: Bool) -> NSMenuItem {
            let item = menuItem(title, target: target, action: select)
            item.representedObject = setting
            item.isEnabled = enabled
            item.state = selected ? .on : .off
            return item
        }

        menu.addItem(choice("Fill Panel", .fill, selected: current == .fill))
        menu.addItem(.separator())
        for group in BrowserViewportPreset.Group.allCases {
            let submenu = NSMenu(title: group.rawValue)
            submenu.autoenablesItems = false
            let presets = BrowserViewportPreset.all.filter { $0.group == group }
            for preset in presets {
                submenu.addItem(choice(preset.setting.title, preset.setting, selected: current.presetID == preset.id))
            }
            let item = NSMenuItem(title: group.rawValue, action: nil, keyEquivalent: "")
            item.submenu = submenu
            item.isEnabled = enabled
            item.state = presets.contains { $0.id == current.presetID } ? .on : .off
            menu.addItem(item)
        }
        if let size = BrowserViewportSize(width: 1_440, height: 900) {
            let desktop = BrowserViewportSetting.fixed(size, presetID: "desktop-1440x900")
            menu.addItem(choice(desktop.title, desktop, selected: current.presetID == desktop.presetID))
        }
        menu.addItem(.separator())
        let customSize = menuItem("Custom Size…", target: target, action: custom)
        customSize.state = current.size != nil && current.presetID == nil ? .on : .off
        customSize.isEnabled = enabled
        menu.addItem(customSize)
        if let rotated = current.rotated {
            menu.addItem(choice("Rotate", rotated, selected: false))
        }
        return menu
    }
}

@MainActor
final class BrowserViewportEditor: NSObject, NSTextFieldDelegate {
    private let alert: NSAlert
    private let width = NSTextField()
    private let height = NSTextField()
    private let problem = NSTextField(wrappingLabelWithString: "")
    private let commit: NSButton

    private init(size: BrowserViewportSize) {
        let prompt = NSAlert()
        prompt.messageText = "Custom Browser Size"
        alert = prompt
        commit = prompt.addButton(withTitle: "Apply Size")
        prompt.addButton(withTitle: "Cancel")
        super.init()
        width.stringValue = String(size.width)
        height.stringValue = String(size.height)
        problem.font = .systemFont(ofSize: 11)
        problem.textColor = WorkspaceStyle.negative
        problem.maximumNumberOfLines = 2
        let dimensions = row([field("Width (px)", width), field("Height (px)", height)], spacing: 10)
        dimensions.distribution = .fillEqually
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 307, height: 80))
        fill(column([dimensions, problem, NSView()], spacing: 6, alignment: .width), in: accessory)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = width
        validate()
    }

    static func chooseSize(_ current: BrowserViewportSize?, in window: NSWindow) async -> BrowserViewportSize? {
        guard window.attachedSheet == nil else { return nil }
        let editor = BrowserViewportEditor(size: current ?? .customDefault)
        let response = await editor.alert.beginSheetModal(for: window)
        return response == .alertFirstButtonReturn ? editor.size : nil
    }

    private var size: BrowserViewportSize? {
        guard let width = Int(width.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let height = Int(height.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return BrowserViewportSize(width: width, height: height)
    }

    private func field(_ name: String, _ field: NSTextField) -> NSView {
        field.setAccessibilityLabel(name)
        field.delegate = self
        return column([label(name, size: 11, color: WorkspaceStyle.muted), field], spacing: 4, alignment: .width)
    }

    func controlTextDidChange(_ notification: Notification) { validate() }

    private func validate() {
        let valid = size != nil
        commit.isEnabled = valid
        problem.stringValue = valid ? "" : "Enter 240 to 3,840 pixels per side, up to 8,294,400 pixels total."
    }
}
