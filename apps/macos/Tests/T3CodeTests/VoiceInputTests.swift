import AVFoundation
import Foundation
import Testing
@testable import T3Code

struct VoiceInputTests {
    @Test func convertsNativeAudioToMonoFloat32AtTheServerSampleRate() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        buffer.frameLength = buffer.frameCapacity
        let channels = try #require(buffer.floatChannelData)
        for index in 0..<Int(buffer.frameLength) {
            let sample = Float(sin(Double(index) * 2 * .pi * 440 / 48_000)) * 0.2
            channels[0][index] = sample
            channels[1][index] = sample
        }
        let data = try VoicePCMConverter(input: format).convert(buffer)
        let samples = data.withUnsafeBytes { bytes in
            Array(bytes.bindMemory(to: Float32.self))
        }
        #expect(samples.count == 1_600)
        let finite = samples.allSatisfy { $0.isFinite }
        #expect(finite)
        #expect(samples.contains { abs($0) > 0.1 })
    }

    @Test func batchTranscriptionUsesTheT3OptionsAndPCMWireFormat() throws {
        let audio = Data([0, 0, 0, 0x3F])
        let options = Wire.object(["speechLanguage": .string("tr")])
        let payload = try VoicePCM.request(audio, options: options)
        let length = payload.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
        #expect(try JSONDecoder().decode(Wire.self, from: payload.subdata(in: 4..<(4 + length))) == options)
        #expect(Data(payload.dropFirst(4 + length)) == audio)
        #expect(throws: ClientError.self) { _ = try VoicePCM.request(Data([1]), options: options) }
    }

    @Test func dictationUsesTheCapturedSelectionAndRefusesToReplaceAnEditedDraft() throws {
        let draft = "📎 Draft"
        let caret = VoiceDraftAnchor(revision: 3, range: NSRange(location: draft.utf16.count, length: 0))
        #expect(try caret.insertion(" for review ", draft: draft, revision: 3, language: "en") == " for review")
        #expect(throws: ClientError.self) { _ = try caret.insertion(" for review ", draft: draft, revision: 4, language: "en") }
        let selection = VoiceDraftAnchor(revision: 3, range: NSRange(location: 3, length: 5))
        #expect(try selection.insertion("Summary", draft: draft, revision: 3, language: "en") == "Summary")
        let cjk = VoiceDraftAnchor(revision: 3, range: NSRange(location: 1, length: 0))
        #expect(try cjk.insertion("本", draft: "日", revision: 3, language: "ja") == "本")
    }

    @Test func existingVoicePreferencesKeepTheirEnvironmentGrantAndCleanupOff() throws {
        let grant = UUID()
        let data = Data(#"{"grant":"\#(grant.uuidString)","language":"tr","translate":false,"removeFillers":true,"filterSilence":true}"#.utf8)
        let preferences = try JSONDecoder().decode(VoiceInputPreferences.self, from: data)
        #expect(preferences.grant == grant)
        #expect(preferences.cloud == nil)
        #expect(preferences.cleanupGrant == nil)
        #expect(preferences.language == "tr")
    }

    @Test func cloudDestinationRequiresAnExactOpenRouterModelAndKeepsTheCueOptIn() throws {
        #expect(VoiceCloudDestination(provider: .openrouter) == nil)
        #expect(VoiceCloudDestination(provider: .openrouter, model: "openrouter/auto") == nil)
        #expect(VoiceCloudDestination(provider: .openrouter, model: "vendor/speech:nitro") == nil)
        #expect(VoiceCloudDestination(provider: .openai, model: "vendor/speech") == nil)
        let route = try #require(VoiceCloudDestination(provider: .openrouter, model: "vendor/speech-1.2"))
        let preferences = VoiceInputPreferences(cloud: route, correctionCue: "pardon", language: "tr", translate: true)
        let ordinary = preferences.options(for: nil, vocabulary: [])
        #expect(ordinary["speechLanguage"].string == "tr")
        #expect(ordinary["speechTranslateToEnglish"].bool == false)
        #expect(ordinary["speechCorrectionWord"] == .null)
        #expect(preferences.options(for: nil, vocabulary: [], cleanup: true)["speechCorrectionWord"].string == "pardon")
        let builtIn = VoiceInputPreferences(cleanupPrompt: "Saved custom instructions", cleanupUsesCustomInstructions: false)
        #expect(builtIn.cleanupOptions(vocabulary: [])["speechPostProcessingPrompt"] == .object([
            "mode": .string("default"), "customInstructions": .string(""),
        ]))
        #expect(VoiceCloudProvider.apiKey("https://example.test/key") == nil)
        #expect(VoiceCloudProvider.apiKey(" a key ") == nil)
        #expect(VoiceCloudProvider.apiKey(" fixture-key ") == .string("fixture-key"))
    }

    @Test func cleanupContextOnlyContainsTheBoundedSelectionAndNearbyDraftText() throws {
        let draft = String(repeating: "a", count: 2_000) + String(repeating: "b", count: 2_000) + String(repeating: "c", count: 2_000)
        let anchor = VoiceDraftAnchor(revision: 1, range: NSRange(location: 2_000, length: 2_000))
        let context = try #require(anchor.cleanupContext(draft))
        let expected = ["a", "b", "c"].map { String(repeating: $0, count: 1_024) }.joined()
        #expect(context["text"].string == expected)
        #expect(context["selection"] == .object(["start": .int(1_024), "end": .int(2_048)]))
    }
}
