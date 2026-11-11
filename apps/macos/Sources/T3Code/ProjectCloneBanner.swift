import AppKit

@MainActor
final class ProjectCloneBanner: NSView {
    private let workspace: Workspace
    private let title = label(size: 12.5, weight: .medium, color: WorkspaceStyle.ink)
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private lazy var cancel = ActionButton("Cancel Clone", style: .subtle) { [weak self] in self?.run(.cancel) }
    private lazy var retry = ActionButton("Retry Clone", style: .subtle) { [weak self] in self?.run(.retry) }
    private lazy var remove = ActionButton("Remove Project", style: .subtle) { [weak self] in self?.run(.remove) }
    private var status: ProjectCloneStatus?
    private var projectName: String?
    private var failure: String?
    private var task: Task<Void, Never>?
    var onRemoved: ((String) -> Void)?

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(frame: .zero)
        isHidden = true
        detail.font = .systemFont(ofSize: 11.5)
        detail.textColor = WorkspaceStyle.secondary
        detail.maximumNumberOfLines = 3
        progress.style = .bar
        progress.controlSize = .small
        progress.isIndeterminate = false
        progress.maxValue = 100
        progress.setAccessibilityLabel("Repository Clone Progress")
        remove.contentTintColor = WorkspaceStyle.negative
        let heading = row([WorkspaceStyle.icon("arrow.down.circle", size: 13), title, NSView(), cancel, remove, retry], spacing: 7)
        let content = column([heading, detail, progress], spacing: 5, alignment: .width)
        let card = Surface(WorkspaceStyle.composer, border: WorkspaceStyle.outline, radius: 9)
        fill(content, in: card, inset: 9)
        fill(card, in: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func render(_ status: ProjectCloneStatus?, projectName: String?) {
        if self.status?.id != status?.id || self.status?.phase != status?.phase { failure = nil }
        self.status = status
        self.projectName = projectName
        update()
    }

    private func update() {
        guard let status, status.blocksCheckout else { isHidden = true; return }
        isHidden = false
        let name = projectName ?? "repository"
        let target = workspace.projectTarget(status.id)
        let canControl = target != nil && workspace.can("source-control:write") && task == nil
        title.stringValue = switch status.phase {
        case .starting, .running: "Cloning \(name)"
        case .failed: "Couldn’t clone \(name)"
        case .cancelled: "Clone cancelled"
        case .done: ""
        }
        detail.stringValue = failure ?? (status.phase == .failed ? status.error ?? "The repository could not be cloned." :
            status.phase == .cancelled ? "Retry to finish cloning this repository." : status.progressText)
        detail.textColor = failure == nil ? WorkspaceStyle.secondary : WorkspaceStyle.negative
        cancel.isHidden = status.phase != .running
        cancel.isEnabled = canControl
        retry.isHidden = !status.canRetry
        retry.isEnabled = canControl
        remove.isHidden = !status.canRetry
        remove.isEnabled = target != nil && workspace.can("orchestration:operate") && task == nil
        progress.isHidden = status.phase != .running || status.percent == nil
        if let percent = status.percent { progress.doubleValue = Double(percent) }
    }

    private func run(_ control: ProjectCloneControl) {
        guard task == nil, let status, let target = workspace.projectTarget(status.id) else { return }
        failure = nil
        task = Task { [weak self, workspace] in
            do {
                let applied = try await workspace.controlProjectClone(target, control)
                if applied, case .remove = control { self?.onRemoved?(target.id) }
            } catch { if self?.status?.id == target.id { self?.failure = error.localizedDescription } }
            self?.task = nil
            self?.update()
        }
        update()
    }
}
