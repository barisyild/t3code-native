import AppKit
import AVKit
import UniformTypeIdentifiers

@MainActor
final class BrowserMediaPreview: NSWindowController, NSWindowDelegate {
    enum Content {
        case recording
        case screenshot(CGImage)

        var title: String {
            switch self {
            case .recording: "Browser Recording"
            case .screenshot: "Browser Screenshot"
            }
        }

        var fileType: UTType {
            switch self {
            case .recording: .mpeg4Movie
            case .screenshot: .png
            }
        }

        var attachmentLimit: Int {
            switch self {
            case .recording: 50 * 1024 * 1024
            case .screenshot: PickedAttachment.maximumImageBytes
            }
        }
    }

    private let file: URL
    private let content: Content
    private var player: AVPlayerView?
    private let status = label(size: 11, color: WorkspaceStyle.secondary)
    private let onAttach: (() throws -> Void)?
    private lazy var attach = ActionButton("Attach to Draft", symbol: "paperclip", style: .subtle) { [weak self] in
        self?.attachToDraft()
    }
    private lazy var more = ActionButton("File Actions", symbol: "ellipsis", iconOnly: true, style: .subtle) {
        [weak self] in self?.showActions()
    }
    private lazy var save = ActionButton("Save As…", symbol: "square.and.arrow.down", style: .subtle) { [weak self] in self?.saveAs() }
    var onClose: (() -> Void)?

    init(file: URL, subject: String?, content: Content, onAttach: (() throws -> Void)?) {
        self.file = file
        self.content = content
        self.onAttach = onAttach
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 510),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = content.title
        window.contentMinSize = NSSize(width: 390, height: 295)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let surface = Surface(WorkspaceStyle.navigation)
        window.contentView = surface
        let media: NSView
        switch content {
        case .recording:
            let player = AVPlayerView()
            player.controlsStyle = .inline
            player.player = AVPlayer(url: file)
            player.setAccessibilityLabel("Browser Recording Playback")
            self.player = player
            media = player
        case .screenshot(let image):
            let view = NSImageView(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
            view.imageScaling = .scaleProportionallyUpOrDown
            view.setAccessibilityLabel("Browser Screenshot")
            media = view
        }
        media.heightAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true
        let title = label(subject ?? content.title, size: 14, weight: .semibold, color: WorkspaceStyle.ink)
        let fileName = label(file.lastPathComponent, size: 11, color: WorkspaceStyle.muted)
        fileName.toolTip = file.lastPathComponent
        status.isHidden = true
        attach.isHidden = onAttach == nil
        if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > content.attachmentLimit {
            attach.isEnabled = false
            attach.toolTip = "This file exceeds the \(content.attachmentLimit / (1024 * 1024)) MiB attachment limit."
        }
        let footer = row([attach, NSView(), more, save], spacing: 8)
        fill(column([column([title, fileName], spacing: 3, alignment: .width), media, status, footer],
                    spacing: 11, alignment: .width), in: surface, inset: 15)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        player?.player?.pause()
        player?.player = nil
        onClose?()
    }

    private func attachToDraft() {
        guard let onAttach else { return }
        do {
            try onAttach()
            attach.isEnabled = false
            showStatus("Added to the draft.")
        } catch {
            showStatus(error.localizedDescription, error: true)
        }
    }

    private func showActions() {
        let menu = NSMenu()
        if case .screenshot = content {
            menu.addItem(menuItem("Copy Image", target: self, action: #selector(copyImage)))
        }
        menu.addItem(menuItem("Show in Finder", target: self, action: #selector(reveal)))
        menu.addItem(menuItem("Copy File Path", target: self, action: #selector(copyPath)))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height), in: more)
    }

    @objc private func reveal() { NSWorkspace.shared.activateFileViewerSelecting([file]) }

    @objc private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(file.path, forType: .string)
        showStatus("File path copied.")
    }

    @objc private func copyImage() {
        guard case .screenshot = content else { return }
        let source = file
        Task { [weak self] in
            do {
                let data = try await Task.detached { try Data(contentsOf: source) }.value
                guard let self else { return }
                NSPasteboard.general.clearContents()
                if NSPasteboard.general.setData(data, forType: .png) {
                    showStatus("Image copied.")
                } else {
                    showStatus("The image could not be copied.", error: true)
                }
            } catch { self?.showStatus(error.localizedDescription, error: true) }
        }
    }

    private func saveAs() {
        guard let window, window.attachedSheet == nil else { return }
        let panel = NSSavePanel()
        panel.title = "Save \(content.title)"
        panel.nameFieldStringValue = file.lastPathComponent
        panel.allowedContentTypes = [content.fileType]
        let source = file
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            self?.save.isEnabled = false
            Task { [weak self] in
                do {
                    try await Task.detached { try AttachmentFile.export(source, to: destination) }.value
                    self?.showStatus("Saved \(destination.lastPathComponent).")
                } catch {
                    self?.showStatus(error.localizedDescription, error: true)
                }
                self?.save.isEnabled = true
            }
        }
    }

    private func showStatus(_ message: String, error: Bool = false) {
        status.stringValue = message
        status.textColor = error ? WorkspaceStyle.negative : WorkspaceStyle.secondary
        status.isHidden = message.isEmpty
        status.toolTip = message
    }
}
