import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class AttachmentStore {
    typealias Loader = @MainActor (ChatAttachment, AttachmentScope) async throws -> AttachmentFile
    private let loader: Loader
    private let files = NSCache<NSString, AttachmentFile>()
    private let images = NSCache<NSString, NSImage>()
    private var pending: [String: Task<AttachmentFile, Error>] = [:]
    private var revision = UUID()
    private(set) var scope: AttachmentScope?

    init(loader: @escaping Loader) {
        self.loader = loader
        files.totalCostLimit = 128 * 1024 * 1024
        files.countLimit = 32
        images.totalCostLimit = 32 * 1024 * 1024
        images.countLimit = 80
    }

    func setScope(_ scope: AttachmentScope?) {
        guard self.scope != scope else { return }
        reset()
        self.scope = scope
    }

    func reset() {
        revision = UUID()
        for task in pending.values { task.cancel() }
        pending.removeAll()
        files.removeAllObjects()
        images.removeAllObjects()
    }

    func file(_ attachment: ChatAttachment, scope: AttachmentScope) async throws -> AttachmentFile {
        try await file(key: attachment.id, scope: scope) { [loader] in try await loader(attachment, scope) }
    }

    func webPage(_ reference: ConversationPage, scope: AttachmentScope,
                 load: @escaping @MainActor () async throws -> AttachmentFile) async throws -> AttachmentFile {
        try await file(key: reference.cacheKey, scope: scope, load: load)
    }

    private func file(key: String, scope: AttachmentScope,
                      load: @escaping @MainActor () async throws -> AttachmentFile) async throws -> AttachmentFile {
        try Task.checkCancellation()
        guard self.scope == scope else { throw ClientError.disconnected }
        if let file = files.object(forKey: key as NSString) { return file }
        let revision = revision
        let task: Task<AttachmentFile, Error>
        if let existing = pending[key] { task = existing }
        else {
            task = Task { try await load() }
            pending[key] = task
        }
        defer { if self.revision == revision { pending.removeValue(forKey: key) } }
        let file = try await task.value
        try Task.checkCancellation()
        guard self.revision == revision, self.scope == scope else { throw ClientError.disconnected }
        files.setObject(file, forKey: key as NSString, cost: file.bytes)
        return file
    }

    func thumbnail(_ attachment: ChatAttachment, scope: AttachmentScope) async throws -> NSImage {
        guard self.scope == scope else { throw ClientError.disconnected }
        if let image = images.object(forKey: attachment.id as NSString) { return image }
        let revision = revision
        let file = try await file(attachment, scope: scope)
        let data = try await Task.detached(priority: .utility) { try Self.thumbnailData(file.url) }.value
        try Task.checkCancellation()
        guard self.revision == revision, self.scope == scope else { throw ClientError.disconnected }
        guard let image = NSImage(data: data) else { throw ClientError.message("This image could not be previewed.") }
        images.setObject(image, forKey: attachment.id as NSString, cost: Int(image.size.width * image.size.height * 4))
        return image
    }

    nonisolated private static func thumbnailData(_ url: URL) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double,
              width > 0, height > 0, width * height <= 64_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 320,
              ] as CFDictionary) else { throw ClientError.message("This image is too large or could not be decoded. Try saving it instead.") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ClientError.message("This image could not be previewed.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ClientError.message("This image could not be previewed.") }
        return data as Data
    }
}
