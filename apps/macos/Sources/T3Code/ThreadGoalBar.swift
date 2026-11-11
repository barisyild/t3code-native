import AppKit

@MainActor
final class ThreadGoalBar: NSView {
    private struct State: Equatable {
        let goal: ThreadGoal
        let driver: ComposerProvider?
        let working: Bool
        let canOperate: Bool

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
    private lazy var details = button("Goal Details", symbol: "arrow.up.left.and.arrow.down.right") { [weak self] in
        self?.showDetails()
    }
    private let detailText = NSTextView()
    private var popover: NSPopover?
    private var state: State?
    var onAction: ((ThreadGoal.Action) -> Void)?

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

    func render(_ goal: ThreadGoal?, driver: ComposerProvider? = nil, working: Bool = false, canOperate: Bool = false) {
        let next = goal.map { State(goal: $0, driver: driver, working: working, canOperate: canOperate) }
        guard next != state else { return }
        if state?.goal.objective != goal?.objective { closeDetails() }
        state = next
        isHidden = next == nil
        guard let next else { return }
        status.stringValue = next.title
        objective.stringValue = next.goal.objective.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        objective.toolTip = next.goal.objective
        objective.setAccessibilityLabel(next.goal.objective)
        progress.stringValue = next.goal.progress ?? ""
        progress.isHidden = progress.stringValue.isEmpty
        clear.isHidden = driver == nil
        clear.isEnabled = canOperate
        toggle.isHidden = driver != .codex || next.goal.status == .complete
        toggle.isEnabled = canOperate && next.goal.allows(next.toggleAction, driver: .codex, working: working)
        let pause = next.toggleAction == .pause
        let actionTitle = pause ? "Pause Goal" : "Resume Goal"
        toggle.image = WorkspaceStyle.symbol(pause ? "pause.circle" : "play.circle")
        toggle.toolTip = actionTitle
        toggle.setAccessibilityLabel(actionTitle)
        if popover?.isShown == true { updateDetails(next) }
    }

    func closeDetails() { popover?.close() }

    private func button(_ title: String, symbol: String, action: @escaping () -> Void) -> ActionButton {
        let button = ActionButton(title, symbol: symbol, iconOnly: true, style: .subtle, action: action)
        button.widthAnchor.constraint(equalToConstant: 25).isActive = true
        button.heightAnchor.constraint(equalToConstant: 25).isActive = true
        return button
    }

    private func showDetails() {
        guard let state else { return }
        if popover == nil {
            detailText.font = .systemFont(ofSize: 13)
            detailText.textColor = WorkspaceStyle.ink
            detailText.textContainerInset = NSSize(width: 0, height: 3)
            let heading = label("Goal Details", size: 13, weight: .semibold, color: WorkspaceStyle.ink)
            let body = column([heading, textScroller(detailText)], spacing: 7, alignment: .width)
            let controller = NSViewController()
            controller.view = Surface(WorkspaceStyle.navigation)
            fill(body, in: controller.view, inset: 13)
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = controller
            popover.contentSize = NSSize(width: 390, height: 175)
            self.popover = popover
        }
        updateDetails(state)
        popover?.show(relativeTo: details.bounds, of: details, preferredEdge: .maxY)
    }

    private func updateDetails(_ state: State) {
        let goal = state.goal
        var sections = [state.title, goal.objective]
        var usage = [goal.progress].compactMap { $0 }
        if let tokens = goal.tokensUsed {
            let count = tokens.formatted()
            usage.append(goal.tokenBudget.map { "\(count) / \($0.formatted()) tokens" } ?? "\(count) tokens")
        }
        if !usage.isEmpty { sections.append(usage.joined(separator: " · ")) }
        if let check = goal.lastCheck, !check.isEmpty { sections.append("Last check\n\(check)") }
        detailText.string = sections.joined(separator: "\n\n")
    }
}
