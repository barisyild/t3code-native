import Foundation
import Testing
@testable import T3Code

struct QuestionAnswerTests {
    @Test func aRequiredQuestionCanBeAnsweredWithJustAFile() throws {
        let file = try PickedAttachment(ownedFile: AttachmentFile(data: Data("Reference".utf8), name: "reference.txt"))
        let reference = try question("reference")
        let choices = try #require(AgentQuestion(.object([
            "id": .string("choices"), "question": .string("Which options?"),
            "allowCustomAnswer": .bool(false), "multiSelect": .bool(true),
            "options": .array([
                .object(["label": .string("First"), "value": .string("a")]),
                .object(["label": .string("Second")]),
            ]),
        ])))
        let drafts: [String: QuestionAnswerDraft] = ["reference": .init(files: [file]), "choices": .init(selected: [1, 0])]
        let content = try QuestionResponseContent(questions: [reference, choices], drafts: drafts, supportsAttachments: true)
        #expect(content.answers == ["choices": .array([.string("a"), .string("Second")])])
        #expect(content.files == ["reference": [file]])
        #expect(throws: ClientError.self) {
            try QuestionResponseContent(questions: [reference, choices], drafts: drafts, supportsAttachments: false)
        }
        #expect(throws: ClientError.self) {
            try QuestionResponseContent(questions: [choices], drafts: ["choices": .init(selected: [0], files: [file])], supportsAttachments: true)
        }
    }

    @Test func fileLimitAppliesAcrossAllQuestions() throws {
        let file = try PickedAttachment(ownedFile: AttachmentFile(data: Data("File".utf8), name: "test.txt"))
        let questions = try [question("first"), question("second")]
        var drafts: [String: QuestionAnswerDraft] = [
            "first": .init(files: Array(repeating: file, count: 50)),
            "second": .init(files: Array(repeating: file, count: 50)),
        ]
        let content = try QuestionResponseContent(questions: questions, drafts: drafts, supportsAttachments: true)
        #expect(content.files.values.flatMap { $0 }.count == 100)
        drafts["second"]?.files.append(file)
        #expect(throws: ClientError.self) {
            try QuestionResponseContent(questions: questions, drafts: drafts, supportsAttachments: true)
        }
    }

    @Test func attachmentHistoryKeepsQuestionOrderAndOlderUnlabelledFiles() throws {
        func attachment(_ id: String) -> Wire {
            .object(["id": .string(id), "name": .string(id + ".txt"), "type": .string("file"),
                     "mimeType": .string("text/plain"), "sizeBytes": .int(10)])
        }
        let item = try #require(TimelineEntry(item: .object([
            "id": .string("questions"), "threadId": .string("thread"), "ordinal": .int(4),
            "type": .string("user_input_request"), "questions": .array([
                .object(["id": .string("second")]), .object(["id": .string("first")]),
            ]),
            "questionAnswer": .object(["attachmentsByQuestionId": .object([
                "first": .array([attachment("first-file")]), "second": .array([attachment("second-file")]),
                "legacy": .array([attachment("older-file")]),
            ])]),
        ])))
        #expect(item.attachments.map(\.id) == ["second-file", "first-file", "older-file"])
    }

    private func question(_ id: String) throws -> AgentQuestion {
        try #require(AgentQuestion(.object(["id": .string(id), "question": .string("Attach a reference.")])))
    }
}
