import AppKit

@MainActor
enum TerminalContextClipboard {
    struct Source {
        let environmentID: String
        var threadID: String?
        var messageID: String?

        var wire: Wire {
            var fields: Payload = ["environmentId": .string(environmentID)]
            if let threadID { fields["threadId"] = .string(threadID) }
            if let messageID { fields["messageId"] = .string(messageID) }
            return .object(fields)
        }
    }

    static let fragment = NSPasteboard.PasteboardType("web application/x-t3-context-fragment+json")
    private static let maximumFragment = 16_000_000
    private static let htmlAttribute = try! NSRegularExpression(pattern: #"data-t3-context-fragment=(?:"([^"]+)"|'([^']+)')"#)
    private static let uriComponent = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")

    static func contexts(in content: NSAttributedString) -> [TerminalContext] {
        var result: [TerminalContext] = []
        var ids: Set<String> = []
        content.enumerateAttribute(.attachment, in: NSRange(location: 0, length: content.length)) { value, _, _ in
            if let context = (value as? TerminalContextAttachment)?.context, ids.insert(context.id).inserted {
                result.append(context)
            }
        }
        return result
    }

    static func read(from pasteboard: NSPasteboard, text: String) -> [Wire] {
        guard !TerminalContext.references(in: text).isEmpty else { return [] }
        let value = decode(pasteboard.string(forType: fragment)) ?? decode(htmlFragment(pasteboard.string(forType: .html)))
        return TerminalContext.referencedRecords(in: text, records: value ?? [])
    }

    static func write(text: String, contexts: [TerminalContext], source: Source?, to pasteboard: NSPasteboard,
                      type: NSPasteboard.PasteboardType) -> Bool {
        if type == .string { return pasteboard.setString(text, forType: .string) }
        guard let source, !contexts.isEmpty else { return false }
        let records = TerminalContext.referencedRecords(in: text, records: contexts.map(\.record))
        guard !records.isEmpty, records.count <= TerminalContext.maximumRecords else { return false }
        let payload: Wire = .object(["version": .int(1), "source": source.wire, "records": .array(records)])
        guard let data = try? JSONEncoder().encode(payload), let raw = String(data: data, encoding: .utf8),
              raw.utf16.count <= maximumFragment else { return false }
        if type == fragment { return pasteboard.setString(raw, forType: fragment) }
        guard type == .html, let attribute = raw.addingPercentEncoding(withAllowedCharacters: uriComponent) else { return false }
        let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return pasteboard.setString("<pre data-t3-context-fragment=\"\(attribute)\">\(escaped)</pre>", forType: .html)
    }

    private static func decode(_ raw: String?) -> [Wire]? {
        guard let raw, raw.utf16.count <= maximumFragment,
              let payload = try? JSONDecoder().decode(Wire.self, from: Data(raw.utf8)), payload["version"].int == 1,
              let environment = payload["source"]["environmentId"].string, !environment.isEmpty,
              case .array(let records) = payload["records"], records.count <= TerminalContext.maximumRecords else { return nil }
        return records
    }

    private static func htmlFragment(_ html: String?) -> String? {
        guard let html, html.utf16.count <= maximumFragment * 9 + 4096,
              let match = htmlAttribute.firstMatch(in: html, range: NSRange(location: 0, length: html.utf16.count)) else { return nil }
        let range = match.range(at: 1).location == NSNotFound ? match.range(at: 2) : match.range(at: 1)
        return (html as NSString).substring(with: range).removingPercentEncoding
    }
}
