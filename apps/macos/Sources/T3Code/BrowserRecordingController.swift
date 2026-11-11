import AppKit

@MainActor
final class BrowserRecordingController {
    enum Phase { case idle, starting, recording, finishing }

    @MainActor
    private final class Capture {
        let target: BrowserTabTarget
        let preferences: BrowserRecordingPreferences
        let encoder: BrowserRecordingEncoder
        var phase = Phase.starting
        var startup: Task<Bool, Never>?
        var stream: Task<Void, Never>?
        var frameDeadline: Task<Void, Never>?
        var completion: Task<Void, Never>?
        var showWhenFinished = false

        var canStop: Bool { phase == .starting || phase == .recording }

        init(target: BrowserTabTarget, preferences: BrowserRecordingPreferences, directory: URL) {
            self.target = target
            self.preferences = preferences
            encoder = BrowserRecordingEncoder(directory: directory, preferences: preferences)
        }
    }

    private let directory: URL
    private var captures: [BrowserTabTarget.Key: Capture] = [:]
    private(set) var latest: BrowserRecordingClip?
    private(set) var notice: String?
    var onChange: (() -> Void)?
    var onPreview: ((BrowserRecordingClip) -> Void)?

    var activeTargets: [BrowserTabTarget] { captures.values.map(\.target) }
    var stoppableTargets: [BrowserTabTarget] { captures.values.filter(\.canStop).map(\.target) }
    var isBusy: Bool { !captures.isEmpty }

    init(directory: URL) {
        self.directory = directory
        latest = BrowserRecordingClip.latest(in: directory)
    }

    func phase(for key: BrowserTabTarget.Key?) -> Phase {
        guard let key else { return .idle }
        return captures[key]?.phase ?? .idle
    }

    func start(_ target: BrowserTabTarget, api: EnvironmentAPI, image: CGImage, preferences: BrowserRecordingPreferences) {
        guard captures[target.key] == nil else { return }
        let run = Capture(target: target, preferences: preferences, directory: directory)
        captures[target.key] = run
        notice = nil
        run.startup = Task { [weak self, weak run] in
            guard let run else { return false }
            do {
                try await run.encoder.start(with: image) { [weak self, weak run] error in
                    Task { @MainActor in
                        if let run { self?.failed(run, error) }
                    }
                }
                guard let self, captures[target.key] === run else { return false }
                if run.phase == .starting {
                    run.phase = .recording
                    watch(run, api: api)
                    onChange?()
                }
                return true
            } catch {
                self?.failed(run, error.localizedDescription)
                return false
            }
        }
        onChange?()
    }

    private func watch(_ run: Capture, api: EnvironmentAPI) {
        let encoder = run.encoder
        let target = run.target
        run.stream = Task { [weak self, weak run] in
            do {
                let stream = try await api.browserStream(threadId: target.threadID, tabId: target.tabID, interactive: false)
                try Task.checkCancellation()
                try await stream.watch { event in
                    switch event {
                    case .image(let image): await encoder.offer(image)
                    case .viewport(let size): await encoder.setViewport(size)
                    case .pointer(let phase, let x, let y) where phase == "click":
                        await encoder.markAgentClick(x: x, y: y)
                    default: break
                    }
                }
                if let run, !Task.isCancelled { self?.interrupted(run, "The recorded browser tab disconnected.") }
            } catch {
                if let run, !Task.isCancelled { self?.interrupted(run, error.localizedDescription) }
            }
        }
        run.frameDeadline = Task { [weak self, weak run] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard let run, !(await encoder.receivedStreamFrame), !Task.isCancelled else { return }
            self?.interrupted(run, "The recording stream did not receive a frame.")
        }
    }

    func observeInput(_ input: Payload, key: BrowserTabTarget.Key, viewport: CGSize) {
        guard let capture = captures[key], capture.phase == .recording else { return }
        let encoder = capture.encoder
        if capture.preferences.showMousePresses, let point = BrowserRecordingInput.pressPoint(input, viewport: viewport) {
            Task { await encoder.markPress(point) }
        }
        if capture.preferences.showShortcuts, let shortcut = BrowserRecordingInput.shortcut(input) {
            Task { await encoder.markShortcut(shortcut) }
        }
    }

    func sync(connection: UUID?) {
        for capture in captures.values where capture.target.connection != connection {
            interrupted(capture, "The recording ended when the environment connection changed.")
        }
    }

    @discardableResult
    func stop(_ key: BrowserTabTarget.Key, show: Bool = true) -> Task<Void, Never>? {
        guard let run = captures[key] else { return nil }
        if let pending = run.completion {
            if !show { run.showWhenFinished = false }
            return pending
        }
        run.phase = .finishing
        run.showWhenFinished = show
        run.stream?.cancel()
        run.frameDeadline?.cancel()
        let completion = Task { [weak self, weak run] in
            guard let run, await run.startup?.value == true else { return }
            do {
                let file = try await run.encoder.finish()
                guard let self, captures[key] === run else { return }
                let clip = BrowserRecordingClip(file: file, target: run.target)
                latest = clip
                captures[key] = nil
                onChange?()
                if run.showWhenFinished { onPreview?(clip) }
            } catch {
                self?.failed(run, error.localizedDescription)
            }
        }
        run.completion = completion
        onChange?()
        return completion
    }

    @discardableResult
    func stopAll() -> [Task<Void, Never>] {
        Array(captures.keys).compactMap { stop($0, show: false) }
    }

    func finishBeforeQuit() async {
        for task in stopAll() { await task.value }
    }

    func previewLatest() {
        if let latest { onPreview?(latest) }
    }

    private func interrupted(_ run: Capture, _ message: String) {
        guard captures[run.target.key] === run, run.canStop else { return }
        notice = message
        stop(run.target.key, show: false)
    }

    private func failed(_ run: Capture, _ message: String) {
        guard captures[run.target.key] === run else { return }
        run.stream?.cancel()
        run.frameDeadline?.cancel()
        captures[run.target.key] = nil
        notice = message
        onChange?()
    }
}
