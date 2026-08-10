import Foundation

enum RemoteScheduledTaskError: LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "任务服务地址无效"
        case .invalidResponse: return "Mac 任务服务返回了无法识别的数据"
        case .server(let message): return message
        }
    }
}

extension ServerEndpoint {
    var scheduledTaskServiceURL: URL? {
        guard port < 65_535 else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        components.port = port + 1
        components.path = "/v1/tasks"
        return components.url
    }

    var runtimeInfoURL: URL? {
        scheduledTaskServiceURL?.deletingLastPathComponent().appendingPathComponent("info")
    }
}

@MainActor
final class RemoteScheduledTaskStore: ObservableObject {
    @Published private(set) var tasks: [ScheduledTask] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastUpdatedAt: Date?
    @Published private(set) var runtimeInfo: RemoteMacRuntimeInfo?

    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func refresh(endpoint: ServerEndpoint) async throws {
        isLoading = true
        defer { isLoading = false }
        let data = try await request(endpoint: endpoint, method: "GET")
        tasks = try decoder.decode([ScheduledTask].self, from: data)
        lastUpdatedAt = Date()
    }

    func refreshRuntimeInfo(endpoint: ServerEndpoint) async throws {
        guard let url = endpoint.runtimeInfoURL else {
            throw RemoteScheduledTaskError.invalidEndpoint
        }
        let data = try await request(url: url, method: "GET")
        runtimeInfo = try decoder.decode(RemoteMacRuntimeInfo.self, from: data)
    }

    func add(_ task: ScheduledTask, endpoint: ServerEndpoint) async throws {
        let data = try await request(
            endpoint: endpoint,
            method: "POST",
            body: try encoder.encode(task)
        )
        let saved = try decoder.decode(ScheduledTask.self, from: data)
        upsert(saved)
    }

    func update(_ task: ScheduledTask, endpoint: ServerEndpoint) async throws {
        let data = try await request(
            endpoint: endpoint,
            method: "PUT",
            pathComponent: task.id.uuidString.lowercased(),
            body: try encoder.encode(task)
        )
        let saved = try decoder.decode(ScheduledTask.self, from: data)
        upsert(saved)
    }

    func delete(id: UUID, endpoint: ServerEndpoint) async throws {
        _ = try await request(
            endpoint: endpoint,
            method: "DELETE",
            pathComponent: id.uuidString.lowercased()
        )
        tasks.removeAll { $0.id == id }
    }

    private func request(
        endpoint: ServerEndpoint,
        method: String,
        pathComponent: String? = nil,
        body: Data? = nil
    ) async throws -> Data {
        guard var url = endpoint.scheduledTaskServiceURL else {
            throw RemoteScheduledTaskError.invalidEndpoint
        }
        if let pathComponent {
            url.append(path: pathComponent)
        }
        return try await request(url: url, method: method, body: body)
    }

    private func request(
        url: URL,
        method: String,
        body: Data? = nil
    ) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.httpMethod = method
        request.setValue(
            "Bearer \(ServerEndpoint.internalCapabilityToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteScheduledTaskError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = object["error"] as? String {
                throw RemoteScheduledTaskError.server(message)
            }
            throw RemoteScheduledTaskError.server("任务服务请求失败（HTTP \(http.statusCode)）")
        }
        guard data.count <= 2 * 1_024 * 1_024 else {
            throw RemoteScheduledTaskError.invalidResponse
        }
        return data
    }

    private func upsert(_ task: ScheduledTask) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        } else {
            tasks.append(task)
        }
        tasks.sort {
            if $0.isEnabled != $1.isEnabled { return $0.isEnabled }
            return ($0.nextRunAt ?? .distantFuture) < ($1.nextRunAt ?? .distantFuture)
        }
        lastUpdatedAt = Date()
    }
}
