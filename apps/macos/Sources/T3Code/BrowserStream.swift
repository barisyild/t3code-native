import Foundation
import ImageIO

struct BrowserControl: Equatable, Sendable {
    enum Owner: String, Sendable { case you, agent, unclaimed, otherViewer = "another-viewer" }

    struct Dialog: Equatable, Sendable {
        let type: String
        let message: String
        let defaultValue: String
    }

    let canOperate: Bool
    let owner: Owner
    let generation: Int
    let dialog: Dialog?

    init?(_ message: Wire) {
        guard let canOperate = message["canOperate"].bool, let owner = message["controller"].string.flatMap(Owner.init),
              let generation = message["generation"].int else { return nil }
        self.canOperate = canOperate
        self.owner = owner
        self.generation = generation
        let dialog = message["dialog"]
        if let type = dialog["type"].string, let text = dialog["message"].string {
            self.dialog = Dialog(type: type, message: text, defaultValue: dialog["defaultValue"].string ?? "")
        } else { self.dialog = nil }
    }
}

struct BrowserFileChooser: Equatable, Sendable {
    let id: String
    let multiple: Bool
    let accept: String
}

struct BrowserDownload: Equatable, Sendable {
    let id: String
    let name: String
}

enum BrowserStreamError: LocalizedError {
    case gone
    case setup(String)
    case disconnected

    var errorDescription: String? {
        switch self {
        case .gone: "This browser tab closed on the host."
        case .setup(let command): "The browser host needs setup. Run \(command) on the host, then try again."
        case .disconnected: "The browser on the host could not connect. If this is the first tab, check whether Chromium is downloading on the host."
        }
    }
}

actor BrowserStream {
    enum Event: Sendable {
        case image(CGImage)
        case viewport(CGSize)
        case control(BrowserControl)
        case pointer(phase: String, x: Double, y: Double)
        case clipboard(String)
        case popup(String)
        case fileChooser(BrowserFileChooser)
        case fileChooserClosed(String)
        case download(BrowserDownload)
    }

    private let socket: URLSessionWebSocketTask
    private var control: BrowserControl?

    init(socket: URLSessionWebSocketTask) {
        self.socket = socket
        socket.maximumMessageSize = 8 * 1024 * 1024
    }

    func watch(_ receive: @Sendable (Event) async -> Void) async throws {
        socket.resume()
        defer { stop() }
        try await withTaskCancellationHandler {
            do {
                while !Task.isCancelled {
                    switch try await socket.receive() {
                    case .data(let bytes):
                        if let image = Self.decodeImage(bytes) { await receive(.image(image)) }
                        // The host sends one frame at a time and can discard superseded frames while decoding.
                        try await socket.send(.string("{\"type\":\"ack\"}"))
                    case .string(let text):
                        if let event = decodeEvent(text) { await receive(event) }
                    @unknown default: break
                    }
                }
            } catch {
                try Task.checkCancellation()
                switch socket.closeCode.rawValue {
                case 4404: throw BrowserStreamError.gone
                case 4503:
                    let details = socket.closeReason.flatMap { try? JSONDecoder().decode(Wire.self, from: $0) }
                    throw BrowserStreamError.setup(details?["command"].string ?? "t3 browser setup")
                default: throw BrowserStreamError.disconnected
                }
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    func send(_ payload: Payload, generation: Int) async throws {
        guard let control, control.canOperate, control.generation == generation,
              payload["type"] == .string("takeControl") || control.owner == .you else { return }
        let data = try JSONEncoder().encode(payload)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    func stop() {
        control = nil
        socket.cancel(with: .goingAway, reason: nil)
    }

    private func decodeEvent(_ text: String) -> Event? {
        guard let message = try? JSONDecoder().decode(Wire.self, from: Data(text.utf8)) else { return nil }
        switch message["type"].string {
        case "viewport":
            guard let width = message["width"].int, let height = message["height"].int, width > 0, height > 0 else { return nil }
            return .viewport(CGSize(width: width, height: height))
        case "control":
            guard let next = BrowserControl(message) else { return nil }
            control = next
            return .control(next)
        case "clipboard": return message["text"].string.map(Event.clipboard)
        case "pointer":
            guard let phase = message["phase"].string, let x = message["x"].double, let y = message["y"].double,
                  x.isFinite, y.isFinite else { return nil }
            return .pointer(phase: phase, x: x, y: y)
        case "popup": return message["tabId"].string.map(Event.popup)
        case "fileChooser":
            guard let id = message["id"].string else { return nil }
            return .fileChooser(BrowserFileChooser(id: id, multiple: message["multiple"].bool == true,
                                                    accept: message["accept"].string ?? ""))
        case "fileChooserClosed": return message["id"].string.map(Event.fileChooserClosed)
        case "download":
            guard let id = message["id"].string, let name = message["fileName"].string else { return nil }
            return .download(BrowserDownload(id: id, name: name))
        default: return nil
        }
    }

    private static func decodeImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let dimensions = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = dimensions[kCGImagePropertyPixelWidth] as? Int,
              let height = dimensions[kCGImagePropertyPixelHeight] as? Int,
              (1...7_680).contains(width), (1...4_320).contains(height) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}
