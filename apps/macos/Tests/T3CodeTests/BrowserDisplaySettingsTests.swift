import Foundation
import Testing
@testable import T3Code

struct BrowserDisplaySettingsTests {
    @Test func deviceRotationKeepsThePresetAndUsesItsNewDimensions() throws {
        let phone = try #require(BrowserViewportPreset.all.first { $0.id == "iphone-12-pro" })
        let landscape = try #require(phone.setting.rotated)
        #expect(landscape.wire == .object([
            "_tag": .string("preset"), "presetId": .string("iphone-12-pro"),
            "width": .int(844), "height": .int(390),
        ]))
        #expect(BrowserViewportSetting(landscape.wire).rotated == phone.setting)
        let legacy = BrowserViewportSetting(.object([
            "_tag": .string("preset"), "presetId": .string("desktop-1440x900"),
            "width": .int(1_440), "height": .int(900),
        ]))
        #expect(legacy.presetID == "desktop-1440x900")
    }

    @Test func dimensionsRespectBothSidesAndTheMaximumArea() throws {
        #expect(BrowserViewportSize(width: 239, height: 480) == nil)
        #expect(BrowserViewportSize(width: 3_840, height: 2_161) == nil)
        let largest = try #require(BrowserViewportSize(width: 3_840, height: 2_160))
        #expect(largest.rotated.width == 2_160 && largest.rotated.height == 3_840)
        let futurePreset = BrowserViewportSetting(.object([
            "_tag": .string("preset"), "presetId": .string("future-device"),
            "width": .int(420), "height": .int(940),
        ]))
        #expect(futurePreset.wire == .object(["_tag": .string("freeform"), "width": .int(420), "height": .int(940)]))
    }

    @Test func oldPreferencesOpenOrdinaryTabsAndNewDisplayDefaultsRoundTrip() throws {
        let old = BrowserPreferences(.object(["defaultProfileId": .string("default")]))
        #expect(old.display.viewport == .fill)
        #expect(old.display.zoom == .actualSize)
        #expect(old.display.appearance == .system)
        #expect(old.display.newTabAdjustments.isEmpty)

        var settings = old
        settings.display.viewport = .fixed(try #require(BrowserViewportSize(width: 720, height: 480)), presetID: nil)
        settings.display.zoom = try #require(BrowserZoom(1.25))
        settings.display.appearance = .dark
        let data = try JSONEncoder().encode(settings.storedValue)
        let restored = try JSONDecoder().decode(Wire.self, from: data)
        #expect(BrowserPreferences(restored) == settings)
        #expect(settings.report == old.report)
        #expect(settings.display.newTabAdjustments == ["zoomFactor": .double(1.25), "colorScheme": .string("dark")])
    }

    @Test func zoomStepsUseTheServerLevelsAndStopAtTheirBounds() throws {
        let smaller = try #require(BrowserZoom(0.9))
        #expect(BrowserZoom.actualSize.step(.decrease) == smaller)
        #expect(smaller.step(.increase) == .actualSize)
        #expect(smaller.step(.actualSize) == .actualSize)
        #expect(BrowserZoom.actualSize.step(.actualSize) == nil)
        #expect(BrowserZoom(1.23) == nil)
        #expect(BrowserZoom(0.25)?.step(.decrease) == nil)
        #expect(BrowserZoom(5)?.step(.increase) == nil)
    }
}
