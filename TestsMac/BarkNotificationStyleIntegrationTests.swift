import Foundation
import XCTest
@testable import CodeAnywhereMac

final class BarkNotificationStyleIntegrationTests: XCTestCase {
    @MainActor
    func testCompletionMonitorSendsConfiguredFormatAndStyle() async throws {
        let completedAt = Date(timeIntervalSince1970: 1_786_000_000)
        let delivery = PendingCompletionDelivery(
            id: "turn-style",
            threadID: "thread-style",
            title: "Codex 已完成",
            body: "Mac UI 重构",
            group: "CodeAnywhere",
            deepLink: "codeanywhere://thread/thread-style",
            terminalState: .completed,
            threadUpdatedAt: completedAt,
            attempts: 0,
            nextAttemptAt: .distantPast
        )
        let persistence = StyleTestStateStore(
            state: CompletionMonitorState(
                baseline: completedAt,
                pending: [delivery.id: delivery]
            )
        )
        let sender = StyleRecordingBarkSender()
        let client = EmptyThreadClient()
        let monitor = CompletionMonitor(
            persistence: persistence,
            deviceKeyStore: StyleTestDeviceKeyStore(),
            barkSender: sender,
            now: completedAt,
            clientFactory: { _ in client }
        )
        monitor.notificationStyle = BarkNotificationStyle(
            titleTemplate: "{status}",
            subtitleTemplate: "{thread}",
            bodyTemplate: "**{thread}** 已完成",
            group: "Codex Tasks",
            level: .timeSensitive,
            criticalVolume: 5,
            sound: "minuet",
            icon: "https://example.com/icon.png",
            usesMarkdown: true
        )
        defer { monitor.stop() }

        monitor.start(port: 4_500)
        let deadline = Date().addingTimeInterval(2)
        while await sender.notification == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        let recordedNotification = await sender.notification
        let notification = try XCTUnwrap(recordedNotification)
        XCTAssertEqual(notification.title, "Codex 已完成")
        XCTAssertEqual(notification.subtitle, "Mac UI 重构")
        XCTAssertEqual(notification.body, "**Mac UI 重构** 已完成")
        XCTAssertEqual(notification.group, "Codex Tasks")
        XCTAssertEqual(notification.level, .timeSensitive)
        XCTAssertEqual(notification.sound, "minuet")
        XCTAssertEqual(notification.icon, "https://example.com/icon.png")
        XCTAssertTrue(notification.usesMarkdown)
    }
}

private final class StyleTestStateStore: CompletionStatePersisting, @unchecked Sendable {
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

private struct StyleTestDeviceKeyStore: DeviceKeyStoring, Sendable {
    func read() throws -> String? { "test-device" }
    func save(_ key: String) throws {}
    func delete() throws {}
}

private actor StyleRecordingBarkSender: BarkSending {
    private(set) var notification: BarkNotification?

    func send(
        _ notification: BarkNotification,
        deviceKey: String,
        serverURL: String
    ) async throws {
        self.notification = notification
    }
}

private actor EmptyThreadClient: MacCodexClientProtocol {
    func connect() async throws {}
    func disconnect() async {}

    func call(method: String, params: [String: MacJSONValue]) async throws -> MacJSONValue {
        .object(["data": .array([])])
    }
}
