import Foundation

@MainActor
final class VoiceDictation {
    enum Phase: Equatable {
        case idle, preparing, recording, transcribing, cleaning, notice(String), failed(String)

        var busy: Bool { self == .preparing || self == .recording || self == .transcribing || self == .cleaning }
    }

    struct Cleanup {
        let draft: Wire
        let vocabulary: [Wire]
    }

    struct Request {
        let owner: UUID
        let target: VoiceTarget
        let preferences: VoiceInputPreferences
        let vocabulary: [Wire]
        let api: EnvironmentAPI
        var cleanup: Cleanup?
    }

    private final class Session {
        let request: Request
        let isCurrent: () -> Bool
        let isCleanupCurrent: () -> Bool
        var task: Task<Void, Never>?
        var limit: Task<Void, Never>?
        var recording: VoiceRecording?
        var stream: VoiceSpeechStream?
        var cleanupTask: Task<String, Error>?
        var send = false

        init(request: Request, isCurrent: @escaping () -> Bool, isCleanupCurrent: @escaping () -> Bool) {
            self.request = request
            self.isCurrent = isCurrent
            self.isCleanupCurrent = isCleanupCurrent
        }
    }

    private let capture: () async throws -> VoiceRecording
    private var session: Session?
    private(set) var owner: UUID?
    private(set) var phase: Phase = .idle
    private(set) var preview: String?
    var onChange: (() -> Void)?

    init(capture: @escaping () async throws -> VoiceRecording = VoiceRecording.microphone) {
        self.capture = capture
    }

    func start(_ request: Request, isCurrent: @escaping () -> Bool, isCleanupCurrent: @escaping () -> Bool = { false },
               commit: @escaping (_ transcript: String, _ language: String, _ send: Bool) throws -> Void) {
        guard session == nil, request.preferences.grant != nil, isCurrent() else { return }
        let session = Session(request: request, isCurrent: isCurrent, isCleanupCurrent: isCleanupCurrent)
        self.session = session
        owner = request.owner
        update(.preparing, preview: nil)
        session.task = Task { [weak self] in
            await self?.run(session, commit: commit)
        }
    }

    func finish(owner: UUID, send: Bool = false) {
        guard let session, self.owner == owner, phase == .recording else { return }
        session.send = send
        stopCapture(session)
        update(.transcribing, preview: preview)
    }

    func cancel(owner: UUID? = nil) {
        guard let current = self.owner, owner == nil || current == owner else { return }
        let session = session
        self.session = nil
        self.owner = nil
        session?.task?.cancel()
        if let session { release(session) }
        update(.idle, preview: nil)
    }

    func invalidate(target: VoiceTarget?, grant: UUID?, cleanupGrant: UUID?) {
        guard let session else { return }
        if session.request.target != target || session.request.preferences.grant != grant { cancel() }
        else if session.request.preferences.cleanupGrant != cleanupGrant { session.cleanupTask?.cancel() }
    }

