import Foundation
import Testing
@testable import T3Code

struct AssistantCitationTests {
    @Test func roundTripsTheSharedAssistantCitationURL() throws {
        let href = "t3-citation://v1/env%2Fbox/thread%20a/reply%28x%29?text=Fix+%C3%A7%2B%2B&start=0&end=7&prefix=&suffix=&comment=Use+%28safe%29"
        let citation = try #require(AssistantCitation.parse(href))
        #expect(citation.environmentID == "env/box")
        #expect(citation.threadID == "thread a")
        #expect(citation.text == "Fix ç++")
        #expect(citation.comment == "Use (safe)")
        #expect(citation.href == href)
        #expect(AssistantCitation.plainText("See \(citation.markdown).") == "See Fix ç++\nComment: Use (safe).")
        #expect(AssistantCitation.parse(href + "&text=duplicate") == nil)
        #expect(AssistantCitation.parse(href + "#fragment") == nil)
        #expect(AssistantCitation.parse(href.replacingOccurrences(of: "end=7", with: "end=9007199254740992")) == nil)
    }

    @Test func selectorsPreserveTheQuoteAndLocateItAcrossWhitespaceChanges() throws {
        let rendered = "Before 😀\n\nKeep  this text.\nAfter"
        let selection = (rendered as NSString).range(of: "Keep  this text.")
        let citation = try #require(AssistantCitation.selection(environmentID: "env", threadID: "thread", messageID: "reply",
                                                                 rendered: rendered, range: selection))
        #expect(citation.text == "Keep  this text.")
        #expect(citation.before == "Before 😀 ")
        #expect(citation.after == " After")
        #expect(citation.end - citation.start == "Keep this text.".utf16.count)
        let changed = "New preface\nBefore 😀\tKeep this text.\nAfter"
        let revealed = try #require(citation.range(in: changed))
        #expect((changed as NSString).substring(with: revealed) == "Keep this text.")
    }

    @Test func quotesRoundTripLongProviderIdentifiersAndEncodedText() throws {
        let identifier = String(repeating: "界", count: 4_096)
        let quote = String(repeating: "字", count: AssistantCitation.maximumText)
        let selection = AssistantCitation.selection(environmentID: identifier, threadID: identifier,
                                                    messageID: identifier, rendered: quote,
                                                    range: NSRange(location: 0, length: quote.utf16.count))
        let citation = try #require(selection).replacingComment(String(repeating: "語", count: AssistantCitation.maximumComment))
        #expect(AssistantCitation.parse(citation.href) == citation)
        #expect(AssistantCitation.matches(in: citation.markdown).map(\.citation) == [citation])
    }

    @Test func repeatedTextNeedsAnUnambiguousContextEvenAtTheSavedOffset() throws {
        let lead = String(repeating: "a", count: 40) + " "
        let tail = " " + String(repeating: "b", count: 40)
        let section = lead + "Repeated" + tail
        let source = section + "\n" + section
        let citation = try #require(AssistantCitation.selection(environmentID: "env", threadID: "thread", messageID: "reply",
                                                                 rendered: source, range: (source as NSString).range(of: "Repeated")))
        #expect(citation.range(in: source) == nil)
        let unique = "New context with Repeated"
        #expect(citation.range(in: unique) == (unique as NSString).range(of: "Repeated"))
    }

    @Test func anEditedCommentDoesNotChangeSourceIdentity() throws {
        let original = try #require(AssistantCitation.selection(environmentID: "env", threadID: "thread", messageID: "reply",
                                                                 rendered: "Quote", range: NSRange(location: 0, length: 5)))
        let updated = try original.replacingComment("  Explain this.  ")
        #expect(updated.comment == "Explain this.")
        #expect(try updated.replacingComment("\n") == original)
        #expect(AssistantCitation.parse(updated.href) == updated)
        #expect(throws: ClientError.self) { _ = try original.replacingComment(String(repeating: "x", count: 8_001)) }
    }
}
