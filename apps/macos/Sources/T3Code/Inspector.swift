import AppKit
import Quartz
import UniformTypeIdentifiers

@MainActor
final class InspectorController: NSViewController, NSTableViewDelegate, NSTableViewDataSource, NSTextViewDelegate {
    enum Tab { case files, changes, browser, device }

    private struct FileEntry {
        let path: String
        let isDirectory: Bool
    }

    private let workspace: Workspace
    private let fileList = NSTableView()
    private let document = NSTextView()
    private let fileUndo = UndoManager()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let titleField = label("Files", size: 14, weight: .semibold)
    private let location = label(size: 11, color: .secondaryLabelColor)
    private let changeSource = NSSegmentedControl(labels: ["Working tree", "Thread"], trackingMode: .selectOne, target: nil, action: nil)
    private lazy var back = ActionButton("Back", symbol: "chevron.left", iconOnly: true) { [weak self] in self?.goBack() }
    private lazy var filesScroll = scroller(for: fileList)
    private lazy var documentScroll = textScroller(document)
    private lazy var browser = BrowserPane(workspace: workspace)
    private var device: DevicePane?
    private var panelContainer: NSView?
    private var filePanel: NSView?
    private lazy var refresh = ActionButton("Refresh", symbol: "arrow.clockwise", iconOnly: true, style: .subtle) { [weak self] in self?.load() }
    private lazy var source = ActionButton("Show Source", symbol: "chevron.left.forwardslash.chevron.right", iconOnly: true, style: .subtle) {
        [weak self] in self?.toggleSource()
    }
    private lazy var copy = ActionButton("Copy Contents", symbol: "document.on.document", iconOnly: true, style: .subtle) { [weak self] in
        self?.copyContents()
    }
    private lazy var export = ActionButton("Save a Copy…", symbol: "square.and.arrow.down", iconOnly: true, style: .subtle) { [weak self] in
        self?.saveCopy()
    }
    private lazy var save = ActionButton("Save Changes", symbol: "checkmark", iconOnly: true, style: .subtle) { [weak self] in
        self?.saveCurrentFile()
    }
    private lazy var useServer = ActionButton("Use Server Version", style: .subtle) { [weak self] in
        guard let self, let activeEditor else { return }
        activeEditor.useServerVersion()
        showEditor(activeEditor)
    }
    private lazy var keepEdits = ActionButton("Keep My Edits", style: .subtle) { [weak self] in self?.activeEditor?.keepEdits() }
    private lazy var conflictActions = row([useServer, keepEdits, NSView()], spacing: 4)
    private var preview: QLPreviewView?
    private var previewFile: AttachmentFile?
    private var fileContents: WorkspaceFileContents?
    private var fileError: String?
    private var showSource = false
    private var editors: [WorkspaceFileTarget: WorkspaceFileEditor] = [:]
    private var activeEditor: WorkspaceFileEditor?
    private var preparingToQuit = false
    private var exportTask: Task<Void, Never>?
    private var entries: [FileEntry] = []
    private var task: Task<Void, Never>?
    private var directory = ""
    private var file: WorkspaceFilePath?
    private var pendingPosition: WorkspaceFilePosition?
    private var context: WorkspaceFileContext?
    private var tab = Tab.files
    private var presented = false
    var onBrowserReveal: (() -> Void)? { didSet { browser.onReveal = onBrowserReveal } }
    var onBrowserSettings: (() -> Void)? { didSet { browser.onManageProfiles = onBrowserSettings } }
    var onBrowserRecordingChange: ((Bool) -> Void)? { didSet { browser.onRecordingChange = onBrowserRecordingChange } }
    var onAttachBrowserRecording: ((BrowserRecordingClip) throws -> Void)? { didSet { browser.onAttachRecording = onAttachBrowserRecording } }
    var onAttachBrowserImage: ((PickedAttachment, BrowserTabTarget?) throws -> Void)? { didSet { browser.onAttachImage = onAttachBrowserImage } }
    var onDeviceSettings: (() -> Void)? { didSet { device?.onManageHosts = onDeviceSettings } }
    var onError: ((String) -> Void)? { didSet { device?.onError = onError; browser.onCaptureError = onError } }

