import Foundation

struct ThreadLiveActivity: Equatable, Sendable {
    let symbol: String
    let title: String
    let detail: String?

    init(symbol: String, title: String, detail: String? = nil) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
    }

    init?(entry: TimelineEntry) {
        let item = entry.value
        let status = item["status"].string
        guard status == "running" ||
                ((status == nil || status == "pending") && item["streaming"].bool == true) else { return nil }
        switch entry.type {
        case "command_execution":
            self.init(symbol: "terminal", title: "Running command", detail: Self.oneLine(item["input"].string))
        case "file_search":
            let input = Self.searchDetail(title: item["title"].string, query: item["pattern"].string)
            self.init(symbol: "magnifyingglass", title: "Searching files", detail: input)
        case "web_search":
            self.init(symbol: "globe", title: "Searching the web", detail: Self.oneLine(item["patterns"].array.first?.string))
        case "file_change":
            let path = item["changes"].array.first?["path"].string ?? item["fileName"].string
            self.init(symbol: "pencil", title: "Editing files", detail: Self.oneLine(path))
        case "dynamic_tool":
            let name = item["toolName"].string
            let input = item["input"]
            switch name?.lowercased() {
            case "grep", "glob", "ls", "rg", "find":
                let query = input["pattern"].string ?? input["query"].string ?? input["path"].string
                let detail = Self.searchDetail(title: item["title"].string, query: query)
                self.init(symbol: "magnifyingglass", title: "Searching files", detail: detail)
            case "read", "read file", "readfile", "view_image":
                let path = item["viewedImagePath"].string ?? input["file_path"].string ?? input["path"].string ?? input["filePath"].string
                self.init(symbol: "doc.text", title: "Reading file", detail: Self.oneLine(path))
            default:
                let detail = Self.oneLine(item["title"].string) ?? Self.oneLine(name)
                switch item["toolSurface"].string {
                case "browser": self.init(symbol: "globe", title: "Using the browser", detail: detail)
                case "computer": self.init(symbol: "desktopcomputer", title: "Using the computer", detail: detail)
                default: self.init(symbol: "wrench", title: "Using a tool", detail: detail)
                }
            }
        case "reasoning":
            self.init(symbol: "brain", title: "Thinking…")
        case "assistant_message":
            self.init(symbol: "text.bubble", title: "Writing a reply…")
        case "proposed_plan":
            self.init(symbol: "list.bullet", title: "Writing a plan…")
        case "compaction":
            self.init(symbol: "arrow.down.right.and.arrow.up.left", title: "Summarizing context…")
        default:
            return nil
        }
    }

    private static func searchDetail(title: String?, query: String?) -> String? {
        guard let title = oneLine(title) else { return oneLine(query) }
        let prefix = "Searched "
        return title.hasPrefix(prefix) ? String(title.dropFirst(prefix.count)) : title
    }

    private static func oneLine(_ value: String?) -> String? {
        guard let value else { return nil }
        let line = value.prefix(240).split(whereSeparator: \.isNewline).first { $0.contains { !$0.isWhitespace } }
        let text = line?.split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
        return text.isEmpty ? nil : text
    }
}
