import AppKit

/// Owns both the visible thumb and pointer tracking. Its geometry never
/// depends on SwiftTerm's private scroller or renderer subviews.
final class TerminalScrollbar: NSControl {
    private(set) var position: Double = 1
    private(set) var proportion: CGFloat = 1
    private var dragOffset: CGFloat?
    var onScroll: ((Double) -> Void)?
    var onScrollLines: ((Int) -> Void)?
    var onScrollWheel: ((NSEvent) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isEnabled = false
        setAccessibilityRole(.scrollBar)
        setAccessibilityLabel("Conversation history")
        setAccessibilityOrientation(.vertical)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var knobRect: NSRect {
        let height = min(bounds.height, max(28, bounds.height * (isEnabled ? proportion : 1)))
        return NSRect(x: 2, y: (bounds.height - height) * CGFloat(position),
                      width: max(0, bounds.width - 4), height: height)
    }

    func update(position: Double, proportion: CGFloat, enabled: Bool) {
        let position = min(1, max(0, position))
        let proportion = min(1, max(0, proportion))
        guard self.position != position || self.proportion != proportion || isEnabled != enabled else { return }
        self.position = position
        self.proportion = proportion
        isEnabled = enabled
        if !enabled { dragOffset = nil }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        ElevateTheme.terminalBackground.setFill()
        bounds.fill()
        NSColor(white: 0.18, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 4, y: 0, width: max(0, bounds.width - 8), height: bounds.height),
                     xRadius: 4, yRadius: 4).fill()
        // Use the same high contrast signal as the app's primary action so
        // the current reading position is unmistakable on the ink surface.
        (isEnabled ? (dragOffset == nil ? ElevateTheme.nsSignal : .white)
                   : NSColor(white: 0.45, alpha: 1)).setFill()
        NSBezierPath(roundedRect: knobRect, xRadius: 4, yRadius: 4).fill()
        if isEnabled {
            // A narrow crossbar marks the viewport's exact position even when
            // the proportional thumb is almost as tall as the track.
            let markerY = min(bounds.height - 2, max(2, CGFloat(position) * bounds.height))
            ElevateTheme.nsInk.setFill()
            NSBezierPath(roundedRect: NSRect(x: 2, y: markerY - 1, width: max(0, bounds.width - 4), height: 2),
                         xRadius: 1, yRadius: 1).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        // Clicking the track puts the thumb under the pointer; grabbing the
        // thumb preserves the grab offset so it does not jump on mouse-down.
        dragOffset = knobRect.contains(point) ? point.y - knobRect.minY : knobRect.height / 2
        moveThumb(to: point.y)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragOffset != nil else { return }
        moveThumb(to: convert(event.locationInWindow, from: nil).y)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragOffset != nil else { return }
        moveThumb(to: convert(event.locationInWindow, from: nil).y)
        dragOffset = nil
        needsDisplay = true
    }

    private func moveThumb(to y: CGFloat) {
        guard let dragOffset, bounds.height > knobRect.height else { return }
        scroll(to: Double((y - dragOffset) / (bounds.height - knobRect.height)))
    }

    private func scroll(to value: Double) {
        guard isEnabled else { return }
        position = min(1, max(0, value))
        needsDisplay = true
        onScroll?(position)
    }

    override func scrollWheel(with event: NSEvent) { onScrollWheel?(event) }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 115: scroll(to: 0) // Home
        case 119: scroll(to: 1) // End
        case 126: onScrollLines?(-1)
        case 125: onScrollLines?(1)
        case 116: scroll(to: position - pageStep)
        case 121: scroll(to: position + pageStep)
        default: super.keyDown(with: event)
        }
    }

    private var pageStep: Double { Double(proportion / max(0.001, 1 - proportion)) }
    override func accessibilityValue() -> Any? { position * 100 }
    override func accessibilityMinValue() -> Any? { 0.0 }
    override func accessibilityMaxValue() -> Any? { 100.0 }
    override func setAccessibilityValue(_ value: Any?) {
        guard let number = value as? NSNumber else { return }
        scroll(to: number.doubleValue / 100)
    }
    override func accessibilityPerformIncrement() -> Bool {
        guard isEnabled else { return false }
        scroll(to: position + pageStep)
        return true
    }
    override func accessibilityPerformDecrement() -> Bool {
        guard isEnabled else { return false }
        scroll(to: position - pageStep)
        return true
    }
}
