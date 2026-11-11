import Foundation
import JavaScriptCore

@MainActor
enum TranscriptMathRendering {
    private static let key = "transcriptMathRendering"
    static let didChange = Notification.Name("T3TranscriptMathRenderingDidChange")

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set {
            guard newValue != enabled else { return }
            UserDefaults.standard.set(newValue, forKey: key)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }
}

struct TranscriptFormula: Equatable, Sendable {
    let range: NSRange
    let source: String
    let tex: String
    let display: Bool
}

@MainActor
final class TranscriptMathParser {
    static let shared = TranscriptMathParser()

    private final class Cached {
        let formulas: [TranscriptFormula]
        init(_ formulas: [TranscriptFormula]) { self.formulas = formulas }
    }

    private let asset: URL?
    private let worker: TranscriptMathWorker
    private let cache = NSCache<NSString, Cached>()
    private var pending: [String: Task<[TranscriptFormula], Never>] = [:]

    init(asset: URL? = Bundle.main.url(forResource: "math-parser", withExtension: "js", subdirectory: "TranscriptRenderer")) {
        self.asset = asset
        worker = TranscriptMathWorker(asset: asset)
        cache.countLimit = 80
        cache.totalCostLimit = 6 * 1024 * 1024
    }

    func accepts(_ source: String) -> Bool {
        asset != nil && (source.contains("$") || source.contains("\\(") || source.contains("\\[")) && source.utf16.count <= 240_000
    }

    func cachedFormulas(in source: String) -> [TranscriptFormula]? {
        cache.object(forKey: source as NSString)?.formulas
    }

    func prepare(_ source: String) async -> [TranscriptFormula] {
        guard accepts(source) else { return [] }
        if let cached = cachedFormulas(in: source) { return cached }
        if let existing = pending[source] { return await existing.value }
        let task = Task { [weak self, worker] in
            let formulas = await worker.parse(source)
            let key = source as NSString
            self?.cache.setObject(Cached(formulas), forKey: key, cost: key.length * 4)
            self?.pending.removeValue(forKey: source)
            return formulas
        }
        pending[source] = task
        return await task.value
    }
}

private actor TranscriptMathWorker {
    private let asset: URL?
    private lazy var evaluator: (context: JSContext, parse: JSValue)? = load()

    init(asset: URL?) { self.asset = asset }

    func parse(_ source: String) -> [TranscriptFormula] {
        let key = source as NSString
        guard let evaluator else { return [] }
        evaluator.context.exception = nil
        guard let entries = evaluator.parse.call(withArguments: [source])?.toArray() as? [[String: Any]],
              evaluator.context.exception == nil else { return [] }
        var formulas: [TranscriptFormula] = []
        var endOfPrevious = 0
        for entry in entries {
            guard let start = entry["start"] as? Int, let end = entry["end"] as? Int,
                  start >= endOfPrevious, end > start, end <= key.length,
                  let authored = entry["source"] as? String, let tex = entry["tex"] as? String, !tex.isEmpty,
                  let display = entry["display"] as? Bool else { continue }
            let range = NSRange(location: start, length: end - start)
            guard key.substring(with: range) == authored else { continue }
            let opening = authored.drop(while: { $0 == " " || $0 == "\t" })
            guard opening.hasPrefix("$") || opening.hasPrefix("\\(") || opening.hasPrefix("\\[") else { continue }
            formulas.append(TranscriptFormula(range: range, source: authored, tex: tex, display: display))
            endOfPrevious = end
        }
        return formulas
    }

    private func load() -> (JSContext, JSValue)? {
        guard let asset, let script = try? String(contentsOf: asset, encoding: .utf8), let context = JSContext() else { return nil }
        context.evaluateScript(script, withSourceURL: asset)
        guard context.exception == nil,
              let parser = context.objectForKeyedSubscript("T3MarkdownMath"),
              let parse = parser.objectForKeyedSubscript("markdownMathRanges"), parse.isObject else { return nil }
        return (context, parse)
    }
}

struct TranscriptMathMarkup {
    enum Part {
        case text(String)
        case formula(TranscriptFormula)
    }

    let markdown: String
    private let prefix: String?
    private let marker: NSRegularExpression?
    private let formulas: [TranscriptFormula]

    var hasFormulas: Bool { !formulas.isEmpty }

    init(source: String, formulas: [TranscriptFormula]) {
        self.formulas = formulas
        guard !formulas.isEmpty else {
            markdown = source
            prefix = nil
            marker = nil
            return
        }
        let prefix = "T3Formula" + UUID().uuidString.replacingOccurrences(of: "-", with: "") + "F"
        self.prefix = prefix
        marker = try? NSRegularExpression(pattern: prefix + #"([0-9]+)Z"#)
        let prepared = NSMutableString(string: source)
        for index in formulas.indices.reversed() {
            prepared.replaceCharacters(in: formulas[index].range, with: "\(prefix)\(index)Z")
        }
        markdown = prepared as String
    }

    func parts(in text: String) -> [Part] {
        guard let prefix, text.contains(prefix), let marker else { return [.text(text)] }
        let content = text as NSString
        let matches = marker.matches(in: text, range: NSRange(location: 0, length: content.length))
        var result: [Part] = []
        var cursor = 0
        for match in matches {
            guard let index = Int(content.substring(with: match.range(at: 1))), formulas.indices.contains(index) else { continue }
            if match.range.location > cursor {
                result.append(.text(content.substring(with: NSRange(location: cursor, length: match.range.location - cursor))))
            }
            result.append(.formula(formulas[index]))
            cursor = NSMaxRange(match.range)
        }
        if cursor < content.length { result.append(.text(content.substring(from: cursor))) }
        return result
    }
}
