import AppKit

extension NSApplication {
    /// Dispatches queued events except keyboard input. The test panels take
    /// the keyboard without activating, so keys typed on the Mac during a run
    /// arrive here; the tests' own keys go straight to `NSWindow.sendEvent`.
    @MainActor
    func dispatchQueuedEventsExceptKeyboard() {
        while let event = nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true) {
            if [.keyDown, .keyUp, .flagsChanged].contains(event.type) { continue }
            sendEvent(event)
        }
    }
}
