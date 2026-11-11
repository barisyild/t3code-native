import AppKit

struct BrowserViewport {
    static func fit(_ viewport: CGSize, in bounds: CGRect) -> CGRect {
        guard viewport.width > 0, viewport.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / viewport.width, bounds.height / viewport.height)
        let size = CGSize(width: viewport.width * scale, height: viewport.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    static func pagePoint(_ point: CGPoint, viewport: CGSize, bounds: CGRect, clamp: Bool) -> CGPoint? {
        let image = fit(viewport, in: bounds)
        guard !image.isEmpty, clamp || image.contains(point) else { return nil }
        return CGPoint(x: min(max(0, (point.x - image.minX) / image.width * viewport.width), viewport.width - 1),
                       y: min(max(0, (point.y - image.minY) / image.height * viewport.height), viewport.height - 1))
    }
}

@MainActor
final class BrowserCanvas: NSView, @preconcurrency NSTextInputClient {
    private struct Key {
        let name: String
        let code: String
        let virtual: Int
    }

    private let composition = label(size: 12, color: WorkspaceStyle.ink)
    private let page = CALayer()
    private var tracking: NSTrackingArea?
    private var imageSize: CGSize = .zero
    private var lastSize: CGSize = .zero
    private var pointer = CGPoint.zero
    private var buttons = 0
    private var keys: [UInt16: Key] = [:]
    private var marked = ""
    private var markedSelection = NSRange(location: 0, length: 0)
    private var interpreting: NSEvent?

    var viewport: CGSize = .zero
    var acceptsInput = false {
        didSet {
            if oldValue && !acceptsInput { keys.removeAll(); buttons = 0; unmarkText() }
        }
    }
    var onInput: ((Payload) -> Void)?
    var onSize: ((CGSize) -> Void)?
    var onCopyRequest: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        page.contentsGravity = .resizeAspect
        layer?.addSublayer(page)
        composition.isHidden = true
        composition.backgroundColor = WorkspaceStyle.composer
        composition.drawsBackground = true
        addSubview(composition)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Remote browser page")
        setAccessibilityHelp("Click the page to focus it when you have browser control.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { acceptsInput }

    func display(_ image: CGImage?) {
        imageSize = image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        page.contents = image
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        page.frame = bounds
        CATransaction.commit()
        let size = CGSize(width: floor(bounds.width), height: floor(bounds.height))
        if size != lastSize {
            lastSize = size
            onSize?(size)
        }
        positionComposition()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect], owner: self, userInfo: nil)
        tracking = area
        addTrackingArea(area)
    }

    override func resignFirstResponder() -> Bool {
        if acceptsInput { for key in keys.values { sendKey(key, action: "up", modifiers: 0) } }
        keys.removeAll()
        unmarkText()
        return super.resignFirstResponder()
    }

    override func mouseMoved(with event: NSEvent) { sendPointer(event, action: "move", button: "none", mask: 0) }
    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseDown(with event: NSEvent) { sendPointer(event, action: "down", button: "left", mask: 1) }
    override func mouseUp(with event: NSEvent) { sendPointer(event, action: "up", button: "left", mask: 1) }
    override func rightMouseDown(with event: NSEvent) { sendPointer(event, action: "down", button: "right", mask: 2) }
    override func rightMouseUp(with event: NSEvent) { sendPointer(event, action: "up", button: "right", mask: 2) }
    override func otherMouseDown(with event: NSEvent) { sendPointer(event, action: "down", button: "middle", mask: 4) }
    override func otherMouseUp(with event: NSEvent) { sendPointer(event, action: "up", button: "middle", mask: 4) }

    private func pagePoint(_ event: NSEvent) -> CGPoint? {
        guard acceptsInput, imageSize != .zero else { return nil }
        pointer = convert(event.locationInWindow, from: nil)
        return BrowserViewport.pagePoint(pointer, viewport: viewport == .zero ? imageSize : viewport, bounds: bounds, clamp: buttons != 0)
    }

    private func sendPointer(_ event: NSEvent, action: String, button: String, mask: Int) {
        guard let point = pagePoint(event) else { return }
        if action == "down" {
            window?.makeFirstResponder(self)
            buttons |= mask
        } else if action == "up" { buttons &= ~mask }
        onInput?([
            "type": .string("mouse"), "action": .string(action), "x": .double(point.x), "y": .double(point.y),
            "button": .string(button), "buttons": .int(buttons), "clickCount": .int(event.clickCount),
            "modifiers": .int(Self.modifiers(event.modifierFlags)),
        ])
    }

