import AppKit
import ImageIO
import UniformTypeIdentifiers

enum AttachmentInput: Sendable {
    case file(URL)
    case image(Data)

    private static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, .init(UTType.jpeg.identifier), .init(UTType.gif.identifier), .init(UTType.webP.identifier),
        .init(UTType.heic.identifier), .init(UTType.heif.identifier), .tiff,
    ]
    static let pasteboardTypes: [NSPasteboard.PasteboardType] = [.fileURL] + imageTypes

    @MainActor
    static func read(_ pasteboard: NSPasteboard) -> [Self] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            if let value = item.string(forType: .fileURL), let url = URL(string: value), url.isFileURL {
                return .file(url)
            }
            if let type = item.availableType(from: imageTypes), let data = item.data(forType: type) {
                return .image(data)
            }
            return nil
        }
    }

    @concurrent
    static func prepare(_ inputs: [Self]) async throws -> [PickedAttachment] {
        guard inputs.count <= 100 else { throw ClientError.message("Attach up to 100 files per message.") }
        let files = try inputs.map { input in
            try Task.checkCancellation()
            switch input {
            case .file(let url): return try PickedAttachment(url: url)
            case .image(let data): return try prepareImage(data)
            }
        }
        try PickedAttachment.validate(files)
        return files
    }

    private static func prepareImage(_ data: Data) throws -> PickedAttachment {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let identifier = CGImageSourceGetType(source), let type = UTType(identifier as String),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double,
              width > 0, height > 0, width * height <= 64_000_000 else {
            throw ClientError.message("This pasted image is too large or could not be decoded.")
        }
        if let mime = type.preferredMIMEType, let suffix = type.preferredFilenameExtension,
           PickedAttachment.imageTypes.contains(mime), data.count <= PickedAttachment.maximumImageBytes {
            return try PickedAttachment(ownedFile: AttachmentFile(data: data, name: "Pasted Image.\(suffix)"))
        }
        if CGImageSourceGetCount(source) > 1, PickedAttachment.imageTypes.contains(type.preferredMIMEType ?? "") {
            throw ClientError.message("This animated image exceeds the 10 MiB attachment limit.")
        }
        for limit in [4096, 2048, 1024] {
            try Task.checkCancellation()
            let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                           kCGImageSourceCreateThumbnailWithTransform: true,
                           kCGImageSourceThumbnailMaxPixelSize: limit] as CFDictionary
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { break }
            let png = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else { break }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { break }
            if png.length <= PickedAttachment.maximumImageBytes {
                return try PickedAttachment(ownedFile: AttachmentFile(data: png as Data, name: "Pasted Image.png"))
            }
        }
        throw ClientError.message("Couldn’t prepare this pasted image as an attachment.")
    }
}

@MainActor
class AttachmentTextView: NSTextView {
    var onReadAttachment: ((NSPasteboard) -> Bool)? {
        didSet { updateDragTypeRegistration() }
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        withAttachmentTypes(super.readablePasteboardTypes)
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        withAttachmentTypes(super.acceptableDragTypes)
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if isEditable, pasteboard.availableType(from: AttachmentInput.pasteboardTypes) != nil,
           onReadAttachment?(pasteboard) == true { return }
        super.paste(sender)
    }

    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if isEditable, AttachmentInput.pasteboardTypes.contains(type), onReadAttachment?(pasteboard) == true { return true }
        return super.readSelection(from: pasteboard, type: type)
    }

    override func dragOperation(for draggingInfo: any NSDraggingInfo, type: NSPasteboard.PasteboardType) -> NSDragOperation {
        let operation = super.dragOperation(for: draggingInfo, type: type)
        guard isEditable, onReadAttachment != nil, AttachmentInput.pasteboardTypes.contains(type) else { return operation }
        return draggingInfo.draggingSourceOperationMask.contains(.copy) ? .copy : []
    }

    private func withAttachmentTypes(_ types: [NSPasteboard.PasteboardType]) -> [NSPasteboard.PasteboardType] {
        guard isEditable, onReadAttachment != nil else { return types }
        return AttachmentInput.pasteboardTypes + types.filter { !AttachmentInput.pasteboardTypes.contains($0) }
    }
}
