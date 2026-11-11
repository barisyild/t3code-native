import Foundation

enum ConversationToolOutput {
    static func successful(_ output: Wire) -> Wire? {
        var budget = ReadBudget()
        let result = read(output, depth: 0, budget: &budget)
        return budget.exceeded || result.failed ? nil : result.value
    }

    private struct ReadBudget {
        var bytes = 16_384
        var nodes = 128
        var exceeded = false
    }

    private static func read(_ output: Wire, depth: Int, budget: inout ReadBudget) -> (value: Wire?, failed: Bool) {
        guard depth <= 4, budget.nodes > 0 else { budget.exceeded = true; return (nil, false) }
        budget.nodes -= 1
        switch output {
        case .string(let text):
            budget.bytes -= text.utf8.count
            guard budget.bytes >= 0 else { budget.exceeded = true; return (nil, false) }
            guard let parsed = try? JSONDecoder().decode(Wire.self, from: Data(text.utf8)) else { return (nil, false) }
            return read(parsed, depth: depth + 1, budget: &budget)
        case .array(let blocks):
            guard blocks.count <= 32 else { budget.exceeded = true; return (nil, false) }
            var value: Wire?
            var failed = false
            for block in blocks {
                let text = block["text"]
                let part = read(text["text"] == .null ? text : text["text"], depth: depth + 1, budget: &budget)
                value = value ?? part.value
                failed = failed || part.failed
                if budget.exceeded { break }
            }
            return (value, failed)
        case .object:
            let failed = output["isError"].bool == true || output["is_error"].bool == true ||
                output["_tag"].string == "OrchestratorMcpFailure" || output["error"] != .null
            let content = output["structuredContent"] == .null ? output["content"] : output["structuredContent"]
            if content != .null {
                let result = read(content, depth: depth + 1, budget: &budget)
                return (result.value, failed || result.failed)
            }
            return (output, failed)
        default: return (nil, false)
        }
    }
}
