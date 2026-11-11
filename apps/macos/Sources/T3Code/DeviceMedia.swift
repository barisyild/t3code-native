import Foundation
import ImageIO

enum DeviceMediaFailure: LocalizedError {
    case http(Int)
    case invalidFrame
    case disconnected
    case overloaded

    var errorDescription: String? {
        switch self {
        case .http(let status): "The device host refused the stream (HTTP \(status))."
        case .invalidFrame: "The device sent an invalid or unsupported frame."
        case .disconnected: "The device stream disconnected."
        case .overloaded: "The device stream fell behind."
        }
    }
}

struct DeviceMediaAccess: Sendable {
    enum Route {
        case info, avcc, mjpeg, input(video: Bool), screenshot, offer, close
    }

    let origin: URL
    let target: DeviceTarget
    let ticket: String

    func request(_ route: Route, body: Payload? = nil) throws -> URLRequest {
        guard var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              parts.scheme == "https" || parts.scheme == "http", parts.host != nil, parts.user == nil, parts.password == nil,
              let device = target.key.deviceID.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_~"))) else {
            throw ClientError.invalidResponse
        }
        let vendor = target.avcc ? "serve-sim" : "serve-emu"
        var query = [URLQueryItem(name: "hostId", value: target.key.hostID), URLQueryItem(name: "wsTicket", value: ticket)]
        let suffix: String
        var method = "GET"
        var timeout: TimeInterval = 20
        switch route {
        case .info:
            suffix = "/api"
            timeout = 5
            query.append(.init(name: "device", value: target.key.deviceID))
        case .avcc:
            suffix = "/helper/\(device)/stream.avcc"
        case .mjpeg:
            suffix = "/helper/\(device)/stream.mjpeg"
        case .input(let video):
            parts.scheme = parts.scheme == "https" ? "wss" : "ws"
            suffix = target.avcc ? "/helper/ws" : "/ws"
            query.append(.init(name: "device", value: target.key.deviceID))
            if !target.avcc { query.append(.init(name: video ? "frame-meta" : "video", value: video ? "1" : "0")) }
        case .screenshot:
            method = "POST"
            suffix = "/api/screenshot"
            query.append(.init(name: "device", value: target.key.deviceID))
        case .offer, .close:
            method = "POST"
            let action = route.isOffer ? "offer" : "close"
            suffix = target.avcc ? "/helper/\(device)/webrtc/\(action)" : "/webrtc/\(action)"
            if !target.avcc { query.append(.init(name: "device", value: target.key.deviceID)) }
        }
        parts.percentEncodedPath = "/api/device-hub/vendor/\(vendor)" + suffix
        parts.queryItems = query
        parts.fragment = nil
        guard let url = parts.url else { throw ClientError.invalidResponse }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    func socket(video: Bool) throws -> DeviceSocket {
        try DeviceSocket(request: request(.input(video: video)))
    }

    func json(_ route: Route, body: Payload? = nil) async throws -> Wire {
        let bytes = try await data(route, body: body)
        if bytes.isEmpty { return .null }
        return try JSONDecoder().decode(Wire.self, from: bytes)
    }

    func screenshot() async throws -> Data {
        let bytes = try await data(.screenshot)
        guard Self.image(bytes) != nil else { throw DeviceMediaFailure.invalidFrame }
        return bytes
    }

    private func data(_ route: Route, body: Payload? = nil) async throws -> Data {
        let feed = try DeviceHTTPFeed(request: request(route, body: body))
        defer { feed.stop() }
        var data = Data()
        for try await event in feed.events {
            try Task.checkCancellation()
            switch event {
            case .response(let status, _):
                guard (200..<300).contains(status) else { throw DeviceMediaFailure.http(status) }
            case .bytes(let bytes):
                guard data.count + bytes.count <= 8 * 1024 * 1024 else { throw DeviceMediaFailure.invalidFrame }
                data.append(bytes)
            }
        }
        try Task.checkCancellation()
        return data
    }

    static func image(_ bytes: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...7_680).contains(width), (1...7_680).contains(height) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}

private extension DeviceMediaAccess.Route {
    var isOffer: Bool {
        if case .offer = self { return true }
        return false
    }
}

final class DeviceSocket: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let opened: AsyncThrowingStream<Void, Error>
    private let continuation: AsyncThrowingStream<Void, Error>.Continuation
    private var session: URLSession!
    private var webSocketTask: URLSessionWebSocketTask!
    var task: URLSessionWebSocketTask { webSocketTask }

    init(request: URLRequest) {
        let (opened, continuation) = AsyncThrowingStream<Void, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.opened = opened
        self.continuation = continuation
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        webSocketTask = session.webSocketTask(with: request)
        webSocketTask.maximumMessageSize = 8 * 1024 * 1024
    }

    func waitForOpen() async throws {
        for try await _ in opened { return }
        throw DeviceMediaFailure.disconnected
    }

    func stop() {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
        continuation.finish()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        continuation.yield(())
        continuation.finish()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        continuation.finish(throwing: error)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class DeviceHTTPFeed: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case response(Int, String?)
        case bytes(Data)
    }

    let events: AsyncThrowingStream<Event, Error>
    private let continuation: AsyncThrowingStream<Event, Error>.Continuation
    private var session: URLSession!

    init(request: URLRequest) {
        let (events, continuation) = AsyncThrowingStream<Event, Error>.makeStream(bufferingPolicy: .bufferingOldest(24))
        self.events = events
        self.continuation = continuation
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        session.dataTask(with: request).resume()
    }

    func stop() {
        session.invalidateAndCancel()
        continuation.finish()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            continuation.finish(throwing: ClientError.invalidResponse)
            completionHandler(.cancel)
            return
        }
        continuation.yield(.response(response.statusCode, response.value(forHTTPHeaderField: "Content-Type") ?? response.mimeType))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if case .dropped = continuation.yield(.bytes(data)) {
            continuation.finish(throwing: DeviceMediaFailure.overloaded)
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation.finish(throwing: error) }
        else { continuation.finish() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
