import AppKit

struct ThreadFindScope: Equatable {
    let threadID: String
    let connection: UUID
    let progressive: Bool
}

struct ThreadFindMatch: Equatable {
    let entryID: String
    let occurrence: Int

    var anchor: Wire { .object(["entryId": .string(entryID), "occurrence": .int(occurrence)]) }
}

struct ThreadFindResult {
    private struct Span {
        let entryID: String
        let first: Int
        let count: Int
    }

    let count: Int
    let index: Int
    let match: ThreadFindMatch?
    let complete: Bool
    private let spans: [Span]

    init(_ value: Wire) throws {
        guard let count = value["totalMatches"].int, count >= 0,
              let index = value["activeIndex"].int, index >= 0, index < max(1, count) else {
            throw ClientError.invalidResponse
        }
        self.count = count
        self.index = index
        complete = value["complete"].bool != false
        if let id = value["match"]["entryId"].string, let occurrence = value["match"]["occurrence"].int, occurrence >= 0 {
            match = ThreadFindMatch(entryID: id, occurrence: occurrence)
        } else { match = nil }
        if (count > 0) != (match != nil) { throw ClientError.invalidResponse }
        spans = value["navigation"].array.compactMap { row in
            guard let id = row["entryId"].string, let first = row["startIndex"].int,
                  let count = row["count"].int, first >= 0, count > 0 else { return nil }
            return Span(entryID: id, first: first, count: count)
        }
    }

    private init(count: Int, index: Int, match: ThreadFindMatch, spans: [Span]) {
        self.count = count
        self.index = index
        self.match = match
        self.spans = spans
        complete = true
    }

    func stepping(_ direction: Int) -> Self? {
        guard complete, count > 0 else { return nil }
        let next = direction < 0 ? (index > 0 ? index - 1 : count - 1) : (index + 1 == count ? 0 : index + 1)
        guard let span = spans.first(where: { $0.first <= next && next - $0.first < $0.count }) else { return nil }
        return Self(count: count, index: next, match: .init(entryID: span.entryID, occurrence: next - span.first), spans: spans)
    }
}

enum ThreadFindText {
    static func ranges(of query: String, in text: String) -> [NSRange] {
        let query = fold(query)
        guard !query.isEmpty else { return [] }
        let source = fold(text) as NSString
        var result: [NSRange] = []
        var start = 0
        while start < source.length {
            let match = source.range(of: query, options: .literal, range: NSRange(location: start, length: source.length - start))
            if match.location == NSNotFound { break }
            result.append(match)
            start = NSMaxRange(match)
        }
        return result
    }

    private static func fold(_ value: String) -> String {
        let lowered = value.lowercased()
        // Keep UTF-16 offsets identical to the original attributed text.
        let stable = lowered.utf16.count == value.utf16.count ? lowered : value.unicodeScalars.map { scalar in
            let original = String(scalar)
            let folded = original.lowercased()
            return original.utf16.count == folded.utf16.count ? folded : original
        }.joined()
        return stable.replacingOccurrences(of: "ς", with: "σ")
            .replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
    }
}

@MainActor
final class ThreadFindBar: NSView, NSSearchFieldDelegate {
    private let workspace: Workspace
    private let field = NSSearchField()
    private let count = label(size: 11, color: WorkspaceStyle.muted)
    private lazy var previous = control("Previous Match", "chevron.up") { [weak self] in self?.step(-1) }
    private lazy var next = control("Next Match", "chevron.down") { [weak self] in self?.step(1) }
    private lazy var close = control("Close Find", "xmark") { [weak self] in self?.dismiss() }
    private lazy var retry = control("Retry Search", "arrow.clockwise") { [weak self] in self?.search(start: self?.result?.match) }
    private var scope: ThreadFindScope?
    private var sequence = -1
    private var result: ThreadFindResult?
    private var shownMatch: ThreadFindMatch?
    private var errorMessage: String?
    private var searchTask: Task<Void, Never>?
    private var revealTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private weak var priorResponder: NSView?
    var onReveal: (@MainActor (ThreadFindMatch, String) async throws -> Bool)?
    var onClear: (() -> Void)?

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(frame: .zero)
        let surface = Surface(WorkspaceStyle.navigation, border: WorkspaceStyle.outline, radius: 10)
        field.placeholderString = "Find in thread"
        field.setAccessibilityLabel("Find in Thread")
        field.sendsSearchStringImmediately = true
        field.delegate = self
        field.controlSize = .small
        field.font = .systemFont(ofSize: 12)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        fill(row([field, count, retry, previous, next, close], spacing: 4), in: surface, inset: 5)
        addSubview(surface)
        surface.translatesAutoresizingMaskIntoConstraints = false
        let width = surface.widthAnchor.constraint(equalToConstant: 380)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            width,
            surface.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isHidden = true
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var query: String {
        SearchText.messageQuery(field.stringValue)
    }

    var canNavigate: Bool { !isHidden && searchTask == nil && result?.complete == true && (result?.count ?? 0) > 0 }

