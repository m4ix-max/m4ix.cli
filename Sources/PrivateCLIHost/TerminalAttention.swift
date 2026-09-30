import AppKit
import Foundation
import UserNotifications

/// Reads the desktop notifications the hosted CLIs write into the terminal.
/// The launcher asks Claude for OSC 777 (`notify;title;body`) and Codex for
/// OSC 9 (`body`). OSC 9 bodies that start with a number and a semicolon are
/// ConEmu commands such as `4;` progress, not messages.
enum TerminalAttention {
    static func notification(oscCode: Int, payload: [UInt8]) -> String? {
        let text = String(decoding: payload, as: UTF8.self)
        switch oscCode {
        case 777:
            let parts = text.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.first == "notify" else { return nil }
            let body = parts.count > 2 ? String(parts[2]) : ""
            let title = parts.count > 1 ? String(parts[1]) : ""
            return clean(body.isEmpty ? title : body)
        case 9:
            if text.range(of: #"^\d+;"#, options: .regularExpression) != nil { return nil }
            return clean(text)
        default:
            return nil
        }
    }

    private static func clean(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return String(line.trimmingCharacters(in: .whitespaces).prefix(160))
    }
}

/// Infers turns from terminal output. Both CLIs redraw a spinner at least once
/// a second while they work and write nothing while idle, so output that stops
/// after a stretch of work marks a turn that ended or is waiting on a prompt.
struct TurnDetector {
    static let quietAfter: TimeInterval = 2.5
    static let minimumTurn: TimeInterval = 4

    private(set) var isWorking = false
    private(set) var lastWorkEnded: Date?
    private var workingSince: Date?

    /// Returns true when a turn long enough to report has just ended.
    mutating func update(outputAge: TimeInterval?, now: Date) -> Bool {
        guard let outputAge else { return false }
        let lastOutput = now.addingTimeInterval(-outputAge)
        if outputAge < Self.quietAfter {
            if !isWorking {
                isWorking = true
                workingSince = lastOutput
            }
            return false
        }
        guard isWorking, let since = workingSince else { return false }
        isWorking = false
        workingSince = nil
        lastWorkEnded = lastOutput
        return lastOutput.timeIntervalSince(since) >= Self.minimumTurn
    }

    mutating func reset() {
        isWorking = false
        workingSince = nil
    }
}

/// Dock badge and system notifications for sessions that need attention.
/// A development build run outside an app bundle has no notification centre,
/// so it only badges the Dock.
@MainActor
enum AttentionNotifier {
    private static var isBundled: Bool {
        ProcessInfo.processInfo.environment["M4IX_PACKAGED_SMOKE_REPORT"] == nil &&
            Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    static func install(delegate: UNUserNotificationCenterDelegate) {
        guard isBundled else { return }
        UNUserNotificationCenter.current().delegate = delegate
    }

    static func setBadge(_ count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

    static func post(sessionID: UUID, title: String, body: String) {
        guard isBundled else { return }
        let center = UNUserNotificationCenter.current()
        let identifier = sessionID.uuidString.lowercased()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = ["hostSession": identifier]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }

    static func withdraw(sessionID: UUID) {
        guard isBundled else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: [sessionID.uuidString.lowercased()]
        )
    }
}
