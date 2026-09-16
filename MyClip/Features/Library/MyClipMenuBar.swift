import AppKit
import SwiftUI
import MyClipCore

@MainActor
final class MyClipMenuBarController: NSObject, NSPopoverDelegate {
    private let model: MyClipModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: 56)
    private let popover = NSPopover()
    private var tooltip: NSPanel?
    private var tooltipAgent: ClipAgent?
    private var tooltipTask: Task<Void, Never>?
    private var presentedAgent: ClipAgent?
    private var iconView: AgentStatusView!

    init(model: MyClipModel) {
        self.model = model
        super.init()
        guard let button = statusItem.button, let container = button.window?.contentView else { return }
        button.title = ""
        button.isBordered = false
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: .leftMouseUp)
        button.setAccessibilityLabel("MyClip：Codex 和 Claude")
        iconView = AgentStatusView(frame: button.bounds)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        // Use the full menu bar height so the larger circles remain clickable at their edges.
        container.addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            iconView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            iconView.topAnchor.constraint(equalTo: container.topAnchor),
            iconView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        iconView.onHover = { [weak self] agent in self?.scheduleTooltip(for: agent) }
        iconView.onClick = { [weak self] agent in self?.showPanel(for: agent) }
        NotificationCenter.default.addObserver(self, selector: #selector(statusItemMoved), name: NSWindow.didMoveNotification, object: button.window)
        popover.behavior = .transient
        popover.delegate = self
        model.onStatusChange = { [weak self] in self?.refresh() }
        refresh()
    }

    private func refresh() {
        iconView?.states = Dictionary(uniqueKeysWithValues: ClipAgent.allCases.map { ($0, model.state($0)) })
        iconView?.needsDisplay = true
        if tooltip?.isVisible == true, let agent = tooltipAgent { showTooltip(for: agent) }
    }

    @objc private func statusItemClicked() { iconView.activateFromStatusItem() }

    private func scheduleTooltip(for agent: ClipAgent?) {
        guard tooltipAgent != agent else { return }
        tooltipTask?.cancel()
        tooltipAgent = agent
        tooltip?.orderOut(nil)
        guard let agent, !popover.isShown else { return }
        tooltipTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard let self, self.tooltipAgent == agent, !self.popover.isShown else { return }
            self.showTooltip(for: agent)
        }
    }

    private func showTooltip(for agent: ClipAgent) {
        guard !popover.isShown, iconView.window != nil else { return }
        let detail: String = switch model.state(agent).phase {
        case .disconnected: "尚未连接"
        case .connecting: "正在连接"
        case .ready: "已连接"
        case .working: "正在整理"
        case .permission: "等待确认"
        case .failed: "需要重试"
        case .installing: "正在准备"
        }
        let text = NSMutableAttributedString(string: agent.name, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor
        ])
        text.append(NSAttributedString(string: " · \(detail)", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor
        ]))
        if let panel = tooltip, let label = panel.contentView?.subviews.first as? NSTextField,
           label.stringValue == text.string {
            tooltipAgent = agent
            positionTooltip()
            if !panel.isVisible { panel.orderFrontRegardless() }
            return
        }
        let label = NSTextField(labelWithAttributedString: text)
        label.sizeToFit()
        let width = ceil(label.frame.width) + 20
        let panel = tooltip ?? NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 24),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let background = AgentTooltipBackground(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        label.setFrameOrigin(NSPoint(x: 10, y: floor((24 - label.frame.height) / 2)))
        background.addSubview(label)
        panel.contentView = background
        panel.setContentSize(NSSize(width: width, height: 24))
        tooltip = panel
        tooltipAgent = agent
        positionTooltip()
        if !panel.isVisible { panel.orderFrontRegardless() }
        panel.invalidateShadow()
    }

    private func positionTooltip() {
        guard let panel = tooltip, let agent = tooltipAgent, let window = iconView.window,
              let screen = window.screen else { return }
        let icon = iconView.rect(for: agent)
        let screenRect = window.convertToScreen(iconView.convert(icon, to: nil))
        let visible = screen.visibleFrame
        let width = panel.frame.width
        let x = min(visible.maxX - width - 8, max(visible.minX + 8, screenRect.midX - width / 2))
        let y = min(window.frame.minY, visible.maxY) - panel.frame.height - 4
        panel.setFrameOrigin(NSPoint(x: round(x), y: round(y)))
    }

    func showPanel(for agent: ClipAgent) {
        guard let button = statusItem.button else { return }
        scheduleTooltip(for: nil)
        if popover.isShown, presentedAgent == agent { popover.performClose(nil); return }
        presentedAgent = agent
        iconView.setPanelVisible(true)
        popover.appearance = NSApp.appearance
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let content = NSHostingController(rootView: AgentMenuPanel(model: model, agent: agent) { [weak self] in self?.popover.performClose(nil) }.environment(\.locale, Locale(identifier: "zh_Hans_CN")))
        content.sizingOptions = [.preferredContentSize]
        let size = content.view.fittingSize
        content.view.setFrameSize(size)
        popover.contentViewController = content
        popover.contentSize = size
        positionPanel(for: agent, button: button)
        popover.contentViewController?.view.window?.makeKey()
    }

    @objc private func statusItemMoved(_ notification: Notification) {
        positionTooltip()
        guard popover.isShown, let agent = presentedAgent, let button = statusItem.button,
              notification.object as? NSWindow === button.window else { return }
        positionPanel(for: agent, button: button)
    }

    private func positionPanel(for agent: ClipAgent, button: NSStatusBarButton) {
        button.window?.contentView?.layoutSubtreeIfNeeded()
        iconView.layoutSubtreeIfNeeded()
        let icon = iconView.convert(iconView.rect(for: agent), to: button)
        let anchor = NSRect(x: icon.midX - 1, y: button.bounds.minY, width: 2, height: button.bounds.height)
        popover.show(relativeTo: anchor, of: button, preferredEdge: button.isFlipped ? .maxY : .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        presentedAgent = nil
        iconView.setPanelVisible(false)
    }
}