    func sync(scope: ThreadFindScope?, sequence: Int) {
        if self.scope != scope {
            dismiss(restoreFocus: false)
            self.scope = scope
            field.stringValue = ""
        }
        guard self.sequence != sequence else { return }
        self.sequence = sequence
        refreshWhenIdle()
    }

    func open(searching text: String? = nil, at match: ThreadFindMatch? = nil) {
        guard scope != nil else { return }
        if isHidden {
            priorResponder = window?.firstResponder as? NSView
            isHidden = false
            if text == nil { search() }
        }
        if let text {
            field.stringValue = text
            result = nil
            shownMatch = match
            search(start: match)
        }
        field.selectText(nil)
    }

    func dismiss(restoreFocus: Bool = true) {
        let wasOpen = !isHidden
        isHidden = true
        searchTask?.cancel()
        revealTask?.cancel()
        refreshTask?.cancel()
        searchTask = nil
        revealTask = nil
        refreshTask = nil
        result = nil
        shownMatch = nil
        errorMessage = nil
        if wasOpen { onClear?() }
        if restoreFocus, let priorResponder, priorResponder.window === window {
            window?.makeFirstResponder(priorResponder)
        }
        priorResponder = nil
    }

    func step(_ direction: Int) {
        guard canNavigate, let result else { return }
        errorMessage = nil
        if refreshTask == nil, let next = result.stepping(direction) {
            apply(next, query: query)
        } else {
            search(start: result.match, offset: direction)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        revealTask?.cancel()
        revealTask = nil
        result = nil
        shownMatch = nil
        onClear?()
        search(delay: .milliseconds(240))
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        if command == #selector(NSResponder.cancelOperation(_:)) { dismiss(); return true }
        guard command == #selector(NSResponder.insertNewline(_:)) ||
                command == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) else { return false }
        if canNavigate { step(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1) }
        else if errorMessage != nil { search(start: result?.match) }
        return true
    }

    private func search(start: ThreadFindMatch? = nil, offset: Int = 0, delay: Duration? = nil) {
        searchTask?.cancel()
        refreshTask?.cancel()
        searchTask = nil
        refreshTask = nil
        errorMessage = nil
        let query = query
        guard !isHidden, let scope, !query.isEmpty else { render(); return }
        let requestSequence = sequence
        var payload: Payload = ["threadId": .string(scope.threadID), "query": .string(query)]
        if let start { payload["start"] = start.anchor }
        if offset != 0 { payload["offset"] = .int(offset) }
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let delay { try await Task.sleep(for: delay) }
                try Task.checkCancellation()
                if scope.progressive {
                    var receivedResult = false
                    try await workspace.subscribe("orchestration.searchThreadStream", payload) { frames in
                        guard self.scope == scope, self.query == query else { return }
                        for frame in frames {
                            if let result = try? ThreadFindResult(frame) {
                                self.apply(result, query: query)
                                receivedResult = result.complete
                            }
                        }
                    }
                    if !receivedResult { throw ClientError.invalidResponse }
                } else {
                    let response = try await workspace.request("orchestration.searchThread", payload)
                    try Task.checkCancellation()
                    guard self.scope == scope, self.query == query else { return }
                    apply(try ThreadFindResult(response), query: query)
                }
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            guard !Task.isCancelled, self.scope == scope else { return }
            searchTask = nil
            render()
            if requestSequence != sequence { refreshWhenIdle() }
        }
        render()
    }

    private func refreshWhenIdle() {
        guard !isHidden, !query.isEmpty, errorMessage == nil, searchTask == nil, refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard let self else { return }
            refreshTask = nil
            search(start: result?.match)
        }
    }

    private func apply(_ result: ThreadFindResult, query: String) {
        self.result = result
        render()
        if shownMatch == result.match && revealTask != nil { return }
        revealTask?.cancel()
        revealTask = nil
        guard let match = result.match else {
            shownMatch = nil
            onClear?()
            return
        }
        let needsReveal = shownMatch != match
        shownMatch = match
        guard needsReveal, let onReveal else { return }
        revealTask = Task { [weak self] in
            guard let self else { return }
            do {
                if try await !onReveal(match, query) { throw ClientError.message("The matching message could not be loaded.") }
            } catch {
                guard !Task.isCancelled else { return }
                shownMatch = nil
                onClear?()
                errorMessage = error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            revealTask = nil
            render()
        }
    }

    private func render() {
        if errorMessage != nil { count.stringValue = "Search failed" }
        else if let result {
            count.stringValue = !result.complete ? "1 of …" : result.count == 0 ? "No matches" : "\(result.index + 1) of \(result.count)"
        } else { count.stringValue = searchTask == nil ? "" : "Searching…" }
        count.toolTip = errorMessage
        retry.toolTip = errorMessage ?? "Retry Search"
        retry.isHidden = errorMessage == nil
        previous.isEnabled = canNavigate
        next.isEnabled = canNavigate
    }

    private func control(_ title: String, _ symbol: String, action: @escaping () -> Void) -> ActionButton {
        let button = ActionButton(title, symbol: symbol, iconOnly: true, style: .subtle, action: action)
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }
}