    private func run(_ session: Session, commit: (String, String, Bool) throws -> Void) async {
        defer { release(session) }
        let request = session.request
        do {
            try requireCurrent(session)
            let status = try await prepare(request)
            try requireCurrent(session)
            let options = recognitionOptions(session, status: status)
            let language = options["speechLanguage"].string ?? "auto"
            if status?.streams == true {
                let stream = try await request.api.voiceStream()
                session.stream = stream
                try requireCurrent(session)
                try await stream.start(options: options)
            }
            try requireCurrent(session)
            let recording = try await capture()
            session.recording = recording
            try requireCurrent(session)
            update(.recording, preview: nil)
            session.limit = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(300)) }
                catch { return }
                self?.finish(owner: request.owner)
            }

            var total = 0
            var audio = Data()
            for try await data in recording.audio {
                try requireCurrent(session)
                guard data.count <= VoicePCM.chunkLimit, data.count.isMultiple(of: VoicePCM.bytesPerSample),
                      total <= VoicePCM.recordingLimit - data.count else {
                    throw ClientError.message("Voice recordings are limited to five minutes.")
                }
                if data.isEmpty { continue }
                total += data.count
                if let stream = session.stream {
                    if let text = try await stream.send(data) {
                        try requireCurrent(session)
                        update(phase, preview: text)
                    }
                } else { audio.append(data) }
            }
            try requireCurrent(session)
            stopCapture(session)
            update(.transcribing, preview: preview)
            guard total > 0 else { throw ClientError.message("No usable microphone audio was recorded.") }
            let transcript: String
            if let stream = session.stream { transcript = try await stream.finish() }
            else {
                transcript = try await request.api.transcribeVoice(audio, options: recognitionOptions(session, status: status),
                                                                   cloud: request.preferences.cloud)
            }
            try requireCurrent(session)
            let (text, notice) = await clean(transcript, session: session)
            try requireCurrent(session)
            self.session = nil
            owner = notice == nil ? nil : request.owner
            update(notice.map(Phase.notice) ?? .idle, preview: nil)
            do { try commit(text, language, session.send) }
            catch { fail(request.owner, error: error) }
        } catch {
            guard self.session === session else { return }
            self.session = nil
            if !Task.isCancelled, session.isCurrent(), !(error is CancellationError) { fail(request.owner, error: error) }
            else {
                owner = nil
                update(.idle, preview: nil)
            }
        }
    }

    private func prepare(_ request: Request) async throws -> VoiceStatus? {
        if let cloud = request.preferences.cloud {
            guard cloud.isValid else { throw ClientError.message(cloud.provider.error("model-unavailable")) }
            let keys = try await request.api.cloudVoiceKeys()
            guard keys[cloud.provider.rawValue].bool == true else { throw ClientError.message(cloud.provider.error("missing-key")) }
            return nil
        }
        let reply = try await request.api.http("/api/voice/status", timeout: 30)
        guard let status = VoiceStatus(reply) else { throw ClientError.invalidResponse }
        guard status.supported else { throw ClientError.message(status.reason ?? "Voice input is unavailable on this environment.") }
        guard status.state != "missing-model" else { throw ClientError.message("Select an installed speech model in Voice Settings.") }
        guard status.state != "transcribing" else { throw ClientError.message("The environment is already transcribing audio.") }
        return status
    }

    private func recognitionOptions(_ session: Session, status: VoiceStatus?) -> Wire {
        let request = session.request
        let cleanup = session.isCleanupCurrent() ? request.cleanup : nil
        return request.preferences.options(for: status, vocabulary: cleanup?.vocabulary ?? request.vocabulary, cleanup: cleanup != nil)
    }

    private func clean(_ transcript: String, session: Session) async -> (String, String?) {
        let request = session.request
        guard let cleanup = request.cleanup, session.isCleanupCurrent(), transcript.utf16.count <= 100_000,
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (transcript, nil) }
        update(.cleaning, preview: transcript)
        let task = Task {
            try requireCurrent(session)
            guard session.isCleanupCurrent() else { throw CancellationError() }
            let payload = Wire.object([
                "transcript": .string(transcript), "draft": cleanup.draft,
                "options": request.preferences.cleanupOptions(vocabulary: cleanup.vocabulary),
            ])
            let body = try JSONEncoder().encode(payload)
            let reply = try await request.api.http("/api/voice/post-process", method: "POST", body: body,
                                                   contentType: "application/json", timeout: 130)
            try Task.checkCancellation()
            return try reply.requireString("text").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        session.cleanupTask = task
        defer { session.cleanupTask = nil }
        do {
            let cleaned = try await task.value
            return (session.isCleanupCurrent() && !cleaned.isEmpty ? cleaned : transcript, nil)
        } catch {
            let notice = session.isCleanupCurrent() && !Task.isCancelled && !(error is CancellationError)
                ? "Cleanup couldn’t finish. The original transcript was added." : nil
            return (transcript, notice)
        }
    }

    private func requireCurrent(_ session: Session) throws {
        try Task.checkCancellation()
        guard self.session === session, session.isCurrent() else { throw CancellationError() }
    }

    private func stopCapture(_ session: Session) {
        session.limit?.cancel()
        session.limit = nil
        session.recording?.stop()
        session.recording = nil
    }

    private func release(_ session: Session) {
        stopCapture(session)
        session.stream?.cancel()
        session.stream = nil
        session.cleanupTask?.cancel()
        session.cleanupTask = nil
        session.task = nil
    }

    private func fail(_ owner: UUID, error: Error) {
        self.owner = owner
        update(.failed(error.localizedDescription), preview: nil)
    }

    private func update(_ phase: Phase, preview: String?) {
        let changed = self.phase != phase || self.preview != preview
        self.phase = phase
        self.preview = preview
        if changed { onChange?() }
    }
}
