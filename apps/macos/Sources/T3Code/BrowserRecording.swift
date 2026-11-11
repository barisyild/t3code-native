import Foundation
import CoreGraphics

struct BrowserRecordingPreferences: Equatable, Sendable {
    enum FrameRate: Int, CaseIterable, Sendable {
        case fps30 = 30
        case fps60 = 60
    }

    var frameRate: FrameRate
    var showShortcuts: Bool
    var showMousePresses: Bool

    init(_ value: Wire = .null) {
        frameRate = value["recordingFrameRate"].int.flatMap(FrameRate.init(rawValue:)) ?? .fps30
        showShortcuts = value["recordingShowShortcuts"].bool == true
        showMousePresses = value["recordingShowMousePresses"].bool == true
    }
}

struct BrowserRecordingClip: Sendable {
    let file: URL
    let target: BrowserTabTarget?

    static func latest(in directory: URL) -> Self? {
        BrowserMediaFiles.latest(in: directory, prefix: "Browser Recording", extension: "mp4").map {
            Self(file: $0, target: nil)
        }
    }
}

enum BrowserRecordingInput {
    private static let namedKeys = [
        "Enter": "↵", "Tab": "⇥", "Escape": "Esc", "Backspace": "⌫", "Delete": "⌦",
        "ArrowUp": "↑", "ArrowDown": "↓", "ArrowLeft": "←", "ArrowRight": "→",
        "Home": "Home", "End": "End", "PageUp": "Page Up", "PageDown": "Page Down",
    ]

    static func shortcut(_ input: Payload) -> String? {
        guard input["type"] == .string("key"), input["action"] == .string("down"),
              let key = input["key"]?.string else { return nil }
        let modifiers = input["modifiers"]?.int ?? 0
        let label: String
        if let named = namedKeys[key] {
            label = named
        } else {
            // Printable input belongs in the page, even when the recording shows shortcuts.
            guard modifiers & 6 != 0, key.utf8.count == 1,
                  let byte = key.uppercased().utf8.first, (65...90).contains(byte) || (48...57).contains(byte) else { return nil }
            label = key.uppercased()
        }
        let keys = [(2, "⌃"), (1, "⌥"), (8, "⇧"), (4, "⌘")]
        return keys.filter { modifiers & $0.0 != 0 }.map(\.1).joined() + label
    }

    static func pressPoint(_ input: Payload, viewport: CGSize) -> CGPoint? {
        guard input["type"] == .string("mouse"), let action = input["action"]?.string,
              action == "down" || (action == "move" && (input["buttons"]?.int ?? 0) > 0),
              let x = input["x"]?.double, let y = input["y"]?.double else { return nil }
        return normalizedPoint(x: x, y: y, viewport: viewport)
    }

    static func normalizedPoint(x: Double, y: Double, viewport: CGSize) -> CGPoint? {
        guard x.isFinite, y.isFinite, viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 0, viewport.height > 0 else { return nil }
        return CGPoint(x: min(1, max(0, x / viewport.width)), y: min(1, max(0, y / viewport.height)))
    }
}
