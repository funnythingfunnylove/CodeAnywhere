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

    func testCompletedTurnUpdatedAfterBaselineIsCandidateWithoutActiveObservation() {
        var state = CompletionMonitorState(baseline: baseline)
        CompletionDetector.observe(
            snapshots: [snapshot(id: "thread-2", updatedAt: 1_001, state: .completed)],
            state: &state,
            now: Date(timeIntervalSince1970: 1_002)
        )
        XCTAssertEqual(state.pending.count, 1)
        XCTAssertEqual(state.pending.values.first?.title, "Codex 已完成")
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
        XCTAssertEqual(state.notificationHistory.count, 1)
        XCTAssertEqual(state.notificationHistory.first?.threadID, terminal.id)
        XCTAssertEqual(state.notificationHistory.first?.deliveredAt, baseline)
    }

    func testOnlyCompletedStateCreatesPendingDelivery() {
        for terminalState in [MonitoredThreadState.failed, .interrupted] {
            var state = CompletionMonitorState(baseline: baseline)
            CompletionDetector.observe(
                snapshots: [snapshot(id: "thread-terminal", updatedAt: 1_010, state: .active)],
                state: &state,
                now: Date(timeIntervalSince1970: 1_011)
            )
            CompletionDetector.observe(
                snapshots: [snapshot(id: "thread-terminal", updatedAt: 1_020, state: terminalState)],
                state: &state,
                now: Date(timeIntervalSince1970: 1_021)
            )

            XCTAssertTrue(state.pending.isEmpty, "\(terminalState) must not trigger Bark delivery")
        }
    }

    func testCompletedStateCannotNotifyAgainWithoutAnotherActiveTransition() throws {
        var state = CompletionMonitorState(baseline: baseline)
        CompletionDetector.observe(
            snapshots: [snapshot(id: "thread-repeat", updatedAt: 1_010, state: .active)],
            state: &state,
            now: Date(timeIntervalSince1970: 1_011)
        )
        CompletionDetector.observe(
            snapshots: [snapshot(id: "thread-repeat", updatedAt: 1_020, state: .completed)],
            state: &state,
            now: Date(timeIntervalSince1970: 1_021)
        )
        let firstEventID = try XCTUnwrap(state.pending.keys.first)
        CompletionDetector.markDelivered(eventID: firstEventID, state: &state, at: baseline)

        CompletionDetector.observe(
            snapshots: [snapshot(id: "thread-repeat", updatedAt: 1_030, state: .completed)],
            state: &state,
            now: Date(timeIntervalSince1970: 1_031)
        )

        XCTAssertTrue(state.pending.isEmpty)
        XCTAssertEqual(state.notificationHistory.count, 1)
    }

    func testClearNotificationHistoryKeepsPendingDeliveries() throws {
        let terminal = snapshot(id: "thread-clear", updatedAt: 1_100, state: .completed)
        var state = CompletionMonitorState(baseline: baseline)
        CompletionDetector.observe(snapshots: [terminal], state: &state, now: baseline)
        let eventID = try XCTUnwrap(state.pending.keys.first)
        CompletionDetector.markDelivered(eventID: eventID, state: &state, at: baseline)
        CompletionDetector.observe(
            snapshots: [snapshot(id: "thread-pending", updatedAt: 1_200, state: .completed)],
            state: &state,
            now: baseline
        )

        CompletionDetector.clearNotificationHistory(state: &state)

        XCTAssertTrue(state.notificationHistory.isEmpty)
        XCTAssertEqual(state.delivered.count, 1)
        XCTAssertEqual(state.pending.count, 1)

        CompletionDetector.observe(snapshots: [terminal], state: &state, now: baseline)
        XCTAssertEqual(state.pending.count, 1)
    }

    func testStableEventIDAndDeepLinkEncoding() {
        let value = snapshot(id: "folder/thread ?", updatedAt: 1_100, state: .interrupted)
        XCTAssertEqual(CompletionDetector.stableEventID(for: value), CompletionDetector.stableEventID(for: value))
        XCTAssertLessThanOrEqual(CompletionDetector.stableEventID(for: value).utf8.count, 64)
        XCTAssertEqual(CompletionDetector.deepLink(for: value.id), "codeanywhere://thread/folder%2Fthread%20%3F")
    }

    func testStableEventIDUsesTurnIdentityInsteadOfThreadTimestamp() {
        let first = snapshot(
            id: "thread-stable",
            updatedAt: 1_100,
            state: .completed,
            turnID: "turn-1"
        )
        let timestampOnlyUpdate = snapshot(
            id: "thread-stable",
            updatedAt: 1_200,
            state: .completed,
            turnID: "turn-1"
        )
        let nextTurn = snapshot(
            id: "thread-stable",
            updatedAt: 1_300,
            state: .completed,
            turnID: "turn-2"
        )

        XCTAssertEqual(
            CompletionDetector.stableEventID(for: first),
            CompletionDetector.stableEventID(for: timestampOnlyUpdate)
        )
        XCTAssertNotEqual(
            CompletionDetector.stableEventID(for: first),
            CompletionDetector.stableEventID(for: nextTurn)
        )
    }

    func testThreadSnapshotUsesLatestTurnIdentityAndStatus() throws {
        let snapshot = try XCTUnwrap(MonitoredThreadSnapshot(json: .object([
            "id": .string("thread-detail"),
            "name": .string("详情测试"),
            "updatedAt": .number(1_100_000),
            "status": .object(["type": .string("idle")]),
            "turns": .array([
                .object([
                    "id": .string("turn-old"),
                    "status": .string("completed")
                ]),
                .object([
                    "id": .string("turn-current"),
                    "status": .string("inProgress")
                ])
            ])
        ])))

        XCTAssertEqual(snapshot.turnID, "turn-current")
        XCTAssertEqual(snapshot.state, .active)
    }

    func testTurnCompletedNotificationParsesServerEvent() throws {
        let data = Data(#"""
        {
            "method":"turn/completed",
            "params":{
                "threadId":"thread-event",
                "turn":{"id":"turn-event","status":"completed","items":[]}
            }
        }
        """#.utf8)

        XCTAssertEqual(
            MacCodexServerEventParser.parse(data: data),
            .turnCompleted(
                MacCodexTurnCompletedEvent(threadID: "thread-event", turnID: "turn-event")
            )
        )
    }

    func testMacWebSocketAllowsLargeThreadResponses() {
        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:4500/")!)

        MacCodexWebSocketConfiguration.apply(to: task)

        XCTAssertEqual(task.maximumMessageSize, 32 * 1_024 * 1_024)
        XCTAssertGreaterThan(task.maximumMessageSize, 2 * 1_024 * 1_024)
    }

    func testNonCompletedServerNotificationIsIgnored() {
        let data = Data(#"{"method":"turn/completed","params":{"threadId":"thread-event","turn":{"id":"turn-event","status":"failed","items":[]}}}"#.utf8)
        XCTAssertNil(MacCodexServerEventParser.parse(data: data))
    }

    func testMacVersionDisplayIncludesMarketingVersionAndBuild() {
        XCTAssertEqual(
            MacAppVersion.formatted(shortVersion: "0.1.1", build: "3"),
            "版本 0.1.1（3）"
        )
    }

    @MainActor
    func testMacAppStaysAliveAfterLastWindowCloses() {
        let delegate = CodeAnywhereMacApplicationDelegate()
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    func testRetryPolicyStopsAfterBoundedAttempts() {
        let policy = DeliveryRetryPolicy(maximumAttempts: 3, initialDelay: 10, maximumDelay: 30)
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(policy.nextAttemptDate(afterAttempt: 1, now: now), Date(timeIntervalSince1970: 110))
        XCTAssertEqual(policy.nextAttemptDate(afterAttempt: 2, now: now), Date(timeIntervalSince1970: 120))
        XCTAssertNil(policy.nextAttemptDate(afterAttempt: 3, now: now))
        XCTAssertNil(policy.nextAttemptDate(afterAttempt: 100, now: now))
    }

    func testPrepareForMonitoringCoalescesWithoutReactivatingExhaustedDeliveries() throws {
        let first = snapshot(id: "thread-1", updatedAt: 1_010, state: .completed, turnID: "turn-1")
        let latest = snapshot(id: "thread-1", updatedAt: 1_020, state: .completed, turnID: "turn-2")
        let other = snapshot(id: "thread-2", updatedAt: 1_015, state: .completed)
        var state = CompletionMonitorState(baseline: baseline)
        CompletionDetector.observe(snapshots: [first], state: &state, now: baseline)
        CompletionDetector.observe(snapshots: [latest, other], state: &state, now: baseline)
        XCTAssertEqual(state.pending.count, 3)

        for id in state.pending.keys {
            state.pending[id]?.attempts = 5
            state.pending[id]?.nextAttemptAt = .distantFuture
        }
        let retryAt = Date(timeIntervalSince1970: 2_000)
        CompletionDetector.prepareForMonitoring(
            state: &state,
            now: retryAt,
            maximumAttempts: 5
        )

        XCTAssertEqual(state.pending.count, 2)
        let threadOne = try XCTUnwrap(state.pending.values.first { $0.threadID == "thread-1" })
        XCTAssertEqual(threadOne.threadUpdatedAt, latest.updatedAt)
        XCTAssertEqual(threadOne.attempts, 5)
        XCTAssertEqual(threadOne.nextAttemptAt, .distantFuture)
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

    @MainActor
    func testMonitorReadsLatestTurnAndDeliversSameCompletedTurnOnlyOnce() async throws {
        let persistence = InMemoryCompletionStateStore(
            state: CompletionMonitorState(baseline: baseline)
        )
        let sender = RecordingBarkSender()
        let client = RepeatingCompletedTurnClient()
        let monitor = CompletionMonitor(
            persistence: persistence,
            deviceKeyStore: FixedDeviceKeyStore(),
            barkSender: sender,
            now: baseline,
            clientFactory: { _ in client }
        )
        defer { monitor.stop() }

        monitor.start(port: 4_500)
        try await waitUntil(timeout: 2) { await sender.count == 1 }
        for _ in 0..<3 {
            monitor.pollNow()
            try await Task.sleep(for: .milliseconds(100))
        }

        let deliveryCount = await sender.count
        let methods = await client.recordedMethods
        XCTAssertEqual(deliveryCount, 1)
        XCTAssertGreaterThanOrEqual(methods.filter { $0 == "thread/read" }.count, 2)
        XCTAssertEqual(monitor.notificationHistory.count, 1)
    }

    @MainActor
    func testMonitorDeliversTurnCompletedServerEvent() async throws {
        let persistence = InMemoryCompletionStateStore(
            state: CompletionMonitorState(baseline: baseline)
        )
        let sender = SlowRecordingBarkSender()
        let client = EventingCompletionClient()
        let monitor = CompletionMonitor(
            persistence: persistence,
            deviceKeyStore: FixedDeviceKeyStore(),
            barkSender: sender,
            now: baseline,
            clientFactory: { _ in client }
        )
        defer { monitor.stop() }

        monitor.start(port: 4_500)
        try await waitUntil(timeout: 2) { await client.hasEventHandler }
        await client.emit(
            .turnCompleted(
                MacCodexTurnCompletedEvent(threadID: "thread-event", turnID: "turn-event")
            )
        )

        try await waitUntil(timeout: 2) { await sender.count == 1 }
        await client.emit(
            .turnCompleted(
                MacCodexTurnCompletedEvent(threadID: "thread-event", turnID: "turn-event")
            )
        )
        try await Task.sleep(for: .milliseconds(50))
        let inFlightDeliveryCount = await sender.count
        XCTAssertEqual(inFlightDeliveryCount, 1)
        try await waitUntil(timeout: 2) { monitor.notificationHistory.count == 1 }
        let deliveryCount = await sender.count
        XCTAssertEqual(deliveryCount, 1)
        XCTAssertEqual(monitor.notificationHistory.first?.threadID, "thread-event")
    }

    private func snapshot(
        id: String,
        updatedAt: TimeInterval,
        state: MonitoredThreadState,
        turnID: String? = nil
    ) -> MonitoredThreadSnapshot {
        MonitoredThreadSnapshot(
            id: id,
            title: "测试对话",
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            state: state,
            turnID: turnID ?? "\(id)-turn"
        )
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("等待异步条件超时")
    }
}

private final class InMemoryCompletionStateStore: CompletionStatePersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var state: CompletionMonitorState

    init(state: CompletionMonitorState) {
        self.state = state
    }

    func load(now: Date) -> CompletionMonitorState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func save(_ state: CompletionMonitorState) throws {
        lock.lock()
        defer { lock.unlock() }
        self.state = state
    }
}

private struct FixedDeviceKeyStore: DeviceKeyStoring, Sendable {
    func read() throws -> String? { "test-device" }
    func save(_ key: String) throws {}
    func delete() throws {}
}

private actor RecordingBarkSender: BarkSending {
    private(set) var count = 0

    func send(
        _ notification: BarkNotification,
        deviceKey: String,
        serverURL: String
    ) async throws {
        count += 1
    }
}

private actor SlowRecordingBarkSender: BarkSending {
    private(set) var count = 0

    func send(
        _ notification: BarkNotification,
        deviceKey: String,
        serverURL: String
    ) async throws {
        count += 1
        try await Task.sleep(for: .milliseconds(150))
    }
}

private actor RepeatingCompletedTurnClient: MacCodexClientProtocol {
    private var updatedAt = 1_010
    private(set) var recordedMethods: [String] = []

    func connect() async throws {}
    func disconnect() async {}

    func call(method: String, params: [String: MacJSONValue]) async throws -> MacJSONValue {
        recordedMethods.append(method)
        switch method {
        case "thread/list":
            guard params["archived"]?.boolValue == false else {
                return .object(["data": .array([])])
            }
            updatedAt += 10
            return .object([
                "data": .array([threadJSON(includeTurns: false)])
            ])
        case "thread/read":
            return .object(["thread": threadJSON(includeTurns: true)])
        default:
            throw MacCodexClientError.server(code: -1, message: "unexpected method")
        }
    }

    private func threadJSON(includeTurns: Bool) -> MacJSONValue {
        .object([
            "id": .string("thread-repeat"),
            "name": .string("重复完成测试"),
            "updatedAt": .number(Double(updatedAt)),
            "status": .object(["type": .string("idle")]),
            "turns": includeTurns
                ? .array([.object([
                    "id": .string("turn-stable"),
                    "status": .string("completed")
                ])])
                : .array([])
        ])
    }
}

private actor EventingCompletionClient: MacCodexClientProtocol {
    private var eventHandler: (@Sendable (MacCodexServerEvent) -> Void)?

    var hasEventHandler: Bool { eventHandler != nil }

    func connect() async throws {}
    func disconnect() async {}

    func call(method: String, params: [String: MacJSONValue]) async throws -> MacJSONValue {
        switch method {
        case "thread/list":
            return .object(["data": .array([])])
        case "thread/read":
            return .object(["thread": .object([
                "id": .string("thread-event"),
                "name": .string("事件完成测试"),
                "updatedAt": .number(1_010_000),
                "turns": .array([.object([
                    "id": .string("turn-event"),
                    "status": .string("completed")
                ])])
            ])])
        default:
            throw MacCodexClientError.server(code: -1, message: "unexpected method")
        }
    }

    func setEventHandler(_ handler: (@Sendable (MacCodexServerEvent) -> Void)?) async {
        eventHandler = handler
    }

    func emit(_ event: MacCodexServerEvent) {
        eventHandler?(event)
    }
}
