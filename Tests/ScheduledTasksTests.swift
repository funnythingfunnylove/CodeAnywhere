import XCTest
@testable import CodeAnywhere

final class ScheduledTasksTests: XCTestCase {
    func testCronSupportsStepsRangesAndWeekdayAliases() throws {
        let expression = try CronExpression("*/15 9-10 * * 1-5")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 10, hour: 8, minute: 59
        ))!

        let next = try XCTUnwrap(expression.nextDate(after: start, calendar: calendar))
        XCTAssertEqual(calendar.component(.hour, from: next), 9)
        XCTAssertEqual(calendar.component(.minute, from: next), 0)

        let sunday = try CronExpression("0 0 * * 7")
        let saturday = calendar.date(from: DateComponents(year: 2026, month: 8, day: 8, hour: 23, minute: 59))!
        let sundayNext = try XCTUnwrap(sunday.nextDate(after: saturday, calendar: calendar))
        XCTAssertEqual(calendar.component(.weekday, from: sundayNext), 1)
    }

    func testCronRejectsMalformedExpression() {
        XCTAssertThrowsError(try CronExpression("0 9 * *"))
        XCTAssertThrowsError(try CronExpression("0 25 * * *"))
        XCTAssertThrowsError(try CronExpression("*/0 * * * *"))
    }

    func testRemoteTaskServiceURLUsesAdjacentMacPort() throws {
        let endpoint = ServerEndpoint(host: "192.168.1.2", port: 4500)
        XCTAssertEqual(endpoint.scheduledTaskServiceURL?.absoluteString, "http://192.168.1.2:4501/v1/tasks")
        XCTAssertNil(ServerEndpoint(host: "192.168.1.2", port: 65_535).scheduledTaskServiceURL)
    }

    @MainActor
    func testRemoteStoreDecodesAndMutatesCRUDResponses() async throws {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ScheduledTaskURLProtocol.self]
        let store = RemoteScheduledTaskStore(session: URLSession(configuration: sessionConfiguration))
        let task = ScheduledTask(
            title: "测试",
            prompt: "执行测试",
            cwd: "/tmp/project",
            schedule: .interval(minutes: 5)
        )
        ScheduledTaskURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(ServerEndpoint.internalCapabilityToken)")
            switch request.httpMethod {
            case "GET":
                return (200, try JSONEncoder().encode([task]))
            case "POST", "PUT":
                return (200, try JSONEncoder().encode(task))
            case "DELETE":
                return (204, Data())
            default:
                return (405, Data())
            }
        }
        defer { ScheduledTaskURLProtocol.handler = nil }

        let endpoint = ServerEndpoint(host: "127.0.0.1", port: 4500)
        try await store.refresh(endpoint: endpoint)
        XCTAssertEqual(store.tasks, [task])
        try await store.update(task, endpoint: endpoint)
        try await store.delete(id: task.id, endpoint: endpoint)
        XCTAssertTrue(store.tasks.isEmpty)
    }
}

private final class ScheduledTaskURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (status, data) = try Self.handler?(request) ?? (500, Data())
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