    override func scrollWheel(with event: NSEvent) {
        guard let point = pagePoint(event) else { return }
        let scale: Double = event.hasPreciseScrollingDeltas ? 1 : 16
        onInput?([
            "type": .string("wheel"), "x": .double(point.x), "y": .double(point.y),
            "deltaX": .double(-event.scrollingDeltaX * scale), "deltaY": .double(-event.scrollingDeltaY * scale),
            "modifiers": .int(Self.modifiers(event.modifierFlags)),
        ])
    }

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        (flags.contains(.option) ? 1 : 0) | (flags.contains(.control) ? 2 : 0) |
            (flags.contains(.command) ? 4 : 0) | (flags.contains(.shift) ? 8 : 0)
    }

    override func keyDown(with event: NSEvent) {
        guard acceptsInput else { return }
        let shortcut = !event.modifierFlags.intersection([.command, .control]).isEmpty
        if shortcut || (Self.specialKeys[event.keyCode] != nil && !hasMarkedText()) {
            sendKeyDown(event, text: nil)
        } else {
            interpreting = event
            interpretKeyEvents([event])
            interpreting = nil
        }
    }

    override func keyUp(with event: NSEvent) {
        if let key = keys.removeValue(forKey: event.keyCode) {
            sendKey(key, action: "up", modifiers: Self.modifiers(event.modifierFlags))
        }
    }

    private func sendKeyDown(_ event: NSEvent, text: String?) {
        let key: Key
        if let mapped = Self.specialKeys[event.keyCode] { key = mapped }
        else {
            guard let value = text ?? event.charactersIgnoringModifiers, !value.isEmpty else { return }
            let letter = (event.charactersIgnoringModifiers ?? value).uppercased()
            let scalar = letter.unicodeScalars.first
            let ascii = scalar.flatMap { $0.isASCII && letter.count == 1 ? Int($0.value) : nil } ?? 0
            let code = (65...90).contains(ascii) ? "Key\(letter)" : (48...57).contains(ascii) ? "Digit\(letter)" : ""
            key = Key(name: value, code: code, virtual: ascii)
        }
        keys[event.keyCode] = key
        sendKey(key, action: "down", modifiers: Self.modifiers(event.modifierFlags), text: text)
    }

    private func sendKey(_ key: Key, action: String, modifiers: Int, text: String? = nil) {
        var payload: Payload = ["type": .string("key"), "action": .string(action), "key": .string(key.name),
                                "code": .string(key.code), "keyCode": .int(key.virtual), "modifiers": .int(modifiers)]
        if let text { payload["text"] = .string(text) }
        onInput?(payload)
    }

    private func shortcut(_ name: String) {
        guard acceptsInput else { return }
        let key = Key(name: name, code: "Key\(name.uppercased())", virtual: Int(name.uppercased().utf8.first ?? 0))
        sendKey(key, action: "down", modifiers: 4)
        sendKey(key, action: "up", modifiers: 4)
    }

    @objc func copy(_ sender: Any?) { if acceptsInput { onCopyRequest?(); shortcut("c") } }
    @objc func cut(_ sender: Any?) { if acceptsInput { onCopyRequest?(); shortcut("x") } }
    @objc func paste(_ sender: Any?) { if let text = NSPasteboard.general.string(forType: .string) { sendText(text) } }
    override func selectAll(_ sender: Any?) { shortcut("a") }
    @objc func undo(_ sender: Any?) { shortcut("z") }

    private func sendText(_ text: String) {
        guard acceptsInput, !text.isEmpty else { return }
        let units = text.utf16
        var start = units.startIndex
        while start < units.endIndex {
            var end = units.index(start, offsetBy: 10_000, limitedBy: units.endIndex) ?? units.endIndex
            let last = units.index(before: end)
            if end < units.endIndex && (0xD800...0xDBFF).contains(units[last]) { end = last }
            onInput?(["type": .string("text"), "text": .string(String(decoding: units[start..<end], as: UTF16.self))])
            start = end
        }
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let value = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        let composing = hasMarkedText()
        unmarkText()
        if !composing, let event = interpreting, value.count == 1, value == event.characters {
            sendKeyDown(event, text: value)
        } else { sendText(value) }
    }

    override func doCommand(by selector: Selector) {
        if let event = interpreting, Self.specialKeys[event.keyCode] != nil { sendKeyDown(event, text: nil) }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedSelection = selectedRange
        composition.stringValue = marked
        composition.isHidden = marked.isEmpty
        positionComposition()
    }

    func unmarkText() { marked = ""; composition.isHidden = true }
    func hasMarkedText() -> Bool { !marked.isEmpty }
    func markedRange() -> NSRange { marked.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: marked.utf16.count) }
    func selectedRange() -> NSRange { marked.isEmpty ? NSRange(location: 0, length: 0) : markedSelection }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        actualRange?.pointee = range
        return window.convertToScreen(convert(CGRect(x: pointer.x, y: pointer.y, width: 1, height: 20), to: nil))
    }

    private func positionComposition() {
        guard !composition.isHidden else { return }
        composition.sizeToFit()
        composition.frame.origin = CGPoint(x: max(0, min(pointer.x, bounds.width - composition.frame.width)),
                                           y: max(0, min(pointer.y, bounds.height - composition.frame.height)))
    }

    private static let specialKeys: [UInt16: Key] = [
        36: Key(name: "Enter", code: "Enter", virtual: 13), 76: Key(name: "Enter", code: "NumpadEnter", virtual: 13),
        48: Key(name: "Tab", code: "Tab", virtual: 9), 51: Key(name: "Backspace", code: "Backspace", virtual: 8),
        53: Key(name: "Escape", code: "Escape", virtual: 27), 117: Key(name: "Delete", code: "Delete", virtual: 46),
        115: Key(name: "Home", code: "Home", virtual: 36), 119: Key(name: "End", code: "End", virtual: 35),
        116: Key(name: "PageUp", code: "PageUp", virtual: 33), 121: Key(name: "PageDown", code: "PageDown", virtual: 34),
        123: Key(name: "ArrowLeft", code: "ArrowLeft", virtual: 37), 124: Key(name: "ArrowRight", code: "ArrowRight", virtual: 39),
        125: Key(name: "ArrowDown", code: "ArrowDown", virtual: 40), 126: Key(name: "ArrowUp", code: "ArrowUp", virtual: 38),
    ]
}
