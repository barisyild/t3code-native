import Foundation
import Testing
@testable import T3Code

struct BrowserPreferencesTests {
    @Test func renamingKeepsTheProfilePartitionAndRemovingResetsTheDefault() throws {
        var settings = BrowserPreferences()
        try settings.saveProfile(name: " Staging ")
        let profile = try #require(settings.customProfiles.first)
        settings.selectDefault(profile.id)
        try settings.saveProfile(name: "Release", editing: profile.id)
        #expect(settings.defaultProfile.id == profile.id)
        #expect(settings.defaultProfile.name == "Release")
        #expect(settings.report["profiles"]?.array.map { $0["id"].string } == [profile.id])
        settings.selectDefault(BrowserProfile.incognito.id)
        #expect(settings.defaultProfile.id == profile.id)
        let bytes = try JSONEncoder().encode(settings.storedValue)
        let restored = try JSONDecoder().decode(Wire.self, from: bytes)
        #expect(BrowserPreferences(restored) == settings)
        settings.removeProfile(profile.id)
        #expect(settings.defaultProfile == .standard)
        #expect(settings.customProfiles.isEmpty)
    }

    @Test func savedCatalogsCannotReplaceBuiltInsOrCreateAnotherIncognitoPartition() throws {
        let rows = [
            BrowserProfile(id: "default", name: "Replaced", kind: .incognito),
            BrowserProfile(id: "incognito", name: "Persistent", kind: .persistent),
            BrowserProfile(id: "profile-one", name: "One", kind: .incognito),
            BrowserProfile(id: "profile-one", name: "Duplicate ID", kind: .persistent),
            BrowserProfile(id: "bad\u{0}id", name: "Broken", kind: .persistent),
        ]
        var settings = BrowserPreferences(.object(["profiles": .array(rows.map(\.wire)), "defaultProfileId": .string("incognito")]))
        #expect(settings.profiles.map(\.name) == ["Default", "Incognito", "One"])
        #expect(settings.profiles.filter { $0.kind == .incognito } == [.incognito])
        #expect(settings.defaultProfile == .standard)
        #expect(throws: ClientError.self) { try settings.saveProfile(name: "one") }
        #expect(throws: ClientError.self) { try settings.saveProfile(name: "New", editing: "default") }
        for index in 1..<BrowserPreferences.profileLimit { try settings.saveProfile(name: "Saved \(index)") }
        #expect(settings.report["profiles"]?.array.count == BrowserPreferences.profileLimit)
        #expect(throws: ClientError.self) { try settings.saveProfile(name: "Overflow") }
    }

    @Test func searchTemplatesKeepQueriesInTheConfiguredOrigin() throws {
        var settings = BrowserPreferences()
        settings.setSearchEngine(.brave)
        #expect(try BrowserAddress.resolve("swift navigation", search: settings.search) ==
            "https://search.brave.com/search?q=swift%20navigation")
        settings.setSearchEngine(.custom)
        try settings.setCustomSearch("https://search.example.test/?query=%s")
        let url = try BrowserAddress.resolve("C++ & SwiftUI", search: settings.search)
        #expect(url == "https://search.example.test/?query=C%2B%2B%20%26%20SwiftUI")
        #expect(try BrowserAddress.resolve("localhost:3000/", search: settings.search) == "http://localhost:3000/")
        for invalid in ["https://%s.example.test/", "https://%s@example.test/search", "https://example.test", "file:///tmp/%s"] {
            #expect(throws: ClientError.self) { try settings.setCustomSearch(invalid) }
        }
        #expect(try BrowserAddress.resolve("follow up", search: settings.search) ==
            "https://search.example.test/?query=follow%20up")
        try settings.setCustomSearch("")
        #expect(try BrowserAddress.resolve("follow up", search: settings.search) ==
            "https://duckduckgo.com/?q=follow%20up")
    }
}
