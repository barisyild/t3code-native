import AppKit

@MainActor
final class ThreadGoalBar: NSView {
    private struct State: Equatable {
        let goal: ThreadGoal
        let driver: ComposerProvider?
        let working: Bool
        let canOperate: Bool
        let timing: ThreadGoal.Timing?

        var title: String { goal.status == .active && !working ? "Goal set" : goal.title }
        var toggleAction: ThreadGoal.Action { goal.status == .active ? .pause : .resume }
    }

    private let status = label(size: 12.5, weight: .medium, color: WorkspaceStyle.ink)
    private let objective = label(size: 12.5, color: WorkspaceStyle.muted)
    private let progress = label(size: 12, color: WorkspaceStyle.muted)
    private lazy var clear = button("Clear Goal", symbol: "trash") { [weak self] in self?.onAction?(.clear) }
    private lazy var toggle = button("Pause Goal", symbol: "pause.circle") { [weak self] in
        guard let self, let state else { return }
        onAction?(state.toggleAction)
    }
    private lazy var details = button("Edit Goal", symbol: "arrow.up.left.and.arrow.down.right") { [weak self] in
        self?.onOpenDetails?()
    }
    private var state: State?
    var onAction: ((ThreadGoal.Action) -> Void)?
    var onOpenDetails: (() -> Void)?

    init() {
        super.init(frame: .zero)
        isHidden = true
        let target = WorkspaceStyle.icon("scope", size: 14, tint: WorkspaceStyle.muted)
        target.widthAnchor.constraint(equalToConstant: 16).isActive = true
        status.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        objective.setContentHuggingPriority(.init(249), for: .horizontal)
        progress.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        progress.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let controls = row([clear, toggle, details], spacing: 3)
        let line = row([target, status, objective, progress, controls], spacing: 7)
        let divider = Surface(WorkspaceStyle.outline)
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        fill(column([line, divider], spacing: 4, alignment: .width), in: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func render(_ goal: ThreadGoal?, driver: ComposerProvider? = nil, working: Bool = false, canOperate: Bool = false,
                timing: ThreadGoal.Timing? = nil) {
        let next = goal.map { State(goal: $0, driver: driver, working: working, canOperate: canOperate, timing: timing) }
        guard next != state else { return }
        state = next
        isHidden = next == nil
        guard let next else { return }
        status.stringValue = next.title
        objective.stringValue = next.goal.objective.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        objective.toolTip = next.goal.objective
        objective.setAccessibilityLabel(next.goal.objective)
        updateProgress(next)
        clear.isHidden = driver == nil
        clear.isEnabled = canOperate
        toggle.isHidden = driver != .codex || next.goal.status == .complete
        toggle.isEnabled = canOperate && next.goal.allows(next.toggleAction, driver: .codex, working: working)
        let pause = next.toggleAction == .pause
        let actionTitle = pause ? "Pause Goal" : "Resume Goal"
        toggle.image = WorkspaceStyle.symbol(pause ? "pause.circle" : "play.circle")
        toggle.toolTip = actionTitle
        toggle.setAccessibilityLabel(actionTitle)
    }

    func refreshElapsedTime() {
        guard let state, state.timing?.startedAt != nil else { return }
        updateProgress(state)
    }

    private func updateProgress(_ state: State) {
        let value = state.timing?.label(at: Date()) ?? state.goal.progress ?? ""
        if progress.stringValue != value { progress.stringValue = value }
        progress.isHidden = value.isEmpty
        if state.timing != nil, state.goal.timeUsedSeconds == nil {
            progress.toolTip = "Elapsed time for the current turn"
        } else { progress.toolTip = nil }
    }

    func setDetailsPresented(_ presented: Bool) {
        let title = presented ? "Close Goal Editor" : "Edit Goal"
        details.image = WorkspaceStyle.symbol(presented ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        details.toolTip = title
        details.setAccessibilityLabel(title)
        details.isMarked = presented
    }

    private func button(_ title: String, symbol: String, action: @escaping () -> Void) -> ActionButton {
        let button = ActionButton(title, symbol: symbol, iconOnly: true, style: .subtle, action: action)
        button.widthAnchor.constraint(equalToConstant: 25).isActive = true
        button.heightAnchor.constraint(equalToConstant: 25).isActive = true
        return button
    }

}
