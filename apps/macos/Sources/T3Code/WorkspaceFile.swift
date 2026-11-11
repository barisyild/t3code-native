import Foundation

struct WorkspaceFileTarget: Hashable, Sendable {
    let environmentID: String
    let root: String
    let path: WorkspaceFilePath

    init(environmentID: String, root: String, path: WorkspaceFilePath) {
        self.environmentID = environmentID
        self.root = root
        self.path = path
    }

    init(environmentID: String, root: String, relativePath: String) {
        self.init(environmentID: environmentID, root: root, path: .workspace(relativePath))
    }

    var request: Payload { ["cwd": .string(root), "relativePath": .string(path.requestPath)] }
    var name: String { path.value.split(separator: "/").last.map(String.init) ?? path.value }

    var previewResource: Wire {
        .object(["_tag": .string("draft-workspace-file"), "cwd": .string(root), "path": .string(path.requestPath)])
    }
}

struct WorkspaceFileContents: Sendable {
    let text: String
    let byteLength: Int
    let truncated: Bool
    let hasBOM: Bool
    let lossless: Bool

    init(_ result: Wire) throws {
        text = try result.requireString("contents")
        guard let bytes = result["byteLength"].int, bytes >= 0 else { throw ClientError.invalidResponse }
        byteLength = bytes
        truncated = result["truncated"].bool == true
        let difference = bytes - text.utf8.count
        hasBOM = !truncated && difference == 3
        lossless = !truncated && (difference == 0 || hasBOM) && !text.unicodeScalars.contains("\u{fffd}")
    }

    private init(text: String, hasBOM: Bool) {
        self.text = text
        self.hasBOM = hasBOM
        byteLength = text.utf8.count + (hasBOM ? 3 : 0)
        truncated = false
        lossless = true
    }

    func replacingText(_ text: String) -> Self { .init(text: text, hasBOM: hasBOM) }
    var encodedText: String { hasBOM ? "\u{feff}" + text : text }

    func matches(_ other: Self) -> Bool {
        lossless && other.lossless && hasBOM == other.hasBOM && text.utf8.elementsEqual(other.text.utf8)
    }
}

@MainActor
final class WorkspaceFileEditor {
    typealias Persist = @MainActor (String, UUID) async throws -> Void

    let target: WorkspaceFileTarget
    private let persist: Persist
    private(set) var saved: WorkspaceFileContents
    private(set) var text: String
    private(set) var conflict: WorkspaceFileContents?
    private(set) var error: String?
    private var connection: UUID?
    private var writable = false
    private var revision = 0
    private var savedRevision = 0
    private var debounce: Task<Void, Never>?
    private var write: Task<Void, Never>?
    private var flushAfterWrite = false
    var onChange: (() -> Void)?

    init(target: WorkspaceFileTarget, contents: WorkspaceFileContents, connection: UUID, persist: @escaping Persist) {
        self.target = target
        saved = contents
        text = contents.text
        self.connection = connection
        self.persist = persist
    }

    var isDirty: Bool { revision != savedRevision }
    var isSaving: Bool { write != nil }
    var canEdit: Bool { writable && saved.lossless }
    var canSave: Bool { canEdit && isDirty && conflict == nil }
    var encodedText: String { saved.replacingText(text).encodedText }

    func setAccess(connection: UUID?, writable: Bool) {
        let next = writable && connection != nil && connection == self.connection
        guard self.writable != next else { return }
        self.writable = next
        if next { schedule() }
        else { cancelDebounce() }
        onChange?()
    }

    func invalidateRead() {
        connection = nil
        setAccess(connection: nil, writable: false)
    }

    func refresh(_ contents: WorkspaceFileContents, connection: UUID) {
        guard !isSaving else { return }
        if self.connection != connection {
            self.connection = connection
            writable = false
            cancelDebounce()
        }
        if !isDirty || contents.matches(saved.replacingText(text)) {
            accept(contents)
        } else if contents.matches(saved) {
            conflict = nil
        } else {
            cancelDebounce()
            conflict = contents
        }
        onChange?()
    }

    func change(_ text: String) {
        guard canEdit else { return }
        self.text = text
        revision += 1
        error = nil
        schedule()
        onChange?()
    }

    func flush() {
        cancelDebounce()
        guard canSave, let connection else { return }
        guard write == nil else { flushAfterWrite = true; return }
        let revision = revision
        let contents = saved.replacingText(text)
        error = nil
        write = Task {
            do {
                try await persist(contents.encodedText, connection)
                saved = contents
                savedRevision = revision
            } catch {
                self.error = error.localizedDescription
            }
            write = nil
            let queued = flushAfterWrite
            flushAfterWrite = false
            onChange?()
            if queued, error == nil || self.revision != revision { flush() }
        }
        onChange?()
    }

    func flushAndWait() async {
        flush()
        await waitForWrites()
    }

    func waitForWrites() async {
        while let write { await write.value }
    }

    func useServerVersion() {
        guard let conflict, !isSaving else { return }
        accept(conflict)
        onChange?()
    }

    func keepEdits() {
        guard conflict != nil, canEdit, !isSaving else { return }
        conflict = nil
        flush()
    }

    private func accept(_ contents: WorkspaceFileContents) {
        cancelDebounce()
        saved = contents
        text = contents.text
        savedRevision = revision
        conflict = nil
        error = nil
    }

    private func schedule() {
        cancelDebounce()
        guard canSave else { return }
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) }
            catch { return }
            self?.flush()
        }
    }

    private func cancelDebounce() {
        debounce?.cancel()
        debounce = nil
    }
}
