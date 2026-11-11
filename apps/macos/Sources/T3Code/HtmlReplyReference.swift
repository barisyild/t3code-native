import Foundation

struct HtmlReplyReference: Equatable, Sendable {
    private static let minimumHeight: CGFloat = 80
    private static let maximumHeight: CGFloat = 2_000
    private static let measureWidth: CGFloat = 728
    private static let toolPattern = try! NSRegularExpression(
        pattern: #"(?i)\A(?:html_render|mcp__(?:t3-code|t3_code|t3code|t3-code-direct|t3_code_direct)__html_render|(?:t3[-_]code[-_]direct|t3-code|t3_code|t3code)(?:[.:/]|\s*·\s*)html_render|(?:mcp[-_]{1,2})?t3[-_ ]?code(?:__|[-_.:/ ])html_render|t3-code-[^\s]+_html_render)\z"#
    )

    struct Measurement: Equatable, Sendable {
        let width: CGFloat
        let height: CGFloat
    }

    let attachmentID: String
    let title: String
    let height: CGFloat
    let heights: [Measurement]

    init?(toolItem: Wire) {
        guard toolItem["type"].string == "dynamic_tool", toolItem["status"].string == "completed",
              let name = toolItem["toolName"].string, Self.isRenderTool(name) else { return nil }
        guard let page = ConversationToolOutput.successful(toolItem["output"])?["htmlRender"],
              let id = page["attachmentId"].string, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, id.utf16.count <= 256,
              let title = page["title"].string, let height = page["height"].double, height.isFinite else { return nil }
        attachmentID = id
        let heading = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        self.title = heading.isEmpty ? "HTML" : heading
        self.height = Self.clamp(height)
        let sizes = page["heights"].array
        let measured: [Measurement] = sizes.count <= 24 ? sizes.compactMap { sample in
            let values = sample.array
            guard values.count == 2, let width = values[0].int, (1...10_000).contains(width),
                  let height = values[1].double, height.isFinite else { return nil }
            return Measurement(width: CGFloat(width), height: Self.clamp(height))
        } : []
        heights = measured.count == sizes.count ? measured.sorted { $0.width < $1.width } : []
    }

    var fileName: String {
        let forbidden = CharacterSet(charactersIn: "\\/:*?\"<>|").union(.controlCharacters)
        let clean = title.components(separatedBy: forbidden).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return AttachmentFile.safeName(String((clean.isEmpty ? "Page" : clean).prefix(120)) + ".html")
    }

    var resource: Wire {
        .object(["_tag": .string("attachment"), "attachmentId": .string(attachmentID), "fileName": .string(fileName),
                 "mimeType": .string("text/html"), "disposition": .string("inline")])
    }

    func frameHeight(width: CGFloat, zoom: CGFloat, liveHeight: CGFloat? = nil) -> CGFloat {
        if let liveHeight, liveHeight.isFinite {
            return min(20_000, max(Self.minimumHeight, ceil(liveHeight * zoom)))
        }
        let base: CGFloat
        if let measured = measuredHeight(width: width / zoom),
           let standard = measuredHeight(width: Self.measureWidth) {
            base = min(standard > height ? height : Self.maximumHeight, measured)
        } else { base = height }
        return max(Self.minimumHeight, ceil(base * zoom))
    }

    private func measuredHeight(width: CGFloat) -> CGFloat? {
        guard !heights.isEmpty else { return nil }
        let high = heights.firstIndex { $0.width >= width } ?? (heights.count - 1)
        let low = heights[high].width == width ? high : max(0, high - 1)
        return max(heights[low].height, heights[high].height)
    }

    private static func clamp(_ value: Double) -> CGFloat {
        min(maximumHeight, max(minimumHeight, CGFloat(value.rounded())))
    }

    private static func isRenderTool(_ value: String) -> Bool {
        guard value.utf16.count <= 256 else { return false }
        let name = value.replacingOccurrences(of: #"\s+completed?\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let label = name.hasPrefix("@") ? String(name.dropFirst()) : name
        return toolPattern.firstMatch(in: label, range: NSRange(location: 0, length: label.utf16.count)) != nil
    }

}
