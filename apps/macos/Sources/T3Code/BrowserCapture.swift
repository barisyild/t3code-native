import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct BrowserTabTarget: Equatable, Sendable {
    struct Key: Hashable, Sendable {
        let environmentID: String
        let threadID: String
        let tabID: String
    }

    let environmentID: String
    let connection: UUID
    let threadID: String
    let tabID: String
    let title: String

    var key: Key { .init(environmentID: environmentID, threadID: threadID, tabID: tabID) }
}

struct BrowserSnapshot: Sendable {
    let image: CGImage
    let target: BrowserTabTarget
    let address: String?
}

enum BrowserMediaFiles {
    static func destination(in directory: URL, prefix: String, extension suffix: String, id: UUID) -> URL {
        let timestamp = ISO8601DateFormatter().string(from: Date()).prefix(19).replacingOccurrences(of: ":", with: "-")
        return directory.appendingPathComponent("\(prefix) \(timestamp) \(id.uuidString.lowercased().prefix(8)).\(suffix)")
    }

    static func latest(in directory: URL, prefix: String, extension suffix: String) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let recent = files.compactMap { file -> (URL, Date)? in
            guard file.lastPathComponent.hasPrefix(prefix + " "), file.pathExtension == suffix,
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true, let date = values.contentModificationDate else { return nil }
            return (file, date)
        }.max { $0.1 < $1.1 }
        return recent?.0
    }
}

struct BrowserScreenshot: Sendable {
    let file: URL
    let target: BrowserTabTarget?

    static func latest(in directory: URL) -> Self? {
        BrowserMediaFiles.latest(in: directory, prefix: "Browser Screenshot", extension: "png").map {
            Self(file: $0, target: nil)
        }
    }

    @concurrent
    static func save(_ snapshot: BrowserSnapshot, in directory: URL) async throws -> Self {
        let data = try BrowserImageCapture.png(snapshot.image)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = BrowserMediaFiles.destination(in: directory, prefix: "Browser Screenshot", extension: "png", id: UUID())
        try data.write(to: file, options: .atomic)
        return Self(file: file, target: snapshot.target)
    }

    @concurrent
    func loadImage() async throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, (1...7_680).contains(width),
              let height = properties[kCGImagePropertyPixelHeight] as? Int, (1...4_320).contains(height),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ClientError.message("The browser screenshot could not be opened.")
        }
        return image
    }
}

enum BrowserImageCapture {
    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ClientError.message("The PNG encoder could not start.")
        }
        CGImageDestinationAddImage(encoder, image, nil)
        guard CGImageDestinationFinalize(encoder) else { throw ClientError.message("The browser screenshot could not be encoded.") }
        return data as Data
    }

    static func pixelRect(_ selection: CGRect, width: Int, height: Int) -> CGRect? {
        guard width > 0, height > 0, selection.minX.isFinite, selection.minY.isFinite,
              selection.maxX.isFinite, selection.maxY.isFinite, !selection.isEmpty else { return nil }
        let clipped = selection.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clipped.isEmpty, !clipped.isNull else { return nil }
        let imageBounds = CGRect(x: 0, y: 0, width: width, height: height)
        let pixels = CGRect(x: clipped.minX * imageBounds.width, y: clipped.minY * imageBounds.height,
                            width: clipped.width * imageBounds.width, height: clipped.height * imageBounds.height)
        return pixels.integral.intersection(imageBounds)
    }

    @concurrent
    static func region(_ snapshot: BrowserSnapshot, selection: CGRect, comment: String) async throws -> PickedAttachment {
        guard let pixels = pixelRect(selection, width: snapshot.image.width, height: snapshot.image.height),
              let cropped = snapshot.image.cropping(to: pixels) else { throw ClientError.message("Select a region to attach.") }
        let annotation = BrowserRegionAnnotation(address: snapshot.address, pageTitle: snapshot.target.title, comment: comment)
        var data = try png(cropped)
        if data.count > PickedAttachment.maximumImageBytes {
            let prepared = try await AttachmentInput.prepare([.image(data)])
            guard let resized = prepared.first else { throw ClientError.invalidResponse }
            data = try Data(contentsOf: resized.url)
        }
        try Task.checkCancellation()
        let file = try AttachmentFile(data: data, name: annotation.fileName)
        return try PickedAttachment(ownedFile: file, browserAnnotation: annotation)
    }
}
