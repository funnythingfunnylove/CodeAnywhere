import CodeAnywhereCore
import Foundation
import XCTest

final class CodeAnywhereCoreTests: XCTestCase {
    func testConfigurationDefaultsAndValidation() throws {
        let configuration = try CodeAnywhereConfiguration().validated()
        XCTAssertEqual(configuration.server.port, 4_500)
        XCTAssertEqual(configuration.server.bind, "0.0.0.0")
        XCTAssertFalse(configuration.bark.enabled)
        XCTAssertTrue(configuration.resolvedStateURL().path.contains("completion-state.json"))
    }

    func testConfigurationRejectsInlineLikeBarkKeyConfiguration() {
        var configuration = CodeAnywhereConfiguration()
        configuration.bark.enabled = true
        configuration.bark.deviceKeyEnv = ""
        XCTAssertThrowsError(try configuration.validated()) { error in
            XCTAssertEqual(error as? ConfigurationError, .invalidBarkConfiguration)
        }
    }

    func testConfigurationRejectsInvalidRuntimeValues() {
        var configuration = CodeAnywhereConfiguration()
        configuration.server.token = "\n"
        XCTAssertThrowsError(try configuration.validated()) { error in
            XCTAssertEqual(error as? ConfigurationError, .invalidToken)
        }

        configuration.server.token = "test-token"
        configuration.monitor.maximumDeliveryAttempts = 0
        XCTAssertThrowsError(try configuration.validated()) { error in
            XCTAssertEqual(error as? ConfigurationError, .invalidMaximumDeliveryAttempts(0))
        }
    }

    func testApprovalRequestsAreAutomaticallyAccepted() {
        let request = JSONValue.object([
            "id": .string("approval-1"),
            "method": .string("item/commandExecution/requestApproval"),
            "params": .object([:])
        ])
        let response = CodexAutomaticServerRequestResponder.response(for: request)
        XCTAssertEqual(response?["id"]?.stringValue, "approval-1")
        XCTAssertEqual(response?["result"]?["decision"]?.stringValue, "accept")
    }

    func testInterruptedTurnDoesNotCreateCompletionEvent() {
        let message = JSONValue.object([
            "method": .string("turn/completed"),
            "params": .object([
                "threadId": .string("thread-1"),
                "turn": .object([
                    "id": .string("turn-1"),
                    "status": .string("interrupted")
                ])
            ])
        ])
        XCTAssertNil(CodexServerEventParser.parse(message))
    }

    func testCompletionDetectorUsesTurnIDForDedupe() throws {
        let snapshot = try XCTUnwrap(MonitoredThreadSnapshot(json: .object([
            "id": .string("thread-1"),
            "name": .string("测试任务"),
            "updatedAt": .number(2_000_000_000),
            "turns": .array([.object([
                "id": .string("turn-1"),
                "status": .string("completed")
            ])])
        ])))
        var state = CompletionState(baseline: Date(timeIntervalSince1970: 1_000_000_000))
        CompletionDetector.observe(snapshots: [snapshot], state: &state, now: Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertEqual(state.pending.count, 1)
        CompletionDetector.observe(snapshots: [snapshot], state: &state, now: Date(timeIntervalSince1970: 2_000_000_001))
        XCTAssertEqual(state.pending.count, 1)
    }

    func testStateStoreUsesPrivateFilePermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("state.json")
        let store = FileCompletionStateStore(url: url)
        try store.save(CompletionState())
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testProcessSupervisorStopsOwnedProcessAndRemovesCapabilityToken() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("fake-codex")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        var server = ServerConfiguration(executable: executable.path, bind: "127.0.0.1", port: 45_001)
        server.token = "test-token"
        let supervisor = CodexProcessSupervisor()
        _ = try supervisor.start(configuration: server)
        let tokenURL = try XCTUnwrap(supervisor.tokenFileURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: tokenURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertTrue(supervisor.isRunning)

        supervisor.stop()

        XCTAssertFalse(supervisor.isRunning)
        XCTAssertNil(supervisor.pid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tokenURL.path))
    }

    func testProcessSupervisorReportsOwnedPidAndStopIsIdempotent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("fake-codex")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        var server = ServerConfiguration(executable: executable.path, bind: "127.0.0.1", port: 45_002)
        server.token = "test-token"
        let supervisor = CodexProcessSupervisor()
        let pid = try supervisor.start(configuration: server)
        XCTAssertEqual(supervisor.pid, pid)
        XCTAssertTrue(pid > 0)
        let tokenURL = try XCTUnwrap(supervisor.tokenFileURL)

        supervisor.stop()
        supervisor.stop() // second stop must be a no-op, not a crash

        XCTAssertFalse(supervisor.isRunning)
        XCTAssertNil(supervisor.pid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tokenURL.path))
    }

#if os(Linux)
    func testProcessSupervisorEscalatesToSIGKILLWhenTerminateIgnored() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // A child that ignores SIGTERM must still be stopped via SIGKILL.
        let executable = directory.appendingPathComponent("stubborn-codex")
        try Data("#!/bin/sh\ntrap '' TERM INT\nexec /bin/sleep 30\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        var server = ServerConfiguration(executable: executable.path, bind: "127.0.0.1", port: 45_003)
        server.token = "test-token"
        let supervisor = CodexProcessSupervisor()
        let pid = try supervisor.start(configuration: server)
        let tokenURL = try XCTUnwrap(supervisor.tokenFileURL)

        supervisor.stop()

        XCTAssertFalse(supervisor.isRunning)
        XCTAssertNil(supervisor.pid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tokenURL.path))
        // The SIGKILL fallback must reap the child even though it ignored SIGTERM.
        XCTAssertEqual(kill(pid, 0), -1)
    }
#endif

    func testProcessSupervisorCleansUpStaleTokenFilesFromDeadOwners() throws {
        let runtimeDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/codeanywhere/runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        // A PID that is guaranteed to be dead on this machine.
        let marker = Process()
        marker.executableURL = URL(fileURLWithPath: "/bin/sleep")
        marker.arguments = ["0"]
        try marker.run()
        let deadPID = marker.processIdentifier
        marker.waitUntilExit()

        let staleURL = runtimeDirectory.appendingPathComponent("capability-\(deadPID)-\(UUID().uuidString).token")
        try Data("stale".utf8).write(to: staleURL)
        defer { try? FileManager.default.removeItem(at: staleURL) }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-codex")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        var server = ServerConfiguration(executable: executable.path, bind: "127.0.0.1", port: 45_004)
        server.token = "test-token"
        let supervisor = CodexProcessSupervisor()
        _ = try supervisor.start(configuration: server)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleURL.path))
        supervisor.stop()
    }
}
