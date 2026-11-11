import Foundation

struct AgentQuestion {
    struct Option {
        let label: String
        let value: String
        let detail: String?
    }

    let id: String
    let title: String
    let text: String
    let options: [Option]
    let multiple: Bool
    let custom: Bool
    let required: Bool
    let initialAnswer: String?

    init?(_ value: Wire) {
        guard let id = value["id"].string, let text = value["question"].string else { return nil }
        self.id = id
        self.text = text
        title = value["header"].string ?? "Agent question"
        options = value["options"].array.compactMap { option in
            guard let label = option["label"].string else { return nil }
            return Option(label: label, value: option["value"].string ?? label, detail: option["description"].string)
        }
        multiple = value["multiSelect"].bool == true
        custom = value["allowCustomAnswer"].bool != false
        required = value["required"].bool != false
        initialAnswer = value["initialAnswer"].string
    }

    var initialDraft: QuestionAnswerDraft {
        if let initialAnswer, let index = options.firstIndex(where: { $0.value == initialAnswer || $0.label == initialAnswer }) {
            return .init(selected: [index])
        }
        if !custom, !multiple, !options.isEmpty { return .init(selected: [0]) }
        return .init(text: custom ? initialAnswer ?? "" : "")
    }
}

struct QuestionAnswerDraft {
    var text = ""
    var selected: Set<Int> = []
    var files: [PickedAttachment] = []

    func answer(for question: AgentQuestion) -> Wire? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if question.custom, !text.isEmpty { return .string(text) }
        let values = question.options.enumerated().compactMap { selected.contains($0.offset) ? $0.element.value : nil }
        guard !values.isEmpty else { return nil }
        return question.multiple ? .array(values.map(Wire.string)) : values.first.map(Wire.string)
    }
}

struct QuestionResponseContent: Equatable {
    let answers: Payload
    let files: [String: [PickedAttachment]]

    init(questions: [AgentQuestion], drafts: [String: QuestionAnswerDraft], supportsAttachments: Bool) throws {
        var answers: Payload = [:]
        var files: [String: [PickedAttachment]] = [:]
        for question in questions {
            let draft = drafts[question.id] ?? question.initialDraft
            let answer = draft.answer(for: question)
            if !draft.files.isEmpty {
                guard supportsAttachments, question.custom else {
                    throw ClientError.message("This question does not accept attachments.")
                }
                files[question.id] = draft.files
            }
            if question.required, answer == nil, draft.files.isEmpty {
                throw ClientError.message("Answer \(question.title) before sending.")
            }
            answers[question.id] = answer
        }
        try PickedAttachment.validate(files.values.flatMap { $0 })
        self.answers = answers
        self.files = files
    }
}
