import Foundation

actor RPCSocket {
    struct Chunk: Sendable {
        let requestId: String
        let values: [Wire]
    }

    typealias Stream = AsyncThrowingStream<Chunk, Error>

    private enum Handler {
        case request(CheckedContinuation<Wire, Error>, Task<Void, Never>)
        case stream(Stream.Continuation)

        func finish(_ result: Result<Wire, Error>) {
            switch self {
            case .request(let continuation, let timer):
                timer.cancel()
                continuation.resume(with: result)
            case .stream(let continuation):
                switch result {
                case .success: continuation.finish()
                case .failure(let error): continuation.finish(throwing: error)
                }
            }
        }
    }

    private let socket: URLSessionWebSocketTask
    private var reader: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var handlers: [String: Handler] = [:]
    private var lastFrame = ContinuousClock.now
    private var closed = false

    init(session: URLSession, url: URL) {
        socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = 64 * 1024 * 1024
    }

    func start() {
        guard reader == nil, !closed else { return }
        socket.resume()
        reader = Task { await receive() }
        heartbeat = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(10))
                    guard ContinuousClock.now - lastFrame < .seconds(35) else {
                        close(ClientError.timedOut)
                        return
                    }
                    try await send(["_tag": .string("Ping")])
                } catch {
                    if !Task.isCancelled { close(ClientError.disconnected) }
                    return
                }
            }
        }
    }

    func close(_ error: any Error = ClientError.disconnected) {
        guard !closed else { return }
        closed = true
        socket.cancel(with: .goingAway, reason: nil)
        reader?.cancel()
        heartbeat?.cancel()
        let pending = handlers.values
        handlers.removeAll()
        for handler in pending { handler.finish(.failure(error)) }
    }

    func request(_ method: String, _ payload: Payload = [:], timeout: Duration = .seconds(120)) async throws -> Wire {
        let id = UUID().uuidString
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !closed, !Task.isCancelled else {
                    continuation.resume(throwing: closed ? ClientError.disconnected : CancellationError())
                    return
                }
                let timer = Task {
                    do { try await Task.sleep(for: timeout) }
                    catch { return }
                    await cancel(id, error: ClientError.timedOut)
                }
                handlers[id] = .request(continuation, timer)
                Task { await sendRequest(id, method, payload) }
            }
        } onCancel: {
            Task { await self.cancel(id, error: CancellationError()) }
        }
    }

    func subscribe(_ method: String, _ payload: Payload = [:]) async throws -> Stream {
        guard !closed else { throw ClientError.disconnected }
        try Task.checkCancellation()
        let id = UUID().uuidString
        // The server can send eight unacknowledged chunks per stream before waiting.
        let (stream, continuation) = Stream.makeStream(bufferingPolicy: .bufferingOldest(16))
        continuation.onTermination = { [weak self] reason in
            guard case .cancelled = reason else { return }
            Task { await self?.cancel(id, error: CancellationError()) }
        }
        handlers[id] = .stream(continuation)
        await sendRequest(id, method, payload)
        return stream
    }

    func acknowledge(_ chunk: Chunk) async throws {
        guard handlers[chunk.requestId] != nil else { return }
        try await send(["_tag": .string("Ack"), "requestId": .string(chunk.requestId)])
    }

    private func cancel(_ id: String, error: any Error) async {
        guard let handler = handlers.removeValue(forKey: id) else { return }
        handler.finish(.failure(error))
        try? await send(["_tag": .string("Interrupt"), "requestId": .string(id)])
    }

    private func sendRequest(_ id: String, _ method: String, _ payload: Payload) async {
        guard handlers[id] != nil else { return }
        do {
            try await send([
                "_tag": .string("Request"), "id": .string(id), "tag": .string(method),
                "payload": .object(payload), "headers": .array([]),
            ])
        } catch {
            close(ClientError.disconnected)
        }
    }

    private func send(_ payload: Payload) async throws {
        guard !closed else { throw ClientError.disconnected }
        let data = try JSONEncoder().encode(payload)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func receive() async {
        do {
            while !Task.isCancelled {
                let data: Data
                switch try await socket.receive() {
                case .string(let text): data = Data(text.utf8)
                case .data(let bytes): data = bytes
                @unknown default: throw ClientError.invalidResponse
                }
                let frame = try JSONDecoder().decode(Wire.self, from: data)
                lastFrame = .now
                let messages = frame.object == nil ? frame.array : [frame]
                for message in messages { try handle(message) }
            }
        } catch {
            if !Task.isCancelled {
                close(error is DecodingError ? ClientError.invalidResponse : error as? ClientError ?? .disconnected)
            }
        }
    }

    private func handle(_ frame: Wire) throws {
        let tag = try frame.requireString("_tag")
        switch tag {
        case "Chunk":
            guard let id = frame["requestId"].identifier,
                  case .stream(let continuation) = handlers[id] else { return }
            if case .dropped = continuation.yield(Chunk(requestId: id, values: frame["values"].array)) {
                throw ClientError.invalidResponse
            }
        case "Exit":
            guard let id = frame["requestId"].identifier,
                  let handler = handlers.removeValue(forKey: id) else { return }
            let exit = frame["exit"]
            if exit["_tag"].string == "Success" {
                handler.finish(.success(exit["value"]))
            } else {
                let failure = exit["cause"].array.first { $0["_tag"].string == "Fail" }?["error"]
                handler.finish(.failure(ClientError.rpc(failure ?? .null)))
            }
        case "Defect", "ClientProtocolError": throw ClientError.invalidResponse
        default: break
        }
    }
}
