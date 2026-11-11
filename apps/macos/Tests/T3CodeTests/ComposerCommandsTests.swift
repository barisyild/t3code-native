import Foundation
import Testing
@testable import T3Code

struct ComposerCommandsTests {
    @Test func skillTriggersRespectUTF16CaretsAndIgnoreCurrencyAndPaths() throws {
        let text = "👋 use $rep next"
        let caret = "👋 use $rep".utf16.count
        let trigger = try #require(ComposerCommandTrigger.detect(text, caret: NSRange(location: caret, length: 0)))
        #expect(trigger.kind == .skill)
        #expect(trigger.query == "rep")
        let range = trigger.replacementRange(in: text, inserting: "$review ")
        #expect((text as NSString).replacingCharacters(in: range, with: "$review ") == "👋 use $review next")
        for literal in ["Pay $12", "Use /tmp/foo", "https://example.test"] {
            #expect(ComposerCommandTrigger.detect(literal, caret: NSRange(location: literal.utf16.count, length: 0)) == nil)
        }
    }

    @Test func catalogueOffersOnlyInvocableSkillsAndScopesProviderCommandsToTheStart() throws {
        let catalog = ComposerCommandCatalog(.object([
            "slashCommands": .array([.object(["name": .string("clear")]), .object(["name": .string("compact")])]),
            "skills": .array([
                .object(["name": .string("review"), "displayName": .string("Code review"), "enabled": .bool(true)]),
                .object(["name": .string("disabled"), "enabled": .bool(false)]),
                .object(["name": .string("internal"), "enabled": .bool(true), "userInvocable": .bool(false)]),
            ]),
        ]))
        let start = try #require(ComposerCommandTrigger.detect("/", caret: NSRange(location: 1, length: 0)))
        #expect(catalog.items(for: start, freshSession: true).map(\.action) == [
            .model, .freshSession, .insert("/compact "), .insert("$review "),
        ])
        let later = try #require(ComposerCommandTrigger.detect("hello /", caret: NSRange(location: 7, length: 0)))
        #expect(catalog.items(for: later, freshSession: true).map(\.action) == [.model, .insert("$review ")])
    }
}
