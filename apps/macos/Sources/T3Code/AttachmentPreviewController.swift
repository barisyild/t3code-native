import AppKit
import Quartz
import UniformTypeIdentifiers

@MainActor
final class AttachmentPreviewController: NSWindowController, NSWindowDelegate {
    private let attachments: [ChatAttachment]
    private let scope: AttachmentScope
    private let store: AttachmentStore
    private let preview: QLPreviewView
    private let name = label(size: 14, weight: .semibold, color: WorkspaceStyle.ink)
    private let metadata = label(size: 11.5, color: WorkspaceStyle.muted)
    private let count = label(size: 11.5, color: WorkspaceStyle.muted)
    private let status = NSTextField(wrappingLabelWithString: "")
    private var index: Int
    private var file: AttachmentFile?
    private var task: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private lazy var previous = ActionButton("Previous Attachment", symbol: "chevron.left", iconOnly: true, style: .subtle) { [weak self] in
        self?.move(-1)
    }
    private lazy var next = ActionButton("Next Attachment", symbol: "chevron.right", iconOnly: true, style: .subtle) { [weak self] in
        self?.move(1)
    }
    private lazy var retry = ActionButton("Retry", symbol: "arrow.clockwise", style: .subtle) { [weak self] in self?.load() }
    private lazy var save = ActionButton("Save As…", symbol: "square.and.arrow.down", style: .subtle) { [weak self] in self?.saveAs() }
    var onClose: (() -> Void)?

    init(attachments: [ChatAttachment], selectedID: String, scope: AttachmentScope, store: AttachmentStore) throws {
        let supported = attachments.filter(\.isSupported)
        guard let index = supported.firstIndex(where: { $0.id == selectedID }),
              let preview = QLPreviewView(frame: .zero, style: .normal) else { throw ClientError.invalidResponse }
        self.attachments = supported
        self.index = index
        self.scope = scope
        self.store = store
        self.preview = preview
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 540),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.contentMinSize = NSSize(width: 460, height: 340)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let surface = Surface(WorkspaceStyle.navigation)
        window.contentView = surface
        name.lineBreakMode = .byTruncatingMiddle
        status.font = .systemFont(ofSize: 12)
        status.maximumNumberOfLines = 4
        status.textColor = WorkspaceStyle.muted
        preview.autostarts = false
        preview.shouldCloseWithWindow = false
        let viewport = NSView()
        viewport.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        fill(preview, in: viewport)
        let heading = column([name, metadata], spacing: 4, alignment: .width)
        let tools = row([previous, next, count, NSView(), retry, save], spacing: 8)
        tools.heightAnchor.constraint(equalToConstant: 28).isActive = true
        fill(column([heading, viewport, status, tools], spacing: 12, alignment: .width), in: surface, inset: 16)
        window.center()
        load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        task?.cancel()
        task = nil
        preview.close()
        file = nil
        onClose?()
    }

    private func move(_ delta: Int) {
        guard exportTask == nil, attachments.indices.contains(index + delta) else { return }
        index += delta
        load()
    }

    private func load() {
        task?.cancel()
        task = nil
        preview.previewItem = nil
        preview.isHidden = true
        file = nil
        let attachment = attachments[index]
        name.stringValue = attachment.name
        name.toolTip = attachment.name
        window?.title = attachment.name
        let kind = UTType(mimeType: attachment.mimeType)?.localizedDescription ?? attachment.mimeType
        metadata.stringValue = "\(kind) · \(attachment.sizeLabel)"
        count.stringValue = "\(index + 1) of \(attachments.count)"
        status.stringValue = "Loading attachment…"
        status.textColor = WorkspaceStyle.muted
        let store = store
        let requestScope: AttachmentScope
        if let active = store.scope, active.environmentID == scope.environmentID { requestScope = active }
        else { requestScope = scope }
        task = Task { [weak self] in
            do {
                let file = try await store.file(attachment, scope: requestScope)
                try Task.checkCancellation()
                guard let self else { return }
                self.file = file
                preview.previewItem = file.url as NSURL
                preview.isHidden = false
                status.stringValue = ""
            } catch {
                guard !Task.isCancelled, let self else { return }
                status.stringValue = error.localizedDescription
                status.textColor = WorkspaceStyle.negative
            }
            self?.task = nil
            self?.renderControls()
        }
        renderControls()
    }

    private func renderControls() {
        previous.isEnabled = index > 0 && exportTask == nil
        next.isEnabled = index + 1 < attachments.count && exportTask == nil
        retry.isHidden = task != nil || file != nil
        save.isEnabled = file != nil && exportTask == nil
        status.isHidden = status.stringValue.isEmpty
    }

    private func saveAs() {
        guard exportTask == nil, let file, let window else { return }
        let attachment = attachments[index]
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.fileName
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let destination = panel.url, let self else { return }
            status.stringValue = "Saving attachment…"
            status.textColor = WorkspaceStyle.muted
            exportTask = Task { [weak self] in
                do {
                    try await Task.detached(priority: .userInitiated) { try file.export(to: destination) }.value
                    self?.status.stringValue = ""
                } catch {
                    self?.status.stringValue = error.localizedDescription
                    self?.status.textColor = WorkspaceStyle.negative
                }
                self?.exportTask = nil
                self?.renderControls()
            }
            renderControls()
        }
    }
}
