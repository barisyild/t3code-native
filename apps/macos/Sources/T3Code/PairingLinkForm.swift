import AppKit

@MainActor
final class PairingLinkForm: NSView {
    private let name = NSTextField()
    private let endpoint = NSPopUpButton()
    private let addresses: [PairingAddress]
    private var permissions: PairingPermissions
    private var checkboxes: [PairingScope: NSButton] = [:]
    var onPermissionsChange: ((Bool) -> Void)?

    init(addresses: [PairingAddress], permissions: PairingPermissions) {
        self.addresses = addresses
        self.permissions = permissions
        let scopes = PairingScope.allCases.filter(permissions.available.contains)
        let half = (scopes.count + 1) / 2
        super.init(frame: NSRect(x: 0, y: 0, width: 452, height: 110 + CGFloat(half) * 23))

        name.placeholderString = "Device name (optional)"
        name.setAccessibilityLabel("Device Name")
        endpoint.setAccessibilityLabel("Pairing Address")
        endpoint.addItems(withTitles: addresses.map(\.title))
        endpoint.cell?.lineBreakMode = .byTruncatingMiddle
        for scope in scopes {
            let checkbox = NSButton(checkboxWithTitle: scope.title, target: self, action: #selector(toggle(_:)))
            checkbox.identifier = NSUserInterfaceItemIdentifier(scope.rawValue)
            checkbox.controlSize = .small
            checkbox.font = .systemFont(ofSize: 12)
            checkboxes[scope] = checkbox
        }
        let first = column(scopes.prefix(half).compactMap { checkboxes[$0] }, spacing: 5)
        let second = column(scopes.dropFirst(half).compactMap { checkboxes[$0] }, spacing: 5)
        let grid = row([first, second, NSView()], spacing: 15)
        grid.alignment = .top
        first.widthAnchor.constraint(equalToConstant: 215).isActive = true
        let readOnly = ActionButton("Read Only") { [weak self] in
            self?.permissions.readOnly()
            self?.render()
        }
        let standard = ActionButton("Standard") { [weak self] in
            self?.permissions.standard()
            self?.render()
        }
        let presets = row([label("Permissions", size: 12, weight: .semibold), NSView(), readOnly, standard], spacing: 6)
        fill(column([name, endpoint, presets, grid], spacing: 8, alignment: .width), in: self)
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var labelText: String { name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    var scopes: [String] { permissions.scopes }
    var address: PairingAddress? {
        addresses.indices.contains(endpoint.indexOfSelectedItem) ? addresses[endpoint.indexOfSelectedItem] : nil
    }
    var firstResponder: NSView { name }

    @objc private func toggle(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let scope = PairingScope(rawValue: id) else { return }
        permissions.set(scope, enabled: sender.state == .on)
        render()
    }

    private func render() {
        for (scope, checkbox) in checkboxes {
            checkbox.state = permissions.selected.contains(scope) ? .on : .off
        }
        onPermissionsChange?(!scopes.isEmpty)
    }
}
