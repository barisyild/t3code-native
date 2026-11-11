import AVFoundation
import Foundation
import Testing
@testable import T3Code

struct BrowserRecordingTests {
    @Test func recordingPreferencesKeepInputOptionsLocalAndReportFrameRate() throws {
        var preferences = BrowserPreferences()
        #expect(preferences.recording.frameRate == .fps30)
        #expect(!preferences.recording.showMousePresses && !preferences.recording.showShortcuts)
        preferences.recording.frameRate = .fps60
        preferences.recording.showMousePresses = true
        preferences.recording.showShortcuts = true
        let decoded = try JSONDecoder().decode(Wire.self, from: JSONEncoder().encode(preferences.storedValue))
        #expect(BrowserPreferences(decoded) == preferences)
        #expect(preferences.report["recordingFrameRate"] == .int(60))
        #expect(preferences.report["recordingShowShortcuts"] == nil)
        #expect(preferences.report["recordingShowMousePresses"] == nil)
    }

    @Test func recordingCuesShowShortcutsAndPressesWithoutTypedText() {
        #expect(BrowserRecordingInput.shortcut(["type": .string("text"), "text": .string("test input")]) == nil)
        let key: Payload = ["type": .string("key"), "action": .string("down"), "key": .string("a"), "modifiers": .int(0)]
        #expect(BrowserRecordingInput.shortcut(key) == nil)
        #expect(BrowserRecordingInput.shortcut(key.merging(["modifiers": .int(4)]) { _, new in new }) == "⌘A")
        #expect(BrowserRecordingInput.shortcut(key.merging(["key": .string("ArrowLeft")]) { _, new in new }) == "←")
        #expect(BrowserRecordingInput.shortcut(key.merging(["key": .string("é"), "modifiers": .int(4)]) { _, new in new }) == nil)
        let press: Payload = ["type": .string("mouse"), "action": .string("down"), "x": .int(120), "y": .int(75)]
        let viewport = CGSize(width: 480, height: 300)
        #expect(BrowserRecordingInput.pressPoint(press, viewport: viewport) == CGPoint(x: 0.25, y: 0.25))
        #expect(BrowserRecordingInput.pressPoint(press, viewport: .zero) == nil)
        #expect(BrowserRecordingInput.pressPoint(press.merging(["action": .string("move")]) { _, new in new }, viewport: viewport) == nil)
    }

    @MainActor
    @Test func stoppingDuringStartupProducesAPlayableClipWithoutConnectingASecondViewer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("t3-recording-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try #require(CGContext(data: nil, width: 321, height: 241, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 321, height: 241))
        let image = try #require(context.makeImage())
        let recorder = BrowserRecordingController(directory: directory)
        let target = BrowserTabTarget(environmentID: "fixture", connection: UUID(), threadID: "thread", tabID: "tab", title: "Fixture")
        let origin = try #require(URL(string: "http://127.0.0.1:1"))
        let api = EnvironmentAPI(origin: origin) { _ in
            Issue.record("Immediate stop opened a recording stream.")
            throw ClientError.disconnected
        }
        recorder.start(target, api: api, image: image, preferences: .init())
        #expect(recorder.phase(for: target.key) == .starting)
        let completion = try #require(recorder.stop(target.key, show: false))
        #expect(recorder.phase(for: target.key) == .finishing)
        await completion.value
        #expect(recorder.phase(for: target.key) == .idle)
        let clip = try #require(recorder.latest)
        #expect(clip.target == target)
        let asset = AVURLAsset(url: clip.file)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let video = try #require(tracks.first)
        #expect(try await video.load(.naturalSize) == CGSize(width: 320, height: 240))
        #expect(try await asset.load(.duration).seconds > 0)
        #expect(BrowserRecordingClip.latest(in: directory)?.file.resolvingSymlinksInPath() == clip.file.resolvingSymlinksInPath())
    }
}
