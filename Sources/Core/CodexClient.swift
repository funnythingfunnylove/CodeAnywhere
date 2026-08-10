import Foundation

struct RPCNotification: Sendable {
    let method: String
    let params: JSONValue
}

enum CodexClientError: LocalizedError, Sendable {
    case invalidEndpoint
    case disconnected
    case malformedResponse
    case server(code: Int, message: String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "IP 或端口无效"
        case .disconnected: return "与 Codex 桌面端的连接已断开"
        case .malformedResponse: return "Codex 返回了无法识别的数据"
        case .server(_, let message): return message
        case .transport(let message): return message
        }
    }
}

protocol CodexClientProtocol: Sendable {
    nonisolated var notifications: AsyncStream<RPCNotification> { get }

    func connect() async throws -> String
    func disconnect() async
    func call(method: String, params: [String: JSONValue]) async throws -> JSONValue
}

enum CodexAutomaticServerRequestResponder {
    static func response(for message: JSONValue) -> JSONValue? {
        guard let requestID = message["id"],
              let method = message["method"]?.stringValue else { return nil }

        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            return .object([
                "id": requestID,
                "result": .object(["decision": .string("accept")])
            ])
        default:
            return nil
        }
    }
}

actor CodexWebSocketClient: CodexClientProtocol {
    nonisolated let notifications: AsyncStream<RPCNotification>

    private let endpoint: ServerEndpoint
    private let serverResponseTextSender: (@Sendable (String) async throws -> Void)?
    private let notificationContinuation: AsyncStream<RPCNotification>.Continuation
    private var socket: URLSessionWebSocketTask?
    private var listener: Task<Void, Never>?
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]

    init(
        endpoint: ServerEndpoint,
        serverResponseTextSender: (@Sendable (String) async throws -> Void)? = nil
    ) {
        self.endpoint = endpoint
        self.serverResponseTextSender = serverResponseTextSender
        var continuation: AsyncStream<RPCNotification>.Continuation!
        notifications = AsyncStream { continuation = $0 }
        notificationContinuation = continuation
    }

    deinit {
        listener?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        notificationContinuation.finish()
    }

    func connect() async throws -> String {
        guard let url = endpoint.webSocketURL else { throw CodexClientError.invalidEndpoint }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Bearer \(ServerEndpoint.internalCapabilityToken)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = 32 * 1024 * 1024
        socket = task
        task.resume()
        listener = Task { await receiveLoop() }

        let result = try await call(
            method: "initialize",
            params: [
                "clientInfo": .object([
                    "name": .string("codeanywhere-ios"),
                    "title": .string("CodeAnywhere"),
                    "version": .string(Self.clientVersion)
                ]),
                "capabilities": .object(["experimentalApi": .bool(false)])
            ]
        )
        try await sendNotification(method: "initialized")
        return result["userAgent"]?.stringValue ?? "Codex"
    }

    private static var clientVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let version, let build { return "\(version) (\(build))" }
        return version ?? "unknown"
    }

    func disconnect() {
        listener?.cancel()
        listener = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        failAll(with: CodexClientError.disconnected)
    }

    func call(method: String, params: [String: JSONValue] = [:]) async throws -> JSONValue {
        guard socket != nil else { throw CodexClientError.disconnected }
        let requestID = nextRequestID
        nextRequestID += 1
        let payload = JSONValue.object([
            "id": .number(Double(requestID)),
            "method": .string(method),
            "params": .object(params)
        ])
        let data = try JSONEncoder().encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CodexClientError.malformedResponse
        }

        return try await withCheckedThrowingContinuation { continuation in
            pending[requestID] = continuation
            timeoutTasks[requestID] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(12))
                guard !Task.isCancelled else { return }
                await self?.timeout(requestID: requestID)
            }
            Task { await self.send(text: text, requestID: requestID) }
        }
    }

    private func sendNotification(method: String) async throws {
        guard let socket else { throw CodexClientError.disconnected }
        let payload = JSONValue.object(["method": .string(method)])
        let data = try JSONEncoder().encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CodexClientError.malformedResponse
        }
        do {
            try await socket.send(.string(text))
        } catch {
            throw CodexClientError.transport(error.localizedDescription)
        }
    }

    private func send(text: String, requestID: Int) async {
        guard let socket else {
            resume(requestID: requestID, with: .failure(CodexClientError.disconnected))
            return
        }
        do {
            try await socket.send(.string(text))
        } catch {
            resume(requestID: requestID, with: .failure(CodexClientError.transport(error.localizedDescription)))
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled, let socket {
            do {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .data(let value): data = value
                case .string(let value): data = Data(value.utf8)
                @unknown default: continue
                }
                await handle(data: data)
            } catch {
                if !Task.isCancelled {
                    notificationContinuation.yield(RPCNotification(method: "transport/closed", params: .string(error.localizedDescription)))
                    failAll(with: CodexClientError.transport(error.localizedDescription))
                }
                return
            }
        }
    }

    func handle(data: Data) async {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: data) else { return }
        if let response = CodexAutomaticServerRequestResponder.response(for: message) {
            await sendServerResponse(response)
            return
        }
        if let id = message["id"]?.intValue {
            if let error = message["error"] {
                let code = error["code"]?.intValue ?? -1
                let text = error["message"]?.stringValue ?? "Codex 请求失败"
                resume(requestID: id, with: .failure(CodexClientError.server(code: code, message: text)))
            } else if let result = message["result"] {
                resume(requestID: id, with: .success(result))
            }
            return
        }

        guard let method = message["method"]?.stringValue else { return }
        notificationContinuation.yield(RPCNotification(method: method, params: message["params"] ?? .null))
    }

    private func sendServerResponse(_ response: JSONValue) async {
        guard let data = try? JSONEncoder().encode(response),
              let text = String(data: data, encoding: .utf8) else { return }
        do {
            if let serverResponseTextSender {
                try await serverResponseTextSender(text)
            } else if let socket {
                try await socket.send(.string(text))
            }
        } catch {
            if !Task.isCancelled {
                notificationContinuation.yield(
                    RPCNotification(method: "transport/closed", params: .string(error.localizedDescription))
                )
                failAll(with: CodexClientError.transport(error.localizedDescription))
            }
        }
    }

    private func resume(requestID: Int, with result: Result<JSONValue, Error>) {
        guard let continuation = pending.removeValue(forKey: requestID) else { return }
        timeoutTasks.removeValue(forKey: requestID)?.cancel()
        continuation.resume(with: result)
    }

    private func timeout(requestID: Int) {
        resume(requestID: requestID, with: .failure(CodexClientError.transport("Codex 请求超时")))
    }

    private func failAll(with error: Error) {
        let continuations = pending.values
        pending.removeAll()
        timeoutTasks.values.forEach { $0.cancel() }
        timeoutTasks.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
    }
}
