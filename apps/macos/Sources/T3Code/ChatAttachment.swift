import Foundation

struct ChatAttachment: Equatable, Sendable {
    let id: String
    let type: String
    let name: String
    let mimeType: String
    let bytes: Int

    var isSupported: Bool { type == "image" || type == "file" }
    var isImage: Bool { isSupported && mimeType.lowercased().hasPrefix("image/") }
    var maximumBytes: Int { (type == "image" ? 10 : 50) * 1024 * 1024 }
    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
    var fileName: String { AttachmentFile.safeName(name) }

    var resource: Wire {
        .object(["_tag": .string("attachment"), "attachmentId": .string(id), "fileName": .string(name),
                 "mimeType": .string(mimeType), "disposition": .string("inline")])
    }

    init?(_ value: Wire) {
        guard let id = value["id"].string, !id.isEmpty, id.utf16.count <= 256,
              let type = value["type"].string, !type.isEmpty, type.utf16.count <= 50,
              let name = value["name"].string, !name.isEmpty, name.utf16.count <= 255,
              let mime = value["mimeType"].string, !mime.isEmpty, mime.utf16.count <= 100,
              let bytes = value["sizeBytes"].int, bytes >= 0 else { return nil }
        if type == "image", !mime.lowercased().hasPrefix("image/") || bytes > 10 * 1024 * 1024 { return nil }
        if type == "file", bytes == 0 || bytes > 50 * 1024 * 1024 { return nil }
        self.id = id
        self.type = type
        self.name = name
        mimeType = mime
        self.bytes = bytes
    }
}

struct AttachmentScope: Equatable, Sendable {
    let environmentID: String
    let connection: UUID
}

final class AttachmentFile: Sendable {
    let url: URL
    let bytes: Int
    private let directory: URL

    static func safeName(_ name: String) -> String {
        let base = (name.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
        let clean = String(base.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        guard !clean.isEmpty, ![".", ".."].contains(clean) else { return "attachment" }
        let fileExtension = (clean as NSString).pathExtension
        let suffix = fileExtension.isEmpty || fileExtension.utf8.count > 32 ? "" : "." + fileExtension
        let stem = suffix.isEmpty ? clean : (clean as NSString).deletingPathExtension
        var bytes = 0
        let prefix = stem.prefix { character in
            let size = character.utf8.count
            guard bytes + size <= 220 - suffix.utf8.count else { return false }
            bytes += size
            return true
        }
        return (prefix.isEmpty ? "attachment" : String(prefix)) + suffix
    }

    convenience init(temporaryFile: URL, name: String) throws {
        let bytes = try temporaryFile.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try self.init(name: name, bytes: bytes) { destination in
            try FileManager.default.moveItem(at: temporaryFile, to: destination)
        }
    }

    convenience init(data: Data, name: String) throws {
        try self.init(name: name, bytes: data.count) { destination in
            try data.write(to: destination)
        }
    }

    private init(name: String, bytes: Int, write: (URL) throws -> Void) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("t3-attachment-" + UUID().uuidString)
        url = directory.appendingPathComponent(name)
        self.bytes = bytes
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do { try write(url) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    func export(to destination: URL) throws {
        try Self.export(url, to: destination)
    }

    static func export(_ source: URL, to destination: URL) throws {
        let manager = FileManager.default
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".t3-save-" + UUID().uuidString)
        try manager.copyItem(at: source, to: staging)
        defer { try? manager.removeItem(at: staging) }
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try manager.moveItem(at: staging, to: destination)
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

extension Workspace {
    var attachmentScope: AttachmentScope? {
        guard can("orchestration:read"), let environment, let connection = connectionID else { return nil }
        return .init(environmentID: environment.id, connection: connection)
    }

    func attachmentFile(_ attachment: ChatAttachment, scope: AttachmentScope) async throws -> AttachmentFile {
        guard attachment.isSupported else { throw ClientError.message("This attachment type needs a newer client.") }
        return try await downloadAttachment(attachment.resource, fileName: attachment.fileName, maximumBytes: attachment.maximumBytes, scope: scope)
    }

    func downloadAttachment(_ resource: Wire, fileName: String, maximumBytes: Int, scope: AttachmentScope) async throws -> AttachmentFile {
        guard attachmentScope == scope else { throw ClientError.disconnected }
        let api = try browserAPI(for: scope.environmentID)
        let grant = try await request("assets.createUrl", ["resource": resource])
        guard attachmentScope == scope else { throw ClientError.disconnected }
        let temporary = try await api.downloadAsset(grant.requireString("relativeUrl"), maximumBytes: maximumBytes)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard attachmentScope == scope else { throw ClientError.disconnected }
        return try AttachmentFile(temporaryFile: temporary, name: fileName)
    }
}
