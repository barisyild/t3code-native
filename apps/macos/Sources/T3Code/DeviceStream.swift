import CoreGraphics
import Foundation

enum DeviceTouchPhase: String, Sendable { case begin, move, end }
enum DeviceButton: Sendable { case home, back, recents, power }

enum DeviceInput: Sendable {
    case touch(DeviceTouchPhase, CGPoint)
    case hid(Int, down: Bool)
    case key(Int)
    case text(String)
    case button(DeviceButton)
    case rotate

    var isTouchMove: Bool {
        if case .touch(.move, _) = self { return true }
        return false
    }
}

actor DeviceStream {
    enum Event: Sendable {
        case image(CGImage)
        case video(DeviceVideoSample)
        case screen(DeviceScreenConfig)
        case input(Bool)
        case webRTC(Wire)
        case resetVideo
    }

    private let access: DeviceMediaAccess
    private let canOperate: Bool
    private var socket: URLSessionWebSocketTask?
    private var inputReady = false
    private var screen: DeviceScreenConfig?
    private var orientation: DeviceScreenConfig.Orientation?

    init(access: DeviceMediaAccess, canOperate: Bool) {
        self.access = access
        self.canOperate = canOperate
    }

    func watch(_ receive: @escaping @Sendable (Event) async -> Void) async throws {
        let info = try? await access.json(.info)
        try Task.checkCancellation()
        let settings = info?["streamSettings"] ?? .null
        let transport = settings == .null ? info?["stream"] ?? .null : settings
        if transport["transport"].string == "webrtc" {
            try await webRTC(transport, receive: receive)
            return
        }
        if access.target.avcc {
            do {
                try await watchAVCC(jpeg: false, receive: receive)
            } catch DeviceMediaFailure.http(409) {
                try Task.checkCancellation()
                try await webRTC(transport, receive: receive)
            } catch DeviceMediaFailure.invalidFrame where access.target.platform == .ios && access.target.hostKind.hasHostTools {
                try Task.checkCancellation()
                try await watchAVCC(jpeg: true, receive: receive)
            }
        } else {
            guard canOperate else { throw ClientError.message("This Android stream requires device operation access.") }
            try await watchSocket(video: true, receive: receive)
        }
    }

    private func webRTC(_ settings: Wire, receive: @escaping @Sendable (Event) async -> Void) async throws {
        await receive(.webRTC(settings))
        if canOperate { await watchInput(receive: receive) }
    }

    private func watchAVCC(jpeg: Bool, receive: @escaping @Sendable (Event) async -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            if canOperate { group.addTask { await self.watchInput(receive: receive) } }
            defer { group.cancelAll() }
            try await watchHTTP(jpeg: jpeg, receive: receive)
        }
    }

    private func watchInput(receive: @escaping @Sendable (Event) async -> Void) async {
        for attempt in 0...1 {
            do {
                try await watchSocket(video: false, receive: receive)
                return
            } catch {
                guard !Task.isCancelled else { return }
                await receive(.input(false))
                if attempt == 0 {
                    do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
                }
            }
        }
    }

    private func watchHTTP(jpeg: Bool, receive: @escaping @Sendable (Event) async -> Void) async throws {
        let feed = try DeviceHTTPFeed(request: access.request(jpeg ? .mjpeg : .avcc))
        defer { feed.stop() }
        var mjpeg: DeviceJPEGReader?
        var avcc = DeviceAVCCReader()
        var decoder = DeviceH264()
        for try await event in feed.events {
            try Task.checkCancellation()
            switch event {
            case .response(let status, let contentType):
                guard (200..<300).contains(status) else { throw DeviceMediaFailure.http(status) }
                if jpeg {
                    guard let reader = DeviceJPEGReader(contentType: contentType) else { throw DeviceMediaFailure.invalidFrame }
                    mjpeg = reader
                }
            case .bytes(let data):
                if jpeg {
                    for bytes in try mjpeg?.append(data) ?? [] {
                        if let image = DeviceMediaAccess.image(bytes) { await receive(.image(image)) }
                    }
                } else {
                    for frame in try avcc.append(data) {
                        try Task.checkCancellation()
                        switch frame.kind {
                        case .seed:
                            if let image = DeviceMediaAccess.image(frame.bytes) { await receive(.image(image)) }
                        case .description:
                            try decoder.describeAVCC(frame.bytes)
                            await receive(.resetVideo)
                        case .keyframe, .delta:
                            if let sample = try decoder.sample(frame.bytes, key: frame.kind == .keyframe) {
                                await receive(.video(sample))
                            }
                        }
                    }
                }
            }
        }
        try Task.checkCancellation()
        throw DeviceMediaFailure.disconnected
    }

    private func primeIOSHelper() async {
        guard access.target.avcc, access.target.hostKind.hasHostTools, var request = try? access.request(.mjpeg) else { return }
        request.timeoutInterval = 2
        let feed = DeviceHTTPFeed(request: request)
        defer { feed.stop() }
        do { for try await _ in feed.events { return } }
        catch {}
    }

    private func watchSocket(video: Bool, receive: @escaping @Sendable (Event) async -> Void) async throws {
        await primeIOSHelper()
        try Task.checkCancellation()
        let connection = try access.socket(video: video)
        let socket = connection.task
        self.socket = socket
        inputReady = false
        socket.resume()
        defer {
            self.socket = nil
            inputReady = false
            connection.stop()
        }
        try await withTaskCancellationHandler {
            do {
                try await connection.waitForOpen()
                if !access.target.avcc {
                    inputReady = true
                    await receive(.input(true))
                }
                var decoder = DeviceH264()
                while !Task.isCancelled {
                    switch try await socket.receive() {
                    case .data(let bytes):
                        if access.target.avcc {
                            await acceptInputConfig(bytes, receive: receive)
                        } else if video, let frame = try decoder.annexB(bytes) {
                            await receive(.video(frame))
                        }
                    case .string(let text):
                        if !access.target.avcc, video,
                           let value = try? JSONDecoder().decode(Wire.self, from: Data(text.utf8)),
                           value["type"].string == "video-session" {
                            decoder = DeviceH264()
                            await receive(.resetVideo)
                            try await socket.send(.string("{\"type\":\"reset-video\",\"ack\":false}"))
                        }
                    @unknown default: break
                    }
                }
            } catch {
                try Task.checkCancellation()
                if [1008, 4401].contains(socket.closeCode.rawValue) { throw DeviceMediaFailure.http(401) }
                if let failure = error as? DeviceMediaFailure { throw failure }
                throw DeviceMediaFailure.disconnected
            }
        } onCancel: {
            connection.stop()
        }
    }

    private func acceptInputConfig(_ bytes: Data, receive: @escaping @Sendable (Event) async -> Void) async {
        if bytes.first == 0x83 {
            inputReady = true
            await receive(.input(screen?.inputUnavailable != true))
        } else if bytes.first == 0x82, let value = try? JSONDecoder().decode(Wire.self, from: bytes.dropFirst()),
                  let config = DeviceScreenConfig(value) {
            screen = config
            orientation = config.orientation
            await receive(.screen(config))
            await receive(.input(inputReady && !config.inputUnavailable))
        }
    }

    func send(_ input: DeviceInput) async throws {
        guard canOperate, inputReady, screen?.inputUnavailable != true, let socket else { return }
        if access.target.avcc {
            if let message = try avccInput(input) { try await socket.send(.data(message)) }
        } else {
            for payload in androidInput(input) {
                let bytes = try JSONEncoder().encode(payload)
                try await socket.send(.string(String(decoding: bytes, as: UTF8.self)))
            }
        }
    }

    private func avccInput(_ input: DeviceInput) throws -> Data? {
        let tag: UInt8
        let payload: Payload
        switch input {
        case .touch(let phase, let point):
            let raw = access.target.platform == .ios ? screen?.rawPoint(point) ?? point : point
            tag = 0x03
            payload = ["type": .string(phase.rawValue), "x": .double(raw.x), "y": .double(raw.y)]
        case .button(let button):
            let name: String
            switch button {
            case .home: name = "home"
            case .power: name = "lock"
            case .recents: name = "app_switcher"
            case .back:
                guard access.target.platform == .android else { return nil }
                name = "back"
            }
            tag = 0x04
            payload = ["button": .string(name)]
        case .hid(let code, let down):
            tag = 0x06
            payload = ["type": .string(down ? "down" : "up"), "usage": .int(code)]
        case .rotate:
            guard access.target.platform == .ios else { return nil }
            let next = (orientation ?? .portrait).next
            orientation = next
            tag = 0x07
            payload = ["orientation": .string(next.rawValue)]
        case .key, .text: return nil
        }
        return try Data([tag]) + JSONEncoder().encode(payload)
    }

    private func androidInput(_ input: DeviceInput) -> [Payload] {
        switch input {
        case .touch(let phase, let point):
            return [["type": .string("touch"), "action": .string(phase == .begin ? "down" : phase == .end ? "up" : "move"),
                     "x": .double(point.x), "y": .double(point.y)]]
        case .button(let button):
            let type = switch button {
            case .home: "home"
            case .back: "back"
            case .recents: "recents"
            case .power: "power"
            }
            return [["type": .string(type)]]
        case .key(let key):
            return [["type": .string("key"), "keycode": .int(key)]]
        case .text(let text):
            var chunks: [Payload] = []
            var buffer = ""
            var count = 0
            for character in text.unicodeScalars {
                let size = character.utf8.count
                if count + size > 300 {
                    chunks.append(["type": .string("text"), "text": .string(buffer)])
                    if chunks.count == 64 { return chunks }
                    buffer = ""
                    count = 0
                }
                buffer.unicodeScalars.append(character)
                count += size
            }
            if !buffer.isEmpty { chunks.append(["type": .string("text"), "text": .string(buffer)]) }
            return chunks
        case .hid, .rotate: return []
        }
    }
}
