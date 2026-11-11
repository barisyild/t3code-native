import Foundation
import UniformTypeIdentifiers

struct BrowserMultipart {
    let boundary = "T3-\(UUID().uuidString)"
    let file: URL

    init(files: [URL]) throws {
        guard files.count <= 20 else { throw ClientError.message("Choose up to 20 files at a time.") }
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("t3-browser-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        file = directory.appendingPathComponent("upload")
        do {
            try Data().write(to: file)
            let output = try FileHandle(forWritingTo: file)
            defer { try? output.close() }
            let limit = 100 * 1024 * 1024
            var size = 0
            func write(_ bytes: Data) throws {
                guard bytes.count <= limit - size else { throw ClientError.message("Browser uploads can total up to 100 MiB.") }
                try output.write(contentsOf: bytes)
                size += bytes.count
            }
            for source in files {
                try Task.checkCancellation()
                let properties = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey])
                guard properties.isRegularFile == true, let length = properties.fileSize, length <= limit - size else {
                    throw ClientError.message("Choose regular files totaling no more than 100 MiB.")
                }
                let name = source.lastPathComponent.map { "\r\n\"\\".contains($0) ? "_" : $0 }
                let contentType = properties.contentType?.preferredMIMEType ?? "application/octet-stream"
                let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(String(name))\"\r\nContent-Type: \(contentType)\r\n\r\n"
                try write(Data(header.utf8))
                let input = try FileHandle(forReadingFrom: source)
                defer { try? input.close() }
                while let block = try input.read(upToCount: 256 * 1024), !block.isEmpty {
                    try Task.checkCancellation()
                    try write(block)
                }
                try write(Data("\r\n".utf8))
            }
            try write(Data("--\(boundary)--\r\n".utf8))
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }

    func remove() { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
}