    var selectedTab: Tab { tab }
    var canSaveCurrentFile: Bool { presented && tab == .files && !preparingToQuit && activeEditor?.canSave == true }
    var hasUnsavedFiles: Bool { editors.values.contains { $0.isDirty || $0.isSaving } }

    private var fileTarget: WorkspaceFileTarget? {
        guard tab == .files, let context, let file else { return nil }
        return .init(environmentID: context.environmentID, root: context.root, path: file)
    }

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = Surface(WorkspaceStyle.navigation)
        let tableColumn = NSTableColumn(identifier: .init("file"))
        tableColumn.resizingMask = .autoresizingMask
        fileList.addTableColumn(tableColumn)
        fileList.headerView = nil
        fileList.style = .inset
        fileList.backgroundColor = .clear
        fileList.rowHeight = 24
        fileList.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        fileList.delegate = self
        fileList.dataSource = self
        fileList.target = self
        fileList.doubleAction = #selector(openFile)
        fileList.setAccessibilityLabel("Project Files")
        document.textContainerInset = NSSize(width: 5, height: 7)
        document.setAccessibilityLabel("File or Diff Contents")
        document.delegate = self
        document.allowsUndo = true
        document.isAutomaticQuoteSubstitutionEnabled = false
        document.isAutomaticDashSubstitutionEnabled = false
        document.isAutomaticTextReplacementEnabled = false
        document.isAutomaticSpellingCorrectionEnabled = false
        document.isAutomaticLinkDetectionEnabled = false
        status.font = .systemFont(ofSize: 11.5)
        status.textColor = WorkspaceStyle.muted
        status.maximumNumberOfLines = 3
        changeSource.selectedSegment = 0
        changeSource.target = self
        changeSource.action = #selector(changeDiffSource)
        changeSource.setAccessibilityLabel("Diff Source")
        let top = row([titleField, NSView(), refresh])
        let navigation = row([back, location, NSView(), source, copy, export, save], spacing: 4)
        let content = NSView()
        fill(filesScroll, in: content)
        fill(documentScroll, in: content)
        if let preview = QLPreviewView(frame: .zero, style: .normal) {
            preview.autostarts = false
            preview.shouldCloseWithWindow = false
            preview.isHidden = true
            fill(preview, in: content)
            self.preview = preview
        }
        content.setContentHuggingPriority(.defaultLow, for: .vertical)
        let filePanel = column([navigation, changeSource, status, conflictActions, content], spacing: 8, alignment: .width)
        self.filePanel = filePanel
        let container = NSView()
        panelContainer = container
        fill(filePanel, in: container)
        addChild(browser)
        fill(browser.view, in: container)
        browser.view.isHidden = true
        let stack = column([top, container], spacing: 8, alignment: .width)
        fill(stack, in: view, inset: 10)
        renderFileControls()
    }

    func canShow(_ tab: Tab) -> Bool {
        if tab == .device { return workspace.deviceScope != nil }
        if tab == .browser {
            guard case .thread = workspace.selection else { return false }
            return workspace.can("orchestration:read")
        }
        return workspace.can("filesystem:read") && workspace.workspacePath != nil
    }

    func show(_ tab: Tab, opening reference: WorkspaceFileReference? = nil) {
        let _ = view
        if self.tab != tab { releaseFile() }
        self.tab = tab
        presented = true
        sync(force: true, opening: reference)
    }

    func hide() {
        presented = false
        task?.cancel()
        releaseFile()
        browser.setPresented(false)
        device?.setPresented(false)
    }

    func shutdown() {
        task?.cancel()
        preview?.close()
        previewFile = nil
        browser.shutdown()
        device?.setPresented(false)
    }

    func saveCurrentFile() {
        if canSaveCurrentFile { activeEditor?.flush() }
    }

    func flushBeforeQuit() async -> Bool {
        preparingToQuit = true
        renderFileControls()
        for editor in Array(editors.values) { await editor.flushAndWait() }
        return !hasUnsavedFiles
    }

    func resumeAfterCancelledQuit() {
        preparingToQuit = false
        renderFileControls()
    }

    func focusBrowserAddress() { browser.focusAddress() }
    func newBrowserTab() { browser.newTab() }
    func showBrowserProfiles() { browser.showNewTabProfiles() }
    var canShowBrowserDisplayOptions: Bool { browser.canShowDisplayOptions }
    func showBrowserDisplayOptions() { browser.showDisplayOptions() }
    func canZoomBrowser(_ direction: BrowserZoom.Direction) -> Bool { browser.canZoom(direction) }
    func zoomBrowser(_ direction: BrowserZoom.Direction) { browser.zoom(direction) }
    var canStartBrowserRecording: Bool { browser.canStartRecording }
    var canStopBrowserRecording: Bool { browser.canStopRecording }
    var canStopAllBrowserRecordings: Bool { browser.canStopAllRecordings }
    var hasPendingBrowserCapture: Bool { browser.hasPendingCapture }
    var hasLatestBrowserRecording: Bool { browser.hasLatestRecording }
    var canCaptureBrowserScreenshot: Bool { browser.canCaptureScreenshot }
    var canAnnotateBrowserRegion: Bool { browser.canAnnotateRegion }
    var hasLatestBrowserScreenshot: Bool { browser.hasLatestScreenshot }
    func startBrowserRecording() { browser.startRecording() }
    func stopBrowserRecording() { browser.stopRecording() }
    func stopAllBrowserRecordings() { browser.stopAllRecordings() }
    func previewLatestBrowserRecording() { browser.previewLatestRecording() }
    func captureBrowserScreenshot() { browser.captureScreenshot() }
    func annotateBrowserRegion() { browser.annotateRegion() }
    func previewLatestBrowserScreenshot() { browser.previewLatestScreenshot() }
    func finishBrowserCaptureBeforeQuit() async { await browser.finishCaptureBeforeQuit() }
    func syncBrowserPreferences() { browser.syncBrowserPreferences() }
    func openActionPreview(_ address: String) { browser.openActionPreview(address) }

    func sync(force: Bool = false, opening reference: WorkspaceFileReference? = nil) {
        browser.sync()
        for editor in Array(editors.values) { updateAccess(editor) }
        guard presented else { return }
        let next = workspace.workspaceFileContext
        let changed = context != next
        if changed {
            releaseFile()
            context = next
            directory = ""
            file = nil
            pendingPosition = nil
            showSource = false
            changeSource.selectedSegment = 0
        }
        let showsBrowser = tab == .browser
        let showsDevice = tab == .device
        filePanel?.isHidden = showsBrowser || showsDevice
        browser.view.isHidden = !showsBrowser
        refresh.isHidden = showsBrowser || showsDevice
        browser.setPresented(showsBrowser)
        if showsDevice, device == nil, let panelContainer {
            let pane = DevicePane(workspace: workspace)
            pane.onError = onError
            pane.onManageHosts = onDeviceSettings
            addChild(pane)
            fill(pane.view, in: panelContainer)
            device = pane
        }
        device?.view.isHidden = !showsDevice
        device?.setPresented(showsDevice)
        if showsBrowser || showsDevice {
            task?.cancel()
            titleField.stringValue = showsDevice ? "Device" : "Browser"
            return
        }
        if tab == .files, let reference { navigate(to: reference) }
        else if changed || force { load() }
    }

    private func load() {
        task?.cancel()
        guard tab == .files || tab == .changes else { return }
        let showsFiles = tab == .files
        let retained = fileTarget.flatMap { editors[$0] }
        retained?.invalidateRead()
        clearFileDisplay()
        titleField.stringValue = showsFiles ? "Files" : "Changes"
        changeSource.isHidden = showsFiles || workspace.selectedThread == nil
        back.isHidden = !showsFiles || (directory.isEmpty && file == nil)
        let subpath = file?.value ?? directory
        location.stringValue = showsFiles ? (subpath.isEmpty ? workspace.selectedProject?.name ?? "Workspace" : subpath) :
            workspace.selectedThread?.branch ?? workspace.selectedProject?.name ?? "Workspace"
        location.toolTip = subpath.isEmpty ? context?.root : subpath
        guard let context else { showText("Select a project to view its workspace."); return }
        guard let connection = workspace.connectionID else {
            if let retained, retained.isDirty { showEditor(retained) }
            else { showText("Waiting for the environment to reconnect…") }
            return
        }
        showText("Loading…")
        task = Task {
            do {
                try Task.checkCancellation()
                if showsFiles { try await loadFiles(context, connection: connection) }
                else { try await loadChanges(context.root) }
            } catch {
                guard !Task.isCancelled else { return }
                if let retained, retained.isDirty, workspace.can("filesystem:read") {
                    fileError = error.localizedDescription
                    showEditor(retained)
                } else {
                    showText(error.localizedDescription)
                }
            }
        }
    }

    private func loadFiles(_ context: WorkspaceFileContext, connection: UUID) async throws {
        guard workspace.can("filesystem:read") else { throw ClientError.message("This connection cannot read workspace files.") }
        if let target = fileTarget {
            if let existing = editors[target] { await existing.waitForWrites() }
            try Task.checkCancellation()
            if !showSource, prefersPreview(target), let preview {
                let downloaded = try await workspace.downloadWorkspaceFile(target, connection: connection)
                try Task.checkCancellation()
                previewFile = downloaded
                preview.previewItem = downloaded.url as NSURL
                preview.isHidden = false
                documentScroll.isHidden = true
                renderFileControls()
                return
            }
            let contents: WorkspaceFileContents
            do {
                contents = try await workspace.readWorkspaceFile(target, connection: connection)
            } catch ClientError.rpc(let failure) where failure["_tag"].string == "ProjectReadFileError" &&
                failure["failure"].string == "path_not_file" {
                guard let path = target.path.workspaceRelative, editors[target]?.isDirty != true else { throw ClientError.rpc(failure) }
                try await loadDirectory(path, root: context.root, connection: connection)
                return
            }
            let editor = editors[target] ?? WorkspaceFileEditor(target: target, contents: contents, connection: connection) { [workspace] text, connection in
                try await workspace.writeWorkspaceFile(target, contents: text, connection: connection)
            }
            editors[target] = editor
            editor.refresh(contents, connection: connection)
            showEditor(editor)
            updateAccess(editor)
            return
        }
        try await loadDirectory(directory, root: context.root, connection: connection)
    }

    private func loadDirectory(_ path: String, root: String, connection: UUID) async throws {
        let result = try await workspace.request("projects.listEntries", ["cwd": .string(root), "directoryPath": .string(path)])
        try Task.checkCancellation()
        guard workspace.connectionID == connection else { throw ClientError.disconnected }
        file = nil
        pendingPosition = nil
        directory = path
        showSource = false
        back.isHidden = path.isEmpty
        location.stringValue = path.isEmpty ? workspace.selectedProject?.name ?? "Workspace" : path
        location.toolTip = path.isEmpty ? root : path
        entries = result["entries"].array.compactMap { entry in
            guard let path = entry["path"].string else { return nil }
            return FileEntry(path: path, isDirectory: entry["kind"].string == "directory")
        }.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
        if result["truncated"].bool == true { location.stringValue += " (partial list)" }
        if entries.isEmpty { showText("This folder is empty.") }
        else {
            documentScroll.isHidden = true
            filesScroll.isHidden = false
            fileList.reloadData()
            fileList.scrollRowToVisible(0)
        }
    }

    private func loadChanges(_ path: String) async throws {
        let diff: String
        if changeSource.selectedSegment == 1, let threadId = context?.threadID {
            let count = workspace.detail.checkpointCount
            guard count > 0 else { showText("This thread has no captured changes yet."); return }
            let result = try await workspace.request("orchestration.getFullThreadDiff", [
                "threadId": .string(threadId), "toTurnCount": .int(count),
            ])
            diff = try result.requireString("diff")
        } else {
            guard workspace.can("filesystem:read") else { throw ClientError.message("This connection cannot read workspace changes.") }
            let result = try await workspace.request("review.getDiffPreview", ["cwd": .string(path), "sourceKind": .string("working-tree")])
            diff = result["sources"].array.compactMap { source in
                guard let patch = source["diff"].string else { return nil }
                return source["truncated"].bool == true ? patch + "\n[Diff truncated]" : patch
            }.joined(separator: "\n")
        }
        try Task.checkCancellation()
        showText(diff.isEmpty ? "No changes to show." : diff, diff: !diff.isEmpty)
    }

    private func updateAccess(_ editor: WorkspaceFileEditor) {
        let writable = editor.target.path.workspaceRelative != nil && workspace.environment?.id == editor.target.environmentID &&
            workspace.can("filesystem:read") && workspace.can("filesystem:write")
        editor.setAccess(connection: workspace.connectionID, writable: writable)
    }

    private func showEditor(_ editor: WorkspaceFileEditor) {
        activeEditor = nil
        fileContents = editor.saved
        showText(editor.text)
        fileUndo.removeAllActions()
        document.typingAttributes = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: WorkspaceStyle.ink,
        ]
        activeEditor = editor
        editor.onChange = { [weak self, weak editor] in
            guard let self, let editor else { return }
            if activeEditor === editor { renderFileControls() }
            else if !editor.isDirty && !editor.isSaving { editors.removeValue(forKey: editor.target) }
        }
        renderFileControls()
        if let position = pendingPosition {
            pendingPosition = nil
            reveal(position)
        }
    }

    private func releaseFile() {
        let editor = activeEditor
        clearFileDisplay()
        guard let editor else { return }
        editor.flush()
        if !editor.isDirty && !editor.isSaving { editors.removeValue(forKey: editor.target) }
    }

    private func clearFileDisplay() {
        activeEditor = nil
        fileContents = nil
        fileError = nil
        preview?.previewItem = nil
        preview?.isHidden = true
        previewFile = nil
        document.isEditable = false
    }

    private func prefersPreview(_ target: WorkspaceFileTarget) -> Bool {
        let suffix = (target.name as NSString).pathExtension.lowercased()
        if let type = UTType(filenameExtension: suffix),
           type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .audio) {
            return true
        }
        return ["html", "htm", "pdf", "rtf", "docx", "pptx", "xlsx", "odt", "ods", "odp", "epub",
                "zip", "jar", "tar", "gz", "tgz", "ttf", "otf", "woff", "woff2"].contains(suffix)
    }

    private func hasSource(_ target: WorkspaceFileTarget) -> Bool {
        ["html", "htm", "svg", "rtf"].contains((target.name as NSString).pathExtension.lowercased())
    }

    private func toggleSource() {
        guard let target = fileTarget, hasSource(target), activeEditor?.isDirty != true else { return }
        releaseFile()
        showSource.toggle()
        load()
    }

    private func copyContents() {
        guard fileTarget != nil, let text = activeEditor?.text ?? fileContents?.text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func saveCopy() {
        guard exportTask == nil, let target = fileTarget, let window = view.window else { return }
        let localFile = previewFile
        let text = activeEditor.flatMap { $0.saved.lossless ? $0.encodedText : nil }
        guard localFile != nil || text != nil else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = AttachmentFile.safeName(target.name)
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .OK, let destination = panel.url else { return }
            exportTask = Task {
                do {
                    if let text {
                        try await Task.detached(priority: .userInitiated) {
                            try Data(text.utf8).write(to: destination, options: .atomic)
                        }.value
                    } else if let localFile {
                        try await Task.detached(priority: .userInitiated) { try localFile.export(to: destination) }.value
                    }
                } catch { onError?(error.localizedDescription) }
                exportTask = nil
                renderFileControls()
            }
            renderFileControls()
        }
    }

    private func renderFileControls() {
        let target = fileTarget
        source.isHidden = target.map { !hasSource($0) } ?? true
        let sourceTitle = showSource ? "Show Preview" : "Show Source"
        source.toolTip = sourceTitle
        source.setAccessibilityLabel(sourceTitle)
        source.isEnabled = workspace.can("filesystem:read") && activeEditor?.isDirty != true
        copy.isHidden = target == nil || fileContents == nil
        export.isHidden = previewFile == nil && activeEditor?.saved.lossless != true
        export.isEnabled = exportTask == nil
        save.isHidden = activeEditor?.isDirty != true || activeEditor?.conflict != nil
        save.isEnabled = canSaveCurrentFile
        refresh.isEnabled = activeEditor?.isSaving != true
        document.isEditable = activeEditor?.canEdit == true && !preparingToQuit
        let conflict = activeEditor?.conflict != nil
        conflictActions.isHidden = !conflict
        keepEdits.isEnabled = document.isEditable
        let message: String
        if exportTask != nil { message = "Saving copy…" }
        else if conflict { message = "The file changed on the server. Choose which version to keep." }
        else if let error = fileError ?? activeEditor?.error { message = error }
        else if activeEditor?.isSaving == true { message = "Saving…" }
        else if activeEditor?.isDirty == true { message = document.isEditable ? "Unsaved changes" : "Unsaved changes waiting for write access" }
        else if fileContents?.truncated == true { message = "Preview limited to the first 1 MB." }
        else if fileContents != nil && !document.isEditable { message = "Read-only file preview" }
        else { message = "" }
        if status.stringValue != message { status.stringValue = message }
        status.isHidden = message.isEmpty
    }

    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === document, document.isEditable else { return }
        activeEditor?.change(document.string)
    }

    func undoManager(for view: NSTextView) -> UndoManager? { fileUndo }

    private func showText(_ text: String, diff: Bool = false) {
        documentScroll.isHidden = false
        filesScroll.isHidden = true
        document.textStorage?.setAttributedString(TranscriptText.monospace(text, diff: diff))
        document.scrollRangeToVisible(NSRange(location: 0, length: 0))
        renderFileControls()
    }

    private func reveal(_ position: WorkspaceFilePosition) {
        guard let range = position.selection(in: document.string) else { return }
        document.setSelectedRange(range)
        document.scrollRangeToVisible(range)
    }

    private func navigate(to reference: WorkspaceFileReference) {
        switch reference {
        case .directory(let path):
            releaseFile()
            file = nil
            directory = path
            pendingPosition = nil
            showSource = false
        case .file(let path, let position):
            if file == path, activeEditor?.isDirty == true {
                if let position { reveal(position) }
                return
            }
            let keepSource = file == path && showSource
            releaseFile()
            file = path
            directory = path.workspaceRelative.map(parentDirectory) ?? ""
            pendingPosition = position
            showSource = keepSource || (position != nil && fileTarget.map(hasSource) == true)
        }
        load()
    }

    private func parentDirectory(_ path: String) -> String {
        path.split(separator: "/").dropLast().joined(separator: "/")
    }

    private func goBack() {
        releaseFile()
        showSource = false
        pendingPosition = nil
        if file != nil { file = nil }
        else { directory = parentDirectory(directory) }
        load()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        let entry = entries[index]
        let name = label(entry.path.split(separator: "/").last.map(String.init) ?? entry.path, size: 12)
        let icon = NSImageView(image: NSImage(systemSymbolName: entry.isDirectory ? "folder" : "doc", accessibilityDescription: nil) ?? NSImage())
        icon.widthAnchor.constraint(equalToConstant: 15).isActive = true
        icon.contentTintColor = .secondaryLabelColor
        return row([icon, name, NSView()], spacing: 6)
    }

    @objc private func openFile() {
        let index = fileList.clickedRow >= 0 ? fileList.clickedRow : fileList.selectedRow
        guard entries.indices.contains(index) else { return }
        let entry = entries[index]
        navigate(to: entry.isDirectory ? .directory(entry.path) : .file(.workspace(entry.path), nil))
    }

    @objc private func changeDiffSource() {
        if tab == .changes { load() }
    }
}
