import AppKit

struct NativeSubagentWork {
    struct Step {
        let type: String
        let status: String?
        let text: String?
        let calls: [String]

        init?(_ value: Wire) {
            guard let type = value["type"].string else { return nil }
            self.type = type
            status = value["status"].string
            text = value["text"].string
            calls = value["toolCalls"].array.compactMap { call in
                guard let name = call["name"].string else { return nil }
                return [name, call["input"].string].compactMap { $0 }.joined(separator: " ")
            }
        }
    }

    let role: String
    let prompt: String
    let steps: [Step]?
    let truncated: Bool

    init?(_ value: Wire) {
        guard value["conversationId"].string != nil, let role = value["role"].string, let prompt = value["prompt"].string else { return nil }
        self.role = role
        self.prompt = prompt
        steps = value["steps"] == .null ? nil : value["steps"].array.compactMap(Step.init)
        truncated = value["truncated"].bool == true
    }
}

@MainActor
final class RelatedWorkSheet: NSWindowController {
    enum Content {
        case subagent(ThreadSubagent, title: String)
        case nativeChildren
        case workflowScript(ThreadSubagent)

        var title: String {
            switch self {
            case .subagent(_, let title): title
            case .nativeChildren: "Subagent Work"
            case .workflowScript: "Workflow Script"
            }
        }
    }

    private let workspace: Workspace
    private let scope: ThreadRelationshipScope
    private let content: Content
    private let transcript = NSTextView()
    private let notice = NSTextField(wrappingLabelWithString: "")
    private lazy var refresh = ActionButton("Refresh", symbol: "arrow.clockwise", style: .subtle) { [weak self] in self?.load() }
    private lazy var done = ActionButton("Done", style: .subtle) { [weak self] in
        guard let window = self?.window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }
    private var task: Task<Void, Never>?
    var onClose: (() -> Void)?

    init(workspace: Workspace, scope: ThreadRelationshipScope, content: Content) {
        self.workspace = workspace
        self.scope = scope
        self.content = content
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 610, height: 448),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = content.title
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 440, height: 270)
        transcript.setAccessibilityLabel(content.title)
        transcript.textContainerInset = NSSize(width: 4, height: 4)
        let scroll = textScroller(transcript)
        scroll.hasVerticalScroller = true
        notice.font = .systemFont(ofSize: 11.5)
        notice.maximumNumberOfLines = 4
        let heading = label(content.title, size: 17, weight: .semibold, color: WorkspaceStyle.ink)
        done.keyEquivalent = "\u{1b}"
        let surface = Surface(WorkspaceStyle.navigation)
        window.contentView = surface
        fill(column([heading, notice, scroll, row([refresh, NSView(), done])], spacing: 10, alignment: .width), in: surface, inset: 19)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present(in parent: NSWindow) {
        guard let window, parent.attachedSheet == nil else { return }
        parent.beginSheet(window) { [weak self] _ in
            self?.task?.cancel()
            self?.onClose?()
        }
        load()
    }

    private func load() {
        guard task == nil else { return }
        if case .subagent(let agent, _) = content {
            refresh.isHidden = true
            status("")
            let text = NSMutableAttributedString()
            append([agent.model, agent.status.replacingOccurrences(of: "_", with: " ").capitalized]
                .compactMap { $0 }.joined(separator: " · "), to: text)
            if !agent.prompt.isEmpty { section("Prompt", body: agent.prompt, into: text) }
            if let progress = agent.progress, !progress.isEmpty { section("Progress", body: progress, into: text) }
            if let result = agent.result, !result.isEmpty { section("Result", body: result, into: text) }
            transcript.textStorage?.setAttributedString(text)
            return
        }
        refresh.isEnabled = false
        status("Loading…")
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil; refresh.isEnabled = true }
            do {
                let text: NSAttributedString
                let message: String
                switch content {
                case .nativeChildren:
                    let children = try await workspace.nativeChildWork(scope)
                    text = nativeTranscript(children)
                    message = children.isEmpty ? "The provider has no record of child work for this subagent." : ""
                case .workflowScript(let agent):
                    let script = try await workspace.workflowScript(agent.id, scope: scope)
                    text = TranscriptText.monospace(script.contents)
                    message = script.truncated ? "This script exceeds the preview size." : ""
                case .subagent: return
                }
                guard !Task.isCancelled else { return }
                transcript.textStorage?.setAttributedString(text)
                status(message)
            } catch {
                if !Task.isCancelled { status(error.localizedDescription, error: true) }
            }
        }
    }

    private func status(_ message: String, error: Bool = false) {
        notice.stringValue = message
        notice.textColor = error ? WorkspaceStyle.negative : WorkspaceStyle.muted
        notice.isHidden = message.isEmpty
    }

    private func nativeTranscript(_ children: [NativeSubagentWork]) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for child in children {
            if text.length > 0 { append("\n\n", to: text) }
            append(child.role.isEmpty ? "Subagent" : child.role, to: text, heading: true)
            if !child.prompt.isEmpty { append("\n" + child.prompt, to: text) }
            if child.truncated { append("\nEarlier steps were omitted by the provider.", to: text) }
            if let steps = child.steps {
                for step in steps {
                    let title = [step.type, step.status == "DONE" ? nil : step.status]
                        .compactMap { $0 }.map { $0.replacingOccurrences(of: "_", with: " ").capitalized }.joined(separator: " · ")
                    let body = (step.calls + [step.text].compactMap { $0 }).joined(separator: "\n")
                    section(title, body: body, into: text)
                }
            } else { append("\nNo transcript reported.", to: text) }
        }
        return text
    }

    private func section(_ title: String, body: String, into text: NSMutableAttributedString) {
        append("\n\n" + title + "\n", to: text, heading: true)
        append(body, to: text)
    }

    private func append(_ value: String, to text: NSMutableAttributedString, heading: Bool = false) {
        text.append(NSAttributedString(string: value, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: heading ? .semibold : .regular),
            .foregroundColor: heading ? WorkspaceStyle.ink : WorkspaceStyle.secondary,
        ]))
    }
}
