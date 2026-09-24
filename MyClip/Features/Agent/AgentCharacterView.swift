import AppKit
import MyClipCore

@MainActor
final class AgentCharacterView: NSView {
    let agent: ClipAgent
    private var state = ClipAgentState()
    private var animated = true
    private var interactive = false
    private var motionDisabled = false
    private var hovered = false
    private var gaze = CGPoint.zero
    private var greetingUntil = Date.distantPast
    private var blinkUntil = Date.distantPast
    private var nextBlink = Date.now.addingTimeInterval(Double.random(in: 3...6))
    private var animationTask: Task<Void, Never>?
    private var tracking: NSTrackingArea?

    init(agent: ClipAgent) {
        self.agent = agent
        super.init(frame: .zero)
        focusRingType = .none
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(motionPreferenceChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { animationTask?.cancel() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { interactive }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 3, dy: 3) }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 12, yRadius: 12).fill() }
    override func becomeFirstResponder() -> Bool {
        focusRingType = NSApp.currentEvent?.type == .keyDown ? .exterior : .none
        return super.becomeFirstResponder()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { interactive ? super.hitTest(point) : nil }

    func configure(state: ClipAgentState, animated: Bool = true, interactive: Bool = false, reduceMotion: Bool = false) {
        let changed = self.state.phase != state.phase || self.state.lastCompleted != state.lastCompleted
            || self.animated != animated || motionDisabled != reduceMotion
        self.state = state
        self.animated = animated
        self.interactive = interactive
        motionDisabled = reduceMotion
        setAccessibilityElement(interactive)
        setAccessibilityRole(.button)
        setAccessibilityLabel(state.detail.isEmpty ? agent.name : "\(agent.name) · \(state.detail)")
        if changed || animationTask == nil { restartAnimation() }
        needsDisplay = true
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); restartAnimation() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    @objc private func motionPreferenceChanged() { restartAnimation(); needsDisplay = true }
    private var reduceMotion: Bool { motionDisabled || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func restartAnimation() {
        animationTask?.cancel()
        animationTask = nil
        guard animated, window != nil else { return }
        animationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.advanceAnimation() else { return }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
    }

    private func advanceAnimation() -> TimeInterval? {
        guard window != nil else { return nil }
        guard window?.isVisible == true, !isHiddenOrHasHiddenAncestor else { return 1 }
        let now = Date.now
        let expression = state.expression(at: now)
        needsDisplay = true
        if reduceMotion {
            if expression == .happy, let completed = state.lastCompleted { return max(0.05, 2 - now.timeIntervalSince(completed)) }
            return nil
        }
        if (expression == .asleep && now >= greetingUntil) || expression == .attention { return nil }
        if now >= nextBlink {
            blinkUntil = now.addingTimeInterval(0.16)
            nextBlink = now.addingTimeInterval(Double.random(in: 3...6))
        }
        if expression == .working || expression == .happy || now < greetingUntil || now < blinkUntil { return 1.0 / 30 }
        return max(0.05, nextBlink.timeIntervalSince(now))
    }

    func look(at point: CGPoint?, hovered: Bool) {
        self.hovered = hovered
        if let point, !reduceMotion {
            gaze = CGPoint(x: max(-1, min(1, (point.x / max(1, bounds.width) - 0.5) * 2)),
                           y: max(-1, min(1, (point.y / max(1, bounds.height) - 0.5) * 2)))
        } else { gaze = .zero }
        needsDisplay = true
    }

    func greet() {
        guard state.expression(at: .now) != .attention else { return }
        greetingUntil = .now.addingTimeInterval(1.2)
        restartAnimation()
        needsDisplay = true
    }
    override func accessibilityPerformPress() -> Bool { guard interactive else { return false }; greet(); return true }
    override func mouseDown(with event: NSEvent) { focusRingType = .none; greet() }
    override func keyDown(with event: NSEvent) {
        focusRingType = .exterior
        if event.keyCode == 36 || event.keyCode == 49 { greet() } else { super.keyDown(with: event) }
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) { look(at: convert(event.locationInWindow, from: nil), hovered: true) }
    override func mouseExited(with event: NSEvent) { look(at: nil, hovered: false) }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let now = Date.now
        let expression = animated ? state.expression(at: now) : .idle
        AgentCharacterDrawing.draw(agent: agent, expression: expression, in: bounds, context: context,
            time: reduceMotion || !animated ? 0 : now.timeIntervalSinceReferenceDate,
            moving: animated && !reduceMotion, blinking: animated && !reduceMotion && now < blinkUntil,
            greeting: animated && !reduceMotion && now < greetingUntil && expression != .attention,
            gaze: reduceMotion ? .zero : gaze, hovered: hovered && !reduceMotion)
    }
}

