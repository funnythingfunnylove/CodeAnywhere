import Foundation

enum ThreadTurnStarter {
    static func start(
        threadID: String,
        params: [String: JSONValue],
        resumeThread: Bool = true,
        call: @Sendable (String, [String: JSONValue]) async throws -> JSONValue
    ) async throws {
        if resumeThread {
            _ = try await call("thread/resume", ["threadId": .string(threadID)])
        }
        _ = try await call("turn/start", params)
    }
}
