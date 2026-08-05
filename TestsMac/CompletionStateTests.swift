import Foundation
import XCTest
@testable import CodeAnywhereMac

final class CompletionStateTests: XCTestCase {
    private let baseline = Date(timeIntervalSince1970: 1_000)

    func testActiveThenTerminalCreatesOnePendingDelivery() throws {
        var state = CompletionMonitorState(baseline: baseline)
        CompletionDetector.observe(
            snapshots: [snapshot(id: "thread-1", updatedAt: 1_010, state: .active)],
            state: &state,
            now: Date(timeIntervalSince1970: 1_011)
        )
        XCTAssertNotNil(state.active["thread-1"])

        CompletionDetector.observe(
            snapshots: [snapshot(id: "thread-1", updatedAt: 1_020, state: .completed)],
            state: &state,
            now: Date(timeIntervalSince1970: 1_021)
        )

        let delivery = try XCTUnwrap(state.pending.values.first)
        XCTAssertEqual(state.pending.count, 1)
        XCTAssertNil(state.active["thread-1"])
        XCTAssertEqual(delivery.title, "Codex 已完成")
        XCTAssertEqual(delivery.deepLink, "codeanywhere://thread/thread-1")
    }

    func testTerminalUpdatedAfterBaselineIsCandidateWithoutActiveObservation() {
        var state = CompletionMonitorState(baseline: baseline)
        CompletionDetector.observe(
            snapshots: [snapshot(id: "thread-2", updatedAt: 1_001, state: .failed)],
            state: &state,
            now: Date(timeIntervalSince1970: 1_002)
        )
        XCTAssertEqual(state.pending.count, 1)
        XCTAssertEqual(state.pending.values.first?.title, "Codex 任务失败")
    }

    func testOldTerminalThreadDoesNotCreateCandidate() {
        var state = CompletionMonitorState(baseline: baseline)
        CompletionDetector.observe(
            snapshots: [snapshot(id: "old", updatedAt: 999, state: .completed)],
            state: &state,
            now: Date(timeIntervalSince1970: 1_010)
        )
        XCTAssertTrue(state.pending.isEmpty)
    }

    func testDeliveredEventIsNotCreatedAgain() throws {
        let terminal = snapshot(id: "thread-3", updatedAt: 1_100, state: .completed)
        var state = CompletionMonitorState(baseline: baseline)
        CompletionDetector.observe(snapshots: [terminal], state: &state, now: baseline)
        let eventID = try XCTUnwrap(state.pending.keys.first)
        CompletionDetector.markDelivered(eventID: eventID, state: &state, at: baseline)

        CompletionDetector.observe(snapshots: [terminal], state: &state, now: baseline)

        XCTAssertTrue(state.pending.isEmpty)
        XCTAssertEqual(state.delivered.count, 1)
    }

    func testStableEventIDAndDeepLinkEncoding() {
        let value = snapshot(id: "folder/thread ?", updatedAt: 1_100, state: .interrupted)
        XCTAssertEqual(CompletionDetector.stableEventID(for: value), CompletionDetector.stableEventID(for: value))
        XCTAssertEqual(CompletionDetector.deepLink(for: value.id), "codeanywhere://thread/folder%2Fthread%20%3F")
    }

    func testRetryPolicyStopsAfterBoundedAttempts() {
        let policy = DeliveryRetryPolicy(maximumAttempts: 3, initialDelay: 10, maximumDelay: 30)
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(policy.nextAttemptDate(afterAttempt: 1, now: now), Date(timeIntervalSince1970: 110))
        XCTAssertEqual(policy.nextAttemptDate(afterAttempt: 2, now: now), Date(timeIntervalSince1970: 120))
        XCTAssertNil(policy.nextAttemptDate(afterAttempt: 3, now: now))
    }

    func testFilePersistenceRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileCompletionStateStore(fileURL: directory.appendingPathComponent("state.json"))
        var state = CompletionMonitorState(baseline: baseline)
        state.active["thread"] = ActiveThreadObservation(firstObservedAt: baseline, latestUpdatedAt: baseline)

        try store.save(state)

        XCTAssertEqual(store.load(now: .distantFuture), state)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("state.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    private func snapshot(
        id: String,
        updatedAt: TimeInterval,
        state: MonitoredThreadState
    ) -> MonitoredThreadSnapshot {
        MonitoredThreadSnapshot(
            id: id,
            title: "测试对话",
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            state: state
        )
    }
}
