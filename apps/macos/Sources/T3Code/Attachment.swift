import Foundation
import UniformTypeIdentifiers

struct PickedAttachment: Equatable, Sendable {
    static let imageTypes: Set<String> = ["image/gif", "image/jpeg", "image/png", "image/webp"]
    static let maximumImageBytes = 10 * 1024 * 1024
    let id = UUID()
    let url: URL
    let name: String
    let mimeType: String
    let bytes: Int
    let isImage: Bool
    let browserAnnotation: BrowserRegionAnnotation?
    private let owner: AttachmentFile?

    init(url: URL) throws {
        try self.init(url: url, owner: nil, browserAnnotation: nil)
    }

    init(ownedFile: AttachmentFile, browserAnnotation: BrowserRegionAnnotation? = nil) throws {
        try self.init(url: ownedFile.url, owner: ownedFile, browserAnnotation: browserAnnotation)
    }

    private init(url: URL, owner: AttachmentFile?, browserAnnotation: BrowserRegionAnnotation?) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey])
        let mime = values.contentType?.preferredMIMEType ?? "application/octet-stream"
        let image = Self.imageTypes.contains(mime)
        let limit = image ? Self.maximumImageBytes : 50 * 1024 * 1024
        guard values.isRegularFile == true, let bytes = values.fileSize, bytes > 0 else {
            throw ClientError.message("Choose a non-empty file to attach.")
        }
        guard bytes <= limit else {
            throw ClientError.message("\(url.lastPathComponent) exceeds the \(limit / (1024 * 1024)) MiB attachment limit.")
        }
        self.url = url
        name = String(url.lastPathComponent.prefix(127))
        mimeType = mime
        self.bytes = bytes
        isImage = image
        self.owner = owner
        self.browserAnnotation = browserAnnotation
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    var metadata: Payload {
        ["type": .string(isImage ? "image" : "file"), "name": .string(name),
         "mimeType": .string(mimeType), "sizeBytes": .int(bytes)]
    }

    static func validate(_ files: [Self], retaining attachments: [Wire] = []) throws {
        guard files.count + attachments.count <= 100 else { throw ClientError.message("Attach up to 100 files per message.") }
        let imageBytes = files.filter(\.isImage).reduce(0) { $0 + $1.bytes }
        let retainedBytes = attachments.filter { $0["type"].string == "image" }.reduce(0) { $0 + ($1["sizeBytes"].int ?? 0) }
        guard imageBytes + retainedBytes <= 80 * 1024 * 1024 else {
            throw ClientError.message("Attach up to 80 MiB of images per message.")
        }
    }
}