@MainActor
private final class AgentTooltipBackground: NSVisualEffectView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBorder()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }
    private func updateBorder() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.22).cgColor
        }
        layer?.borderWidth = 1 / (window?.backingScaleFactor ?? 2)
    }
}

@MainActor
private final class AgentStatusView: NSView {
    var onHover: ((ClipAgent?) -> Void)?
    var onClick: ((ClipAgent) -> Void)?
    var states: [ClipAgent: ClipAgentState] = [:] {
        didSet {
            for agent in ClipAgent.allCases {
                let state = states[agent] ?? .init()
                buttons[agent]?.character.configure(state: state)
                buttons[agent]?.setAccessibilityValue(state.detail)
            }
            setAccessibilityValue(ClipAgent.allCases.map { "\($0.name)：\(states[$0]?.detail ?? "尚未连接")" }.joined(separator: "，"))
        }
    }
    private var buttons: [ClipAgent: AgentStatusButton] = [:]
    private var expanded = false
    private var panelVisible = false
    private var hovered: ClipAgent?
    private var collapseTask: Task<Void, Never>?
    private var tracking: NSTrackingArea?
    private var spread: CGFloat = 0
    private var animationTask: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("MyClip Agent 状态")
        setAccessibilityHelp("点击查看 Codex 和 Claude 的整理状态")
        for agent in [ClipAgent.claude, .codex] {
            let button = AgentStatusButton(agent: agent)
            button.frame = rect(for: agent)
            button.onClick = { [weak self] agent in
                self?.onHover?(nil)
                self?.onClick?(agent)
            }
            buttons[agent] = button
            addSubview(button)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    func rect(for agent: ClipAgent) -> NSRect {
        let diameter = min(26, bounds.height)
        let step: CGFloat = 18 + 12 * spread
        let width = diameter + step
        let start = (bounds.width - width) / 2
        return NSRect(x: start + (agent == .codex ? 0 : step), y: (bounds.height - diameter) / 2, width: diameter, height: diameter)
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }
        for agent in ClipAgent.allCases { buttons[agent]?.frame = rect(for: agent) }
    }

