import Foundation

@MainActor
final class BrowserProfileReporter {
    private var socket: RPCSocket?
    private var pending: Payload?
    private var attempted: Payload?
    private var task: Task<Void, Never>?

    func update(_ report: Payload, on socket: RPCSocket) {
        if self.socket !== socket {
            reset()
            self.socket = socket
        }
        pending = report
        guard task == nil, attempted != report else { return }
        task = Task { [weak self, socket] in
            while let self, !Task.isCancelled, self.socket === socket, let next = pending, attempted != next {
                attempted = next
                _ = try? await socket.request("preview.reportProfiles", next, timeout: .seconds(12))
            }
            if !Task.isCancelled, self?.socket === socket { self?.task = nil }
        }
    }

    func reset() {
        task?.cancel()
        task = nil
        socket = nil
        pending = nil
        attempted = nil
    }
}