@MainActor
enum AgentCharacterDrawing {
    private static let blossom = mask(named: "OpenAIBlossom")
    private static let cursorMark = mask(named: "CursorIcon")

    /// Rasterises a vector asset at a fixed resolution so the mask stays sharp regardless of the SVG's declared size.
    private static func mask(named name: String, pixels: Int = 256) -> CGImage? {
        guard let image = NSImage(named: name),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    static func draw(agent: ClipAgent, expression: ClipAgentState.Expression, in bounds: CGRect, context c: CGContext,
                     time: TimeInterval, moving: Bool, blinking: Bool, greeting: Bool, gaze: CGPoint, hovered: Bool) {
        let compact = bounds.width < 45
        let side = min(bounds.width / 1.35, bounds.height / 1.15)
        let wave = moving ? sin(time * .pi * 2 / 1.7) : 0
        let working = expression == .working
        let smiling = expression == .happy || greeting
        let orange = NSColor(srgbRed: 0.898, green: 0.537, blue: 0.439, alpha: 1)
        let ink = agent == .claude ? NSColor(srgbRed: 0.145, green: 0.10, blue: 0.08, alpha: 1) : NSColor.labelColor
        let body: NSColor
        switch agent {
        case .claude: body = orange
        case .opencode: body = NSColor.labelColor
        case .cursor: body = NSColor.labelColor
        case .codex: body = NSColor.labelColor
        }
        func fill(_ rect: CGRect, _ color: NSColor, radius: CGFloat = 0) {
            c.setFillColor(color.cgColor)
            c.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)); c.fillPath()
        }
        func stroke(_ points: [CGPoint], _ color: NSColor, width: CGFloat) {
            guard let first = points.first else { return }
            c.setStrokeColor(color.cgColor); c.setLineWidth(width); c.setLineCap(.round); c.setLineJoin(.round)
            c.beginPath(); c.move(to: first); points.dropFirst().forEach { c.addLine(to: $0) }; c.strokePath()
        }
        c.saveGState()
        c.translateBy(x: bounds.midX, y: bounds.midY)
        c.scaleBy(x: side / 100, y: side / 100)
        let tilt = expression == .attention ? 0.10 : working ? wave * 0.045 : hovered ? gaze.x * 0.08 - 0.06 : greeting ? -0.07 : 0
        c.rotate(by: moving ? tilt : 0)
        if smiling && moving { c.translateBy(x: 0, y: -abs(wave) * (compact ? 1 : 3)) }
        c.translateBy(x: -50, y: -50)

        if agent == .cursor {
            // Cursor keeps its wordless logo (LobeHub icon set) in label colour; no face, only the attention dot.
            if let cursorMark {
                c.saveGState()
                c.translateBy(x: 0, y: 100); c.scaleBy(x: 1, y: -1)
                c.clip(to: CGRect(x: 6, y: 6, width: 88, height: 88), mask: cursorMark)
                fill(CGRect(x: 0, y: 0, width: 100, height: 100), body)
                c.restoreGState()
            }
            if expression == .attention { fill(CGRect(x: 91, y: -3, width: 15, height: 15), .systemOrange, radius: 7.5) }
            c.restoreGState()
            return
        }

        if agent == .claude {
            for x: CGFloat in [10, 28, 64, 82] { fill(CGRect(x: x, y: 74, width: 8, height: 15), body) }
            fill(CGRect(x: 0, y: 14, width: 100, height: 62), body)
        } else if agent == .opencode {
            // OpenCode mark (LobeHub icon set): a tall frame with a rectangular window the face looks out of.
            c.saveGState()
            c.addRect(CGRect(x: 10, y: 0, width: 80, height: 100))
            c.addRect(CGRect(x: 30, y: 20, width: 40, height: 60))
            c.clip(using: .evenOdd)
            fill(CGRect(x: 10, y: 0, width: 80, height: 100), body)
            c.restoreGState()
        } else {
            if let blossom {
                c.saveGState()
                if !compact {
                    c.addRect(CGRect(x: 0, y: 0, width: 100, height: 100))
                    c.addPath(CGPath(roundedRect: CGRect(x: 29, y: 30, width: 42, height: 40), cornerWidth: 15, cornerHeight: 15, transform: nil))
                    c.clip(using: .evenOdd)
                }
                c.translateBy(x: 0, y: 100); c.scaleBy(x: 1, y: -1)
                c.clip(to: CGRect(x: 0, y: 0, width: 100, height: 100), mask: blossom)
                fill(CGRect(x: 0, y: 0, width: 100, height: 100), body)
                c.restoreGState()
            }
        }

