import AppKit

@MainActor
enum WorkspaceStyle {
    static let canvas = color(0x000000, 0xFFFFFF)
    static let navigation = color(0x111113, 0xF5F5F6)
    static let composer = color(0x19191B, 0xF6F6F7)
    static let commandPreview = color(0x111113, 0xEDEDF0)
    static let bubble = color(0x232326, 0xEDEDF0)
    static let selection = color(0x26262A, 0xE4E4E8)
    static let accent = color(0xD18568, 0xA3482F)
    static let quota = color(0xF5B52D, 0x936200)
    static let modelFocus = color(0x5196FF, 0x245FBC)
    static let modelPanel = color(0x2C2B2B, 0xF6F6F8)
    static let effortFill = color(0x397FEB, 0x245FBC)

    static let line = color(0x202022, 0xE0E0E3)
    static let outline = color(0x2C2C2F, 0xDCDCE1)
    static let ink = color(0xEFEFF3, 0x19191D)
    static let secondary = color(0xB8B8C1, 0x484850)
    static let muted = color(0x92929B, 0x65656E)
    static let positive = color(0x67CB87, 0x206739)
    static let negative = color(0xF0847E, 0xB02F29)

    static let composerWidth: CGFloat = 676
    static let railWidth: CGFloat = 52

    static func symbol(_ name: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }

    static func icon(_ name: String, size: CGFloat = 13, tint: NSColor = secondary) -> NSImageView {
        let view = NSImageView(image: symbol(name, size: size) ?? NSImage())
        view.contentTintColor = tint
        view.setAccessibilityElement(false)
        return view
    }

    static func providerIcon(_ family: ComposerProvider, size: CGFloat = 15) -> NSImage {
        let asset = family == .claude ? "ClaudeProvider" : "CodexProvider"
        let image = Bundle.main.url(forResource: asset, withExtension: "png").flatMap(NSImage.init(contentsOf:))
        image?.size = NSSize(width: size, height: size)
        return image ?? symbol(family == .claude ? "sparkle" : "terminal", size: size) ?? NSImage()
    }

    nonisolated static func date(_ timestamp: String?) -> Date? {
        guard let timestamp else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(timestamp))
            ?? (try? Date.ISO8601FormatStyle().parse(timestamp))
    }

    static func age(_ date: Date) -> String {
        let minutes = max(0, Int(-date.timeIntervalSinceNow / 60))
        if minutes < 1 { return "Now" }
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 1_440 { return "\(minutes / 60)h" }
        return "\(minutes / 1_440)d"
    }

    static func elapsed(since date: Date) -> String {
        let seconds = max(0, Int(-date.timeIntervalSinceNow))
        let clock = String(format: "%02d:%02d", (seconds / 60) % 60, seconds % 60)
        let hours = seconds / 3_600
        return hours > 0 ? "\(hours):\(clock)" : clock
    }

    private static func color(_ dark: UInt32, _ light: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }
}
