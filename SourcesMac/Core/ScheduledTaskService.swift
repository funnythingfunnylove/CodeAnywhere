import Foundation
import Network

@MainActor
final class ScheduledTaskService: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var port: Int?
    @Published private(set) var lastError: String?

    let catalog: ScheduledTaskCatalog
    var codeAnywhereVersion = MacAppVersion.display
    var codexVersion = "未检测"
    var appServerPort: Int?
    var operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
    var architecture: String {
#if arch(arm64)
        return "Apple Silicon (arm64)"
#elseif arch(x86_64)
        return "Intel (x86_64)"
#else
        return "未知架构"
#endif
    }
    private var listener: NWListener?

    init(catalog: ScheduledTaskCatalog) {
        self.catalog = catalog
    }

    func start(port: Int) throws {
        guard (1...65_535).contains(port) else {
            throw ScheduledTaskServiceError.invalidPort
        }
        guard listener == nil else { return }
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: UInt16(port))!)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isRunning = true
                    self.lastError = nil
                case .failed(let error):
                    self.isRunning = false
                    self.lastError = error.localizedDescription
                    self.listener?.cancel()
                    self.listener = nil
                case .cancelled:
                    self.isRunning = false
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global(qos: .utility))
            self?.receive(connection: connection, buffer: Data())
        }
        self.listener = listener
        self.port = port
        listener.start(queue: .global(qos: .utility))
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        port = nil
    }

    private nonisolated func receive(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 2 * 1_024 * 1_024) { [weak self] data, _, isComplete, error in
            var combined = buffer
            if let data { combined.append(data) }
            if let request = HTTPTaskRequest(data: combined) {
                Task { @MainActor [weak self] in
                    await self?.handle(request, connection: connection)
                }
                return
            }
            if isComplete || error != nil || combined.count >= 2 * 1_024 * 1_024 {
                connection.cancel()
                return
            }
            self?.receive(connection: connection, buffer: combined)
        }
    }

    private func handle(_ request: HTTPTaskRequest, connection: NWConnection) async {
        guard request.headers["authorization"] == "Bearer \(MacServerAuthentication.capabilityToken)" else {
            send(status: 401, body: ["error": "未授权的任务服务请求"], on: connection)
            return
        }
        do {
            let response: (Int, Data)
            switch (request.method, request.pathComponents.count) {
            case ("GET", 2) where request.pathComponents == ["v1", "info"]:
                let info = RemoteMacRuntimeInfo(
                    codeAnywhereVersion: codeAnywhereVersion,
                    codexVersion: codexVersion,
                    operatingSystem: operatingSystem,
                    architecture: architecture,
                    appServerPort: appServerPort,
                    taskServicePort: port
                )
                response = (200, try JSONEncoder().encode(info))
            case ("GET", 2) where request.pathComponents == ["v1", "tasks"]:
                response = (200, try JSONEncoder().encode(catalog.tasks))
            case ("POST", 2) where request.pathComponents == ["v1", "tasks"]:
                var task = try JSONDecoder().decode(ScheduledTask.self, from: request.body)
                guard task.validationMessage() == nil else {
                    throw ScheduledTaskServiceError.invalidRequest
                }
                guard catalog.task(id: task.id) == nil else {
                    throw ScheduledTaskServiceError.conflict
                }
                task.createdAt = Date()
                task.lastRunAt = nil
                task.nextRunAt = nil
                task.executionState = .never
                task.executionMessage = nil
                catalog.add(task)
                response = (201, try JSONEncoder().encode(catalog.tasks.first { $0.id == task.id } ?? task))
            case ("PUT", 3) where request.pathComponents.prefix(2) == ["v1", "tasks"]:
                let rawID = request.pathComponents[2]
                guard let id = UUID(uuidString: rawID) else {
                    throw ScheduledTaskServiceError.invalidRequest
                }
                var task = try JSONDecoder().decode(ScheduledTask.self, from: request.body)
                task.id = id
                guard task.validationMessage() == nil else {
                    throw ScheduledTaskServiceError.invalidRequest
                }
                guard let existing = catalog.task(id: id) else {
                    throw ScheduledTaskServiceError.notFound
                }
                task.createdAt = existing.createdAt
                task.lastRunAt = existing.lastRunAt
                task.nextRunAt = existing.nextRunAt
                task.executionState = existing.executionState
                task.executionMessage = existing.executionMessage
                guard catalog.replace(task) else { throw ScheduledTaskServiceError.notFound }
                response = (200, try JSONEncoder().encode(catalog.tasks.first { $0.id == id } ?? task))
            case ("DELETE", 3) where request.pathComponents.prefix(2) == ["v1", "tasks"]:
                let rawID = request.pathComponents[2]
                guard let id = UUID(uuidString: rawID) else {
                    throw ScheduledTaskServiceError.invalidRequest
                }
                catalog.delete(id: id)
                response = (204, Data())
            default:
                throw ScheduledTaskServiceError.notFound
            }
            send(status: response.0, bodyData: response.1, on: connection)
        } catch let error as ScheduledTaskServiceError {
            send(status: error.statusCode, body: ["error": error.localizedDescription], on: connection)
        } catch {
            send(status: 400, body: ["error": error.localizedDescription], on: connection)
        }
    }

    private func send(status: Int, body: [String: String], on connection: NWConnection) {
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        send(status: status, bodyData: data, on: connection)
    }

    private func send(status: Int, bodyData: Data, on connection: NWConnection) {
        let reason = HTTPTaskResponse.reason(for: status)
        var response = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(bodyData)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

enum ScheduledTaskServiceError: LocalizedError {
    case invalidPort
    case invalidRequest
    case notFound
    case conflict

    var statusCode: Int {
        switch self {
        case .invalidPort: return 400
        case .invalidRequest: return 400
        case .notFound: return 404
        case .conflict: return 409
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidPort: return "任务服务端口无效"
        case .invalidRequest: return "任务请求无效"
        case .notFound: return "任务接口不存在"
        case .conflict: return "任务 ID 已存在"
        }
    }
}

private struct HTTPTaskRequest {
    let method: String
    let pathComponents: [String]
    let headers: [String: String]
    let body: Data

    init?(data: Data) {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data[..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard requestParts.count == 3 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            headers[parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = parts[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let contentLength = Int(headers["content-length"] ?? "0"),
              contentLength >= 0,
              contentLength <= 2 * 1_024 * 1_024 else { return nil }
        let bodyStart = headerEnd.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        let rawPath = requestParts[1].split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        guard rawPath.hasPrefix("/") else { return nil }
        method = requestParts[0].uppercased()
        pathComponents = rawPath.split(separator: "/").map(String.init)
        self.headers = headers
        body = Data(data[bodyStart..<(bodyStart + contentLength)])
    }
}

private enum HTTPTaskResponse {
    static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 409: return "Conflict"
        default: return "Error"
        }
    }
}
