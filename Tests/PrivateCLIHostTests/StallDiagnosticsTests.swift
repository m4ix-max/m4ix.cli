import Foundation
import XCTest
@testable import PrivateCLIHost

/// A freeze is logged with where the main thread was while it did not answer.
@MainActor
final class StallDiagnosticsTests: XCTestCase {
    func testSampleNamesTheFunctionHoldingTheMainThread() {
        let mainThread = pthread_mach_thread_np(pthread_self())
        let sample = SampledStack()
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            Thread.sleep(forTimeInterval: 0.3)
            sample.lines = ThreadStack.describe(ThreadStack.returnAddresses(of: mainThread))
            release.signal()
        }
        holdTheMainThreadForTheStackTest(until: release)
        XCTAssertTrue(sample.lines.contains { $0.contains("holdTheMainThreadForTheStackTest") },
                      sample.lines.joined(separator: "\n"))
    }

    func testFreezeIsLoggedWithWhereTheMainThreadWas() async throws {
        HostHealth.startMainThreadWatchdog()
        try await Task.sleep(nanoseconds: 1_200_000_000)
        // A ping goes out up to a second into the freeze and is sampled two
        // seconds later, so the freeze has to outlast both.
        freezeTheMainThreadForTheWatchdogTest(seconds: 3.5)
        let deadline = Date().addingTimeInterval(6)
        var logged: [String: Any]?
        while logged == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            logged = stalls().last { event in
                (event["stack"] as? [String])?.contains { $0.contains("freezeTheMainThreadForTheWatchdogTest") } == true
            }
        }
        let event = try XCTUnwrap(logged, "The freeze must be logged with the frozen function: \(stalls())")
        XCTAssertGreaterThan(event["seconds"] as? Int ?? 0, 2)
    }

    private func stalls() -> [[String: Any]] {
        let text = (try? String(contentsOf: HostDiagnostics.logURL, encoding: .utf8)) ?? ""
        return text.split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .filter { $0["event"] as? String == "main_thread_stall" }
    }

    @inline(never)
    private func holdTheMainThreadForTheStackTest(until release: DispatchSemaphore) {
        _ = release.wait(timeout: .now() + 5)
    }

    @inline(never)
    private func freezeTheMainThreadForTheWatchdogTest(seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }
}

private final class SampledStack: @unchecked Sendable {
    var lines: [String] = []
}