    override func mouseEntered(with event: NSEvent) {
        collapseTask?.cancel()
        expand(true)
        updateHover()
    }
    override func mouseMoved(with event: NSEvent) { updateHover() }
    override func mouseExited(with event: NSEvent) {
        hovered = nil
        for button in buttons.values {
            button.hovered = false
            button.character.look(at: nil, hovered: false)
        }
        onHover?(nil)
        needsDisplay = true
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
            self?.collapseIfOutside()
        }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { buttons[hovered ?? .codex]?.performClick(nil) }
        else if event.keyCode == 123 || event.keyCode == 124 {
            hovered = hovered == .codex ? .claude : .codex
            expand(true); onHover?(hovered); needsDisplay = true
        } else { super.keyDown(with: event) }
    }

    func setPanelVisible(_ value: Bool) {
        panelVisible = value
        if value { expand(true, animated: false) } else { collapseIfOutside() }
    }

    func activateFromStatusItem() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let button = (hitTest(convert(point, to: superview)) as? AgentStatusButton) ?? buttons[hovered ?? .codex]
        button?.performClick(nil)
    }

    func collapseIfOutside() {
        guard !panelVisible, let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if !bounds.contains(point) { expand(false) }
    }

    private func updateHover() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let agent = (hitTest(convert(point, to: superview)) as? AgentStatusButton)?.character.agent
        for (kind, button) in buttons {
            button.hovered = kind == agent
            button.character.look(at: button.character.convert(point, from: self), hovered: kind == agent)
        }
        if hovered != agent { hovered = agent; onHover?(agent); needsDisplay = true }
    }

    private func expand(_ value: Bool, animated: Bool = true) {
        let target: CGFloat = value ? 1 : 0
        guard expanded != value || (!animated && spread != target) else { return }
        expanded = value
        animationTask?.cancel()
        if !animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            spread = target
            needsLayout = true; needsDisplay = true; return
        }
        let start = spread
        let began = ProcessInfo.processInfo.systemUptime
        animationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let progress = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : min(1, (ProcessInfo.processInfo.systemUptime - began) / 0.18)
                let eased = 1 - pow(1 - progress, 3)
                self.spread = start + (target - start) * eased
                self.needsLayout = true
                self.layoutSubtreeIfNeeded()
                self.needsDisplay = true
                if progress >= 1 {
                    self.updateHover()
                    return
                }
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
        }
    }
}

@MainActor
private final class AgentStatusButton: NSButton {
    let character: AgentCharacterView
    var onClick: ((ClipAgent) -> Void)?
    var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }

    init(agent: ClipAgent) {
        character = AgentCharacterView(agent: agent)
        super.init(frame: .zero)
        title = ""
        isBordered = false
        appearance = NSAppearance(named: .aqua)
        target = self
        action = #selector(openPanel)
        sendAction(on: .leftMouseDown)
        setAccessibilityLabel(agent.name)
        setAccessibilityHelp("查看 \(agent.name) 状态")
        addSubview(character)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() { super.layout(); character.frame = bounds.insetBy(dx: 1, dy: 1) }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, NSBezierPath(ovalIn: bounds).contains(convert(point, from: superview)) else { return nil }
        return self
    }
    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        NSColor.white.setFill()
        circle.fill()
        if hovered || isHighlighted {
            NSColor.black.withAlphaComponent(isHighlighted ? 0.12 : 0.055).setFill()
            circle.fill()
        }
    }
    override func drawFocusRingMask() { NSBezierPath(ovalIn: bounds).fill() }

    @objc private func openPanel() {
        character.greet()
        onClick?(character.agent)
    }
}
