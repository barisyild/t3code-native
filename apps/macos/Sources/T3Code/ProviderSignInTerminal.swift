import AppKit
import SwiftTerm

@MainActor
final class ProviderSignInTerminal: NSView, @preconcurrency TerminalViewDelegate {
    private let terminal = SwiftTerm.TerminalView(frame: .zero)
    private var previousOutput = ""
    private var written = 0
    var onReply: ((ProviderAuthReply) -> Void)?

    init() {
        super.init(frame: .zero)
        let surface = Surface(WorkspaceStyle.canvas, border: WorkspaceStyle.outline, radius: 7)
        terminal.terminalDelegate = self
        terminal.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        terminal.setAccessibilityLabel("Provider Sign-In Terminal")
        fill(terminal, in: surface, inset: 5)
        fill(surface, in: self)
        heightAnchor.constraint(equalToConstant: 174).isActive = true
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            terminal.nativeBackgroundColor = WorkspaceStyle.canvas
            terminal.nativeForegroundColor = WorkspaceStyle.ink
        }
    }

    func reset() {
        written = 0
        previousOutput = ""
        terminal.getTerminal().resetToInitialState()
        terminal.needsDisplay = true
    }

    func render(output: String, offset: Int) {
        let delta = offset - written
        if delta > 0, delta <= output.utf16.count {
            terminal.feed(text: String(decoding: output.utf16.suffix(delta), as: UTF16.self))
        } else if delta != 0 || output != previousOutput {
            terminal.getTerminal().resetToInitialState()
            terminal.feed(text: output)
        }
        written = offset
        previousOutput = output
    }

    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        onReply?(.terminal("", cols: max(1, min(500, newCols)), rows: max(1, min(200, newRows))))
    }

    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        var remainder = String(decoding: data, as: UTF8.self).unicodeScalars[...]
        while !remainder.isEmpty {
            let prefix = remainder.prefix(2_048)
            onReply?(.terminal(String(prefix), cols: nil, rows: nil))
            remainder = remainder[prefix.endIndex...]
        }
    }

    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    func bell(source: SwiftTerm.TerminalView) {}
    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {}

    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
        if let url = ProviderBrowserAddress.url(link) { NSWorkspace.shared.open(url) }
    }
}
