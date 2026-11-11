import Foundation
import SwiftTerm

struct TerminalSelection: Equatable {
    static let maximumText = 64_000

    let lineStart: Int
    let lineEnd: Int
    let text: String

    static func capture(from a: Position, to b: Position, columns: Int,
                        read: (Position, Position) -> String) -> Self? {
        guard columns > 0, a.row >= 0, b.row >= 0, a != b else { return nil }
        let (start, end) = Position.compare(a, b) == .before ? (a, b) : (b, a)
        let lastRow = end.col == 0 && end.row > start.row ? end.row - 1 : end.row
        var lines: [String] = []
        var firstLine = start.row + 1
        var length = 0
        for row in start.row...lastRow {
            let left = row == start.row ? min(columns, max(0, start.col)) : 0
            let right = row == end.row ? min(columns, max(0, end.col)) : columns
            let line = right > left ? read(Position(col: left, row: row), Position(col: right, row: row)) : ""
            if lines.isEmpty && line.isEmpty {
                firstLine += 1
                continue
            }
            let separator = lines.isEmpty ? 0 : 1
            let remaining = maximumText - length - separator
            guard remaining > 0 else { break }
            let excerpt = TerminalContext.bounded(line, to: remaining)
            lines.append(excerpt)
            length += excerpt.utf16.count + separator
            if excerpt.utf16.count < line.utf16.count { break }
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard !lines.isEmpty else { return nil }
        return Self(lineStart: firstLine, lineEnd: firstLine + lines.count - 1, text: lines.joined(separator: "\n"))
    }
}

struct TerminalContext: Equatable {
    static let maximumRecords = 200
    private static let idPattern = try! NSRegularExpression(pattern: #"\A[a-zA-Z0-9_-]{1,128}\z"#)
    private static let linkPattern = try! NSRegularExpression(
        pattern: #"\[[^\]\n]{0,512}\]\(t3-context://v1/terminal/([a-zA-Z0-9_-]{1,128})\)"#
    )
    private static let prefix = "t3-context://v1/terminal/"

    let id: String
    let terminalID: String
    let terminalLabel: String
    let label: String
    let selection: TerminalSelection

    init?(terminalID: String, terminalLabel: String, selection: TerminalSelection) {
        guard !terminalID.isEmpty, terminalID.utf16.count <= 255 else { return nil }
        id = "terminal_" + UUID().uuidString.lowercased()
        self.terminalID = terminalID
        let name = Self.bounded(terminalLabel.trimmingCharacters(in: .whitespacesAndNewlines), to: 255)
        self.terminalLabel = name.isEmpty ? "Terminal" : name
        self.selection = selection
        let range = selection.lineStart == selection.lineEnd ? "line \(selection.lineStart)" : "lines \(selection.lineStart)-\(selection.lineEnd)"
        label = Self.safeLabel("\(self.terminalLabel) \(range)")
    }

    init?(_ record: Wire) {
        guard record["version"].int == 1, record["kind"].string == "terminal",
              let id = record["contextId"].string, Self.validID(id),
              let terminalID = record["terminalId"].string, !terminalID.isEmpty, terminalID.utf16.count <= 255,
              let terminalLabel = record["terminalLabel"].string, !terminalLabel.isEmpty, terminalLabel.utf16.count <= 255,
              let label = record["label"].string, label.utf16.count <= 200,
              let lineStart = record["lineStart"].int, let lineEnd = record["lineEnd"].int,
              lineStart >= 0, lineEnd >= lineStart, lineEnd < Int.max,
              let text = record["text"].string, !text.isEmpty, text.utf16.count <= TerminalSelection.maximumText else { return nil }
        self.id = id
        self.terminalID = terminalID
        self.terminalLabel = terminalLabel
        self.label = Self.safeLabel(label)
        selection = TerminalSelection(lineStart: lineStart, lineEnd: lineEnd, text: text)
    }

    var markdown: String { "[\(label)](\(Self.prefix)\(id))" }
    var record: Wire {
        .object([
            "version": .int(1), "contextId": .string(id), "kind": .string("terminal"), "label": .string(label),
            "terminalId": .string(terminalID), "terminalLabel": .string(terminalLabel),
            "lineStart": .int(selection.lineStart), "lineEnd": .int(selection.lineEnd), "text": .string(selection.text),
        ])
    }

    static func referenceID(_ url: URL) -> String? {
        let value = url.absoluteString
        guard value.hasPrefix(prefix) else { return nil }
        let id = String(value.dropFirst(prefix.count))
        return validID(id) ? id : nil
    }

    static func references(in text: String) -> [(range: NSRange, id: String)] {
        guard text.contains(prefix) else { return [] }
        let source = text as NSString
        return linkPattern.matches(in: text, range: NSRange(location: 0, length: source.length)).map {
            ($0.range, source.substring(with: $0.range(at: 1)))
        }
    }

    static func byID(_ records: [Wire]) -> [String: Self] {
        var contexts: [String: Self] = [:]
        for context in records.compactMap(Self.init) where contexts[context.id] == nil {
            contexts[context.id] = context
        }
        return contexts
    }

    static func referencedRecords(in text: String, records: [Wire]) -> [Wire] {
        let contexts = byID(records)
        var ids: Set<String> = []
        return references(in: text).compactMap { _, id in ids.insert(id).inserted ? contexts[id]?.record : nil }
    }

    static func retaining(_ records: [Wire], in text: String) -> [Wire] {
        records.filter { $0["kind"].string != "terminal" } + referencedRecords(in: text, records: records)
    }

    static func plainText(_ text: String, records: [Wire]) -> String {
        let matches = references(in: text)
        guard !matches.isEmpty else { return text }
        let contexts = byID(records)
        let plain = NSMutableString(string: text)
        for (range, id) in matches.reversed() {
            if let context = contexts[id] { plain.replaceCharacters(in: range, with: context.label) }
        }
        return plain as String
    }

    static func bounded(_ text: String, to maximum: Int) -> String {
        var units = text.utf16.prefix(maximum)
        if let last = units.last, (0xd800...0xdbff).contains(last) { units = units.dropLast() }
        return String(decoding: units, as: UTF16.self)
    }

    private static func safeLabel(_ label: String) -> String {
        let cleaned = label.map { "[]\\".contains($0) || $0.isWhitespace ? Character(" ") : $0 }
        let text = String(cleaned).split(separator: " ").joined(separator: " ")
        return text.isEmpty ? "Terminal" : bounded(text, to: 200)
    }

    private static func validID(_ id: String) -> Bool {
        idPattern.firstMatch(in: id, range: NSRange(location: 0, length: id.utf16.count)) != nil
    }
}
