import Foundation

@MainActor
final class VoiceSpeechStream {
    private let socket: URLSessionWebSocketTask
    private var revision = -1

    init(socket: URLSessionWebSocketTask) { self.socket = socket }

    func start(options: Wire) async throws {
        let payload = try JSONEncoder().encode(Wire.object(["type": .string("start"), "options": options]))
        guard payload.count <= VoicePCM.optionsLimit else { throw ClientError.invalidResponse }
        socket.resume()
        try await socket.send(.string(String(decoding: payload, as: UTF8.self)))
        guard try await receive()["type"].string == "ready" else { throw ClientError.invalidResponse }
    }

    func send(_ data: Data) async throws -> String? {
        guard !data.isEmpty, data.count <= VoicePCM.chunkLimit, data.count.isMultiple(of: VoicePCM.bytesPerSample) else {
            throw ClientError.invalidResponse
        }
        try await socket.send(.data(data))
        let update = try await receive()
        guard update["type"].string == "update", let next = update["revision"].int, next >= revision else {
            throw ClientError.invalidResponse
        }
        revision = next
        if update["text"] == .null { return nil }
        let committed = try update["text"].requireString("committed")
        let tentative = try update["text"].requireString("tentative")
        return [committed, tentative].filter { !$0.isEmpty }.joined(separator: " ")
    }

    func finish() async throws -> String {
        try await socket.send(.string(#"{"type":"finish"}"#))
        let result = try await receive()
        guard result["type"].string == "finished" else { throw ClientError.invalidResponse }
        return try result.requireString("text")
    }

    func cancel() { socket.cancel(with: .goingAway, reason: nil) }

    private func receive() async throws -> Wire {
        let socket = socket
        let reply = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask {
                try await withTaskCancellationHandler { try await socket.receive() } onCancel: {
                    socket.cancel(with: .goingAway, reason: nil)
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(120))
                throw ClientError.message("Live transcription stopped responding.")
            }
            defer { group.cancelAll() }
            guard let reply = try await group.next() else { throw ClientError.disconnected }
            return reply
        }
        let data: Data = switch reply {
        case .string(let text): Data(text.utf8)
        case .data(let bytes): bytes
        @unknown default: throw ClientError.invalidResponse
        }
        let event = try JSONDecoder().decode(Wire.self, from: data)
        if event["type"].string == "error" {
            throw ClientError.message(event["message"].string ?? "Live transcription failed.")
        }
        return event
    }
}
