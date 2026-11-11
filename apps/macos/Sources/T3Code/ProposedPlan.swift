import Foundation

struct ProposedPlan: Equatable {
    struct SaveTarget: Equatable {
        let connection: UUID
        let threadID: String
        let root: String
    }

    enum Action: String, CaseIterable {
        case copy, download, saveToWorkspace

        var title: String {
            switch self {
            case .copy: "Copy to Clipboard"
            case .download: "Save Markdown As…"
            case .saveToWorkspace: "Save to Workspace…"
            }
        }
    }

    let markdown: String
    let title: String
    let displayMarkdown: String
    let previewMarkdown: String
    let canCollapse: Bool
    let filename: String
    let exportContents: String

    init(markdown: String) {
        self.markdown = markdown
        let heading = Self.heading(in: markdown, multiline: true)
        title = heading ?? "Proposed plan"
        canCollapse = markdown.utf16.count > 900 || markdown.components(separatedBy: "\n").count > 20
        exportContents = Self.trimEnd(markdown) + "\n"
        var lines = Self.trimEnd(markdown).replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if let first = lines.first, Self.heading(in: first) != nil { lines.removeFirst() }
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        if let first = lines.first, Self.heading(in: first)?.lowercased() == "summary" {
            lines.removeFirst()
            while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        }
        displayMarkdown = lines.joined(separator: "\n")
        var preview: [String] = []
        var visibleLines = 0
        for line in lines {
            let text = Self.trimEnd(line)
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                if visibleLines == 10 {
                    while preview.last?.isEmpty == true { preview.removeLast() }
                    preview.append(contentsOf: ["", "..."])
                    break
                }
                visibleLines += 1
            }
            preview.append(text)
        }
        while preview.last?.isEmpty == true { preview.removeLast() }
        previewMarkdown = preview.isEmpty ? heading ?? "Plan preview unavailable." : preview.joined(separator: "\n")
        let segment = (heading ?? "plan").lowercased()
            .replacingOccurrences(of: "[`'\".,!?()\\[\\]{}]+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        filename = (segment.isEmpty ? "plan" : segment) + ".md"
    }

    func body(expanded: Bool, finding: Bool) -> String {
        if finding { return displayMarkdown }
        return canCollapse && !expanded ? previewMarkdown : displayMarkdown
    }

    private static func heading(in text: String, multiline: Bool = false) -> String? {
        let pattern = (multiline ? "(?m)" : "") + "^\\s{0,3}#{1,6}\\s+(.+)$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let title = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private static func trimEnd(_ text: String) -> String {
        guard let last = text.lastIndex(where: { !$0.isWhitespace }) else { return "" }
        return String(text[...last])
    }
}

extension Workspace {
    func planSaveTarget(for threadID: String?) -> ProposedPlan.SaveTarget? {
        guard can("filesystem:write"), let connection = connectionID, let threadID,
              presentedDetail(for: threadID) != nil,
              let thread = data.threads[threadID] ?? data.archived[threadID], let root = checkoutPath(thread) else { return nil }
        return .init(connection: connection, threadID: threadID, root: root)
    }

    func savePlan(_ plan: ProposedPlan, relativePath: String, target: ProposedPlan.SaveTarget) async throws -> String {
        guard planSaveTarget(for: target.threadID) == target else { throw ClientError.disconnected }
        let result = try await request("projects.writeFile", [
            "cwd": .string(target.root), "relativePath": .string(relativePath), "contents": .string(plan.exportContents),
        ])
        guard planSaveTarget(for: target.threadID) == target else { throw ClientError.disconnected }
        return try result.requireString("relativePath")
    }
}