        if agent == .claude || !compact {
            if working && !compact {
                if agent == .claude {
                    fill(CGRect(x: 27, y: 76, width: 48, height: 7), .systemGray)
                    fill(CGRect(x: 27, y: 73, width: 48, height: 6), .white)
                    stroke([CGPoint(x: 31, y: 76), CGPoint(x: 69, y: 76)], .systemGray, width: 1)
                    fill(CGRect(x: 27, y: 58, width: 9, height: 14), orange.blended(withFraction: 0.17, of: .brown) ?? orange)
                    c.saveGState(); c.translateBy(x: 64 + wave * 2, y: 53); c.rotate(by: 0.3 + wave * 0.08)
                    fill(CGRect(x: -3, y: -9, width: 6, height: 26), .systemYellow)
                    fill(CGRect(x: -2, y: 17, width: 4, height: 3), ink)
                    c.restoreGState()
                    fill(CGRect(x: 58 + wave * 2, y: 57, width: 10, height: 9), orange.blended(withFraction: 0.17, of: .brown) ?? orange)
                } else {
                    fill(CGRect(x: 38, y: 76, width: 26, height: 25), .controlBackgroundColor, radius: 2)
                    stroke([CGPoint(x: 44, y: 84), CGPoint(x: 58, y: 84)], .secondaryLabelColor, width: 1.5)
                    stroke([CGPoint(x: 44, y: 90), CGPoint(x: 55, y: 90)], .secondaryLabelColor, width: 1.5)
                    fill(CGRect(x: 27, y: 81 + wave * 2, width: 12, height: 15), body, radius: 6)
                    fill(CGRect(x: 64, y: 79 - wave * 2, width: 12, height: 15), body, radius: 6)
                }
            } else {
                let handY: CGFloat = smiling ? 31 : 43
                let swing = working ? wave * 6 : 0
                let bodyInset: CGFloat = agent == .opencode ? 10 : 0
                fill(CGRect(x: -14 + bodyInset, y: handY + swing, width: 14, height: 14), body, radius: agent == .claude ? 0 : 7)
                c.saveGState(); c.translateBy(x: 108 - bodyInset, y: handY + 7 - swing)
                if greeting { c.rotate(by: -0.35 + wave * 0.55) }
                fill(CGRect(x: -7, y: -7, width: 14, height: 14), body, radius: agent == .claude ? 0 : 7)
                c.restoreGState()
            }
        }

        if agent != .claude && compact {
            if expression == .attention { fill(CGRect(x: 91, y: -3, width: 15, height: 15), .systemOrange, radius: 7.5) }
            c.restoreGState()
            return
        }
        c.saveGState()
        let readingX = working && moving ? sin(time * 1.85) * 2 : gaze.x * 3
        c.translateBy(x: readingX, y: working ? 2 : gaze.y * 2)
        let eyeXs: [CGFloat] = agent == .claude ? [21, 75] : [37, 57]
        for (index, x) in eyeXs.enumerated() {
            let y: CGFloat = agent == .claude ? 33 : 42
            if smiling {
                if agent == .claude {
                    stroke([CGPoint(x: x - 2, y: y + 11), CGPoint(x: x + 4, y: y + 5), CGPoint(x: x + 10, y: y + 11)], ink, width: 4)
                } else {
                    c.setStrokeColor(ink.cgColor); c.setLineWidth(2.8); c.setLineCap(.round)
                    c.move(to: CGPoint(x: x, y: y + 10))
                    c.addQuadCurve(to: CGPoint(x: x + 7, y: y + 10), control: CGPoint(x: x + 3.5, y: y + 1)); c.strokePath()
                }
            } else {
                let closed = blinking || expression == .asleep
                let height: CGFloat = closed ? 2 : expression == .attention && index == 0 ? 8 : 17
                fill(CGRect(x: x, y: y + (17 - height) / 2, width: 7, height: height), ink, radius: agent == .claude ? 0 : 3.5)
            }
        }
        c.restoreGState()
        if expression == .attention {
            fill(CGRect(x: 91, y: -8, width: 17, height: 17), .systemOrange, radius: 8.5)
            fill(CGRect(x: 98, y: -5, width: 3, height: 7), .black, radius: 1)
            fill(CGRect(x: 98, y: 4, width: 3, height: 3), .black, radius: 1)
        }
        c.restoreGState()
    }
}
