import Foundation

struct AssistantCitation: Equatable, Sendable {
    static let prefix = "t3-citation://v1/"
    static let maximumText = 8_000
    static let maximumComment = 8_000
    private static let maximumHref = 160_000
    private static let maximumOffset = 9_007_199_254_740_991
    private static let contextLength = 32
    private static let pathCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
    private static let queryCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789*-._")
    private static let link = try! NSRegularExpression(pattern: #"\[Assistant quote\]\((t3-citation://v1/[^\s)]{1,159983})\)"#)

    let environmentID: String
    let threadID: String
    let messageID: String
    let text: String
    let comment: String?
    let start: Int
    let end: Int
    let before: String
    let after: String

    private init?(environmentID: String, threadID: String, messageID: String, text: String, comment: String?,
                  start: Int, end: Int, before: String, after: String) {
        guard [environmentID, threadID, messageID].allSatisfy(Self.validID),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf16.count <= Self.maximumText,
              (comment?.utf16.count ?? 0) <= Self.maximumComment, start >= 0, end > start, end <= Self.maximumOffset,
              before.utf16.count <= Self.contextLength, after.utf16.count <= Self.contextLength else { return nil }
        self.environmentID = environmentID
        self.threadID = threadID
        self.messageID = messageID
        self.text = text
        self.comment = comment
        self.start = start
        self.end = end
        self.before = before
        self.after = after
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf16.count <= 512 && value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
            value != "." && value != ".."
    }

    static func selection(environmentID: String, threadID: String, messageID: String, rendered: String, range: NSRange) -> Self? {
        let source = rendered as NSString
        guard range.location >= 0, range.location <= source.length, range.length > 0, range.length <= maximumText,
              range.length <= source.length - range.location else { return nil }
        let quote = source.substring(with: range)
        let normalized = NormalizedCitationText(rendered)
        let start = normalized.offset(for: range.location, end: false)
        let end = normalized.offset(for: NSMaxRange(range), end: true)
        let before = Self.boundedSuffix(normalized.text.substring(to: start), length: contextLength)
        let after = Self.boundedPrefix(normalized.text.substring(from: end), length: contextLength)
        return Self(environmentID: environmentID, threadID: threadID, messageID: messageID, text: quote, comment: nil,
                    start: start, end: end, before: before, after: after)
    }

    func replacingComment(_ value: String) throws -> Self {
        let comment = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let next = Self(environmentID: environmentID, threadID: threadID, messageID: messageID, text: text,
                              comment: comment.isEmpty ? nil : comment, start: start, end: end, before: before, after: after) else {
            throw ClientError.message("Use up to 8,000 characters for a quote comment.")
        }
        return next
    }

    var label: String {
        let note = comment?.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = (note?.isEmpty == false ? note ?? text : text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if preview.utf16.count <= 64 { return preview }
        return Self.boundedPrefix(preview, length: 64) + "…"
    }

    var href: String {
        let path = [environmentID, threadID, messageID].map { $0.addingPercentEncoding(withAllowedCharacters: Self.pathCharacters) ?? "" }.joined(separator: "/")
        var query = [("text", text), ("start", String(start)), ("end", String(end)), ("prefix", before), ("suffix", after)]
        if let comment { query.append(("comment", comment)) }
        return Self.prefix + path + "?" + query.map { key, value in
            let encoded = value.addingPercentEncoding(withAllowedCharacters: Self.queryCharacters) ?? ""
            return key + "=" + encoded.replacingOccurrences(of: "%20", with: "+")
        }.joined(separator: "&")
    }

    var markdown: String { "[Assistant quote](\(href))" }

    static func parse(_ href: String) -> Self? {
        guard href.hasPrefix(prefix), href.utf16.count <= maximumHref, !href.contains("#"),
              !href.contains(where: { $0.isWhitespace }) else { return nil }
        let parts = href.dropFirst(prefix.count).split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let path = parts[0].split(separator: "/", omittingEmptySubsequences: false)
        guard path.count == 3, let environment = path[0].removingPercentEncoding,
              let thread = path[1].removingPercentEncoding, let message = path[2].removingPercentEncoding else { return nil }
        let entries = parts[1].split(separator: "&", omittingEmptySubsequences: false)
        guard (5...6).contains(entries.count) else { return nil }
        var query: [String: String] = [:]
        for entry in entries {
            let pair = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, let key = pair[0].removingPercentEncoding, query[key] == nil,
                  ["text", "start", "end", "prefix", "suffix", "comment"].contains(key),
                  let value = pair[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding else { return nil }
            query[key] = value
        }
        guard let text = query["text"], let start = offset(query["start"]), let end = offset(query["end"]),
              let before = query["prefix"], let after = query["suffix"] else { return nil }
        return Self(environmentID: environment, threadID: thread, messageID: message, text: text, comment: query["comment"],
                    start: start, end: end, before: before, after: after)
    }

    private static func offset(_ value: String?) -> Int? {
        guard let value, (1...16).contains(value.utf8.count), value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int(value)
    }

    static func matches(in text: String) -> [(range: NSRange, citation: Self)] {
        guard text.contains(prefix) else { return [] }
        let source = text as NSString
        return link.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap { match in
            parse(source.substring(with: match.range(at: 1))).map { (match.range, $0) }
        }
    }

    static func plainText(_ text: String) -> String {
        let matches = matches(in: text)
        guard !matches.isEmpty else { return text }
        let result = NSMutableString(string: text)
        for (range, citation) in matches.reversed() {
            let value = citation.comment.map { "\(citation.text)\nComment: \($0)" } ?? citation.text
            result.replaceCharacters(in: range, with: value)
        }
        return result as String
    }

    func range(in rendered: String) -> NSRange? {
        let source = NormalizedCitationText(rendered)
        let needle = NormalizedCitationText(text).text as String
        let prefix = NormalizedCitationText(before).text
        let suffix = NormalizedCitationText(after).text
        var contextMatch: NSRange?
        var soleMatch: NSRange?
        var occurrences = 0
        var location = 0
        while location < source.text.length {
            let found = source.text.range(of: needle, options: .literal, range: NSRange(location: location, length: source.text.length - location))
            guard found.location != NSNotFound else { break }
            occurrences += 1
            soleMatch = found
            let end = NSMaxRange(found)
            if found.location >= prefix.length, end + suffix.length <= source.text.length,
               source.text.substring(with: NSRange(location: found.location - prefix.length, length: prefix.length)) == prefix as String,
               source.text.substring(with: NSRange(location: end, length: suffix.length)) == suffix as String {
                if contextMatch != nil { return nil }
                contextMatch = found
            }
            location = found.location + 1
        }
        return (contextMatch ?? (occurrences == 1 ? soleMatch : nil)).map(source.rawRange)
    }

    private static func boundedPrefix(_ value: String, length: Int) -> String {
        var units = value.utf16.prefix(length)
        if let last = units.last, (0xd800...0xdbff).contains(last) { units = units.dropLast() }
        return String(decoding: units, as: UTF16.self)
    }

    private static func boundedSuffix(_ value: String, length: Int) -> String {
        var units = value.utf16.suffix(length)
        if let first = units.first, (0xdc00...0xdfff).contains(first) { units = units.dropFirst() }
        return String(decoding: units, as: UTF16.self)
    }
}

private struct NormalizedCitationText {
    let text: NSString
    private let boundaries: [Int]

    init(_ raw: String) {
        var units: [UInt16] = []
        var boundaries = [0]
        var position = 0
        var inWhitespace = false
        for scalar in raw.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar.value == 0xfeff {
                position += 1
                if inWhitespace { boundaries[boundaries.count - 1] = position }
                else { units.append(32); boundaries.append(position) }
                inWhitespace = true
            } else {
                for unit in scalar.utf16 {
                    position += 1
                    units.append(unit)
                    boundaries.append(position)
                }
                inWhitespace = false
            }
        }
        text = String(decoding: units, as: UTF16.self) as NSString
        self.boundaries = boundaries
    }

    func offset(for raw: Int, end: Bool) -> Int {
        var low = 0
        var high = boundaries.count - 1
        while low < high {
            let middle = (low + high) / 2
            if boundaries[middle] < raw { low = middle + 1 }
            else { high = middle }
        }
        return end || boundaries[low] == raw ? low : max(0, low - 1)
    }

    func rawRange(_ range: NSRange) -> NSRange {
        let first = boundaries[range.location]
        return NSRange(location: first, length: boundaries[NSMaxRange(range)] - first)
    }
}
