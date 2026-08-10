import Darwin
import Foundation
import Network
import XCTest
@testable import CodeAnywhereMac

final class ScheduledTasksTests: XCTestCase {
    @MainActor
    func testCatalogPersistsAndClaimsOneTimeTaskOnlyOnce() throws {
        let suiteName = "CodeAnywhereMacTests.ScheduledTasks.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let runAt = now.addingTimeInterval(60)
        let task = ScheduledTask(
            title: "单次任务",
            prompt: "检查项目",
            cwd: "/tmp/project",
            schedule: .once(at: runAt)
        )
        let catalog = ScheduledTaskCatalog(defaults: defaults, storageKey: "tasks")

        catalog.add(task, now: now)
        XCTAssertEqual(catalog.task(id: task.id)?.nextRunAt, runAt)
        XCTAssertTrue(catalog.claimDueTasks(at: now).isEmpty)

        let claimed = catalog.claimDueTasks(at: runAt)
        XCTAssertEqual(claimed.map(\.id), [task.id])
        XCTAssertEqual(catalog.task(id: task.id)?.executionState, .running)
        XCTAssertFalse(catalog.task(id: task.id)?.isEnabled == true)
        XCTAssertTrue(catalog.claimDueTasks(at: runAt.addingTimeInterval(60)).isEmpty)

        catalog.recordSuccess(id: task.id, message: "已创建对话")
        let restored = ScheduledTaskCatalog(defaults: defaults, storageKey: "tasks")
        XCTAssertEqual(restored.task(id: task.id)?.executionState, .succeeded)
        XCTAssertEqual(restored.task(id: task.id)?.executionMessage, "已创建对话")
    }

    @MainActor
    func testCatalogRecomputesScheduleWhenDefinitionChanges() throws {
        let suiteName = "CodeAnywhereMacTests.ScheduledTaskEdit.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let catalog = ScheduledTaskCatalog(defaults: defaults, storageKey: "tasks")
        var task = ScheduledTask(
            title: "间隔任务",
            prompt: "检查项目",
            cwd: "/tmp/project",
            schedule: .interval(minutes: 5)
        )
        catalog.add(task, now: now)
        XCTAssertEqual(catalog.task(id: task.id)?.nextRunAt, now.addingTimeInterval(300))

        task.schedule = .interval(minutes: 10)
        XCTAssertTrue(catalog.replace(task, now: now))
        XCTAssertEqual(catalog.task(id: task.id)?.nextRunAt, now.addingTimeInterval(600))
    }

    @MainActor
    func testScheduledExecutionStartsThreadThenTurnWithFullAccess() async throws {
        let client = RecordingScheduledTaskClient()
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("state.json")
        let monitor = CompletionMonitor(
            persistence: FileCompletionStateStore(fileURL: stateURL),
            now: Date(timeIntervalSince1970: 1_000),
            clientFactory: { _ in client }
        )
        defer {
            monitor.stop()
            try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent())
        }
        monitor.start(port: 4_500)
        let task = ScheduledTask(
            title: "每日检查",
            prompt: "运行测试并汇报",
            cwd: "/tmp/project",
            modelID: "gpt-5",
            reasoningEffort: "high",
            schedule: .interval(minutes: 60)
        )

        let threadID = try await monitor.executeScheduledTask(task)
        XCTAssertEqual(threadID, "scheduled-thread")
        let calls = await client.calls
        guard let threadStart = calls.first(where: { $0.method == "thread/start" }),
              let turnStart = calls.first(where: { $0.method == "turn/start" }) else {
            return XCTFail("缺少 thread/start 或 turn/start")
        }
        XCTAssertEqual(threadStart.params["cwd"]?.stringValue, "/tmp/project")
        XCTAssertEqual(threadStart.params["approvalPolicy"]?.stringValue, "never")
        XCTAssertEqual(threadStart.params["sandbox"]?.stringValue, "danger-full-access")
        XCTAssertEqual(turnStart.params["threadId"]?.stringValue, "scheduled-thread")
        XCTAssertEqual(turnStart.params["approvalPolicy"]?.stringValue, "never")
        XCTAssertEqual(turnStart.params["sandboxPolicy"]?["type"]?.stringValue, "dangerFullAccess")
        XCTAssertEqual(turnStart.params["effort"]?.stringValue, "high")
    }

    @MainActor
    func testTaskServiceRequiresBearerAndServesCRUD() async throws {
        let suiteName = "CodeAnywhereMacTests.ScheduledTaskHTTP.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let catalog = ScheduledTaskCatalog(defaults: defaults, storageKey: "tasks")
        let service = ScheduledTaskService(catalog: catalog)
        let port = try Self.unusedLoopbackPort()
        try service.start(port: port)
        defer { service.stop() }
        for _ in 0..<50 where !service.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(service.isRunning)

        let task = ScheduledTask(
            title: "HTTP 任务",
            prompt: "通过接口创建",
            cwd: "/tmp/project",
            schedule: .interval(minutes: 15)
        )
        let baseURL = URL(string: "http://127.0.0.1:\(port)/v1/tasks")!
        let unauthorized = try await Self.request(url: baseURL, method: "GET", token: "wrong")
        XCTAssertEqual(unauthorized.0, 401)

        let created = try await Self.request(
            url: baseURL,
            method: "POST",
            token: MacServerAuthentication.capabilityToken,
            body: try JSONEncoder().encode(task)
        )
        XCTAssertEqual(created.0, 201)
        XCTAssertEqual(try JSONDecoder().decode(ScheduledTask.self, from: created.1).id, task.id)

        var edited = task
        edited.title = "已修改"
        edited.isEnabled = false
        let updated = try await Self.request(
            url: baseURL.appending(path: task.id.uuidString),
            method: "PUT",
            token: MacServerAuthentication.capabilityToken,
            body: try JSONEncoder().encode(edited)
        )
        XCTAssertEqual(updated.0, 200)
        XCTAssertEqual(try JSONDecoder().decode(ScheduledTask.self, from: updated.1).title, "已修改")

        let deleted = try await Self.request(
            url: baseURL.appending(path: task.id.uuidString),
            method: "DELETE",
            token: MacServerAuthentication.capabilityToken
        )
        XCTAssertEqual(deleted.0, 204)
        let listed = try await Self.request(url: baseURL, method: "GET", token: MacServerAuthentication.capabilityToken)
        XCTAssertEqual(try JSONDecoder().decode([ScheduledTask].self, from: listed.1), [])
    }

    private static func request(
        url: URL,
        method: String,
        token: String,
        body: Data? = nil
    ) async throws -> (Int, Data) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (try XCTUnwrap((response as? HTTPURLResponse)?.statusCode), data)
    }

    private static func unusedLoopbackPort() throws -> Int {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL) }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

private actor RecordingScheduledTaskClient: MacCodexClientProtocol {
    struct Call: Sendable {
        let method: String
        let params: [String: MacJSONValue]
    }

    private(set) var calls: [Call] = []

    func connect() async throws {}
    func disconnect() async {}

    func call(method: String, params: [String: MacJSONValue]) async throws -> MacJSONValue {
        calls.append(Call(method: method, params: params))
        switch method {
        case "thread/start":
            return .object(["thread": .object(["id": .string("scheduled-thread")])])
        case "turn/start":
            return .object([:])
        case "thread/list":
            return .object(["data": .array([])])
        default:
            throw MacCodexClientError.server(code: -1, message: "unexpected method")
        }
    }
}
