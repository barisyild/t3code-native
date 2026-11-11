import AppKit

@MainActor
enum HtmlReplyTheme {
    static func message(appearance: NSAppearance) -> [String: Any] {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        var variables: [String: String] = [:]
        appearance.performAsCurrentDrawingAppearance {
            let background = hex(WorkspaceStyle.canvas), foreground = hex(WorkspaceStyle.ink)
            let surface = hex(WorkspaceStyle.composer), secondary = hex(WorkspaceStyle.bubble), overlay = hex(WorkspaceStyle.navigation)
            let border = hex(WorkspaceStyle.outline), accent = hex(WorkspaceStyle.accent), muted = hex(WorkspaceStyle.muted)
            let negative = hex(WorkspaceStyle.negative), positive = hex(WorkspaceStyle.positive)
            let focus = hex(WorkspaceStyle.modelFocus), warning = hex(WorkspaceStyle.quota)
            variables = [
                "--background": background, "--foreground": foreground,
                "--muted": surface, "--muted-foreground": muted, "--card": surface, "--card-foreground": foreground,
                "--popover": overlay, "--popover-foreground": foreground, "--secondary": secondary, "--secondary-foreground": foreground,
                "--border": border, "--input": border, "--ring": focus,
                "--primary": foreground, "--primary-foreground": background, "--accent": accent, "--accent-foreground": background,
                "--accent-surface": secondary, "--accent-surface-foreground": accent,
                "--destructive": negative, "--destructive-foreground": background, "--destructive-surface": secondary,
                "--warning": warning, "--warning-foreground": background, "--warning-surface": secondary,
                "--success": positive, "--success-foreground": positive, "--info": focus, "--info-foreground": focus,
                "--code-background": overlay, "--code-foreground": foreground,
                "--chart-1": accent, "--chart-2": dark ? "#2dd4bf" : "#0d9488", "--chart-3": warning,
                "--chart-4": dark ? "#c084fc" : "#9333ea", "--chart-5": negative, "--chart-6": positive,
                "--radius": "0.625rem", "--font-sans": "-apple-system, BlinkMacSystemFont, system-ui, sans-serif",
                "--font-mono": "\"SF Mono\", \"SFMono-Regular\", Menlo, monospace",
            ]
        }
        return ["jsonrpc": "2.0", "method": "ui/notifications/host-context-changed",
                "params": ["theme": dark ? "dark" : "light", "styles": ["variables": variables]]]
    }

    private static func hex(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "#000000" }
        let bytes = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Int((255 * min(1, max(0, $0))).rounded()) }
        return String(format: "#%02x%02x%02x", bytes[0], bytes[1], bytes[2])
    }
}
