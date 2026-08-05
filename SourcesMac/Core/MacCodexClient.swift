import Foundation

enum MacCodexClientError: LocalizedError, Sendable {
    case invalidEndpoint
    case disconnected
    case malformedResponse
    case server(code: Int, message: String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Codex app-server 地址无效"
        case .disconnected: return "Codex app-server 连接已断开"
        case .malformedResponse: return "Codex app-server 返回了无法识别的数据"
        case .server(_, let message): return message
        case .transport(let message): return message
        }
    }
}

struct MacCodexTurnCompletedEvent: Equatable, Sendable {
    let threadID: String
    let turnID: String
}

enum MacCodexServerEvent: Equatable, Sendable {
    case turnCompleted(MacCodexTurnCompletedEvent)
}

enum MacCodexServerEventParser {
    static func parse(data: Data) -> MacCodexServerEvent? {
        guard let message = try? JSONDecoder().decode(MacJSONValue.self, from: data),
              message["method"]?.stringValue == "turn/completed",
              let params = message["params"],
              let threadID = params["threadId"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !threadID.isEmpty,
              let turn = params["turn"],
              turn["status"]?.stringValue == "completed",
              let turnID = turn["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !turnID.isEmpty else {
            return nil
        }
        return .turnCompleted(
            MacCodexTurnCompletedEvent(threadID: threadID, turnID: turnID)
        )
    }
}

protocol MacCodexClientProtocol: Sendable {
    func connect() async throws
    func disconnect() async
    func call(method: String, params: [String: MacJSONValue]) async throws -> MacJSONValue
    func setEventHandler(_ handler: (@Sendable (MacCodexServerEvent) -> Void)?) async
}

extension MacCodexClientProtocol {
    func setEventHandler(_ handler: (@Sendable (MacCodexServerEvent) -> Void)?) async {}
}

actor MacCodexWebSocketClient: MacCodexClientProtocol {
    private let port: Int
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var listener: Task<Void, Never>?
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<MacJSONValue, Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var eventHandler: (@Sendable (MacCodexServerEvent) -> Void)?

    init(port: Int, session: URLSession = .shared) {
        self.port = port
        self.session = session
    }

    deinit {
        listener?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        timeouts.values.forEach { $0.cancel() }
    }

    func connect() async throws {
        guard (1...65_535).contains(port), let url = URL(string: "ws://127.0.0.1:\(port)/") else {
            throw MacCodexClientError.invalidEndpoint
        }
        if socket != nil { return }

        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(
            "Bearer \(MacServerAuthentication.capabilityToken)",
            forHTTPHeaderField: "Authorization"
        )
        let task = session.webSocketTask(with: request)
        socket = task
        task.resume()
        listener = Task { await receiveLoop() }

        do {
            _ = try await call(
                method: "initialize",
                params: [
                    "clientInfo": .object([
                        "name": .string("codeanywhere-mac"),
                        "title": .string("CodeAnywhere Mac"),
                        "version": .string("0.1.1")
                    ]),
                    "capabilities": .object(["experimentalApi": .bool(false)])
                ]
            )
            try await sendNotification(method: "initialized")
        } catch {
            disconnect()
            throw error
        }
    }

    func disconnect() {
        listener?.cancel()
        listener = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        eventHandler = nil
        failAll(with: MacCodexClientError.disconnected)
    }

    func setEventHandler(_ handler: (@Sendable (MacCodexServerEvent) -> Void)?) {
        eventHandler = handler
    }

    func call(method: String, params: [String: MacJSONValue] = [:]) async throws -> MacJSONValue {
        guard let socket else { throw MacCodexClientError.disconnected }
        let requestID = nextRequestID
        nextRequestID += 1
        let payload = MacJSONValue.object([
            "id": .number(Double(requestID)),
            "method": .string(method),
            "params": .object(params)
        ])
        let data = try JSONEncoder().encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw MacCodexClientError.malformedResponse
        }

        return try await withCheckedThrowingContinuation { continuation in
            pending[requestID] = continuation
            timeouts[requestID] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.timeout(requestID: requestID)
            }
            Task { await self.send(text: text, requestID: requestID, socket: socket) }
        }
    }

    private func sendNotification(method: String) async throws {
        guard let socket else { throw MacCodexClientError.disconnected }
        let payload = MacJSONValue.object(["method": .string(method)])
        let data = try JSONEncoder().encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw MacCodexClientError.malformedResponse
        }
        do {
            try await socket.send(.string(text))
        } catch {
            throw MacCodexClientError.transport(error.localizedDescription)
        }
    }

    private func send(text: String, requestID: Int, socket: URLSessionWebSocketTask) async {
        do {
            try await socket.send(.string(text))
        } catch {
            resume(requestID: requestID, with: .failure(MacCodexClientError.transport(error.localizedDescription)))
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
                handle(data: data)
            } catch {
                if !Task.isCancelled {
                    failAll(with: MacCodexClientError.transport(error.localizedDescription))
                    self.socket = nil
                }
                return
            }
        }
    }

    private func handle(data: Data) {
        guard let message = try? JSONDecoder().decode(MacJSONValue.self, from: data) else {
            return
        }
        guard let id = message["id"]?.intValue else {
            if let event = MacCodexServerEventParser.parse(data: data) {
                eventHandler?(event)
            }
            return
        }
        if let error = message["error"] {
            resume(
                requestID: id,
                with: .failure(
                    MacCodexClientError.server(
                        code: error["code"]?.intValue ?? -1,
                        message: error["message"]?.stringValue ?? "Codex 请求失败"
                    )
                )
            )
        } else if let result = message["result"] {
            resume(requestID: id, with: .success(result))
        }
    }

    private func resume(requestID: Int, with result: Result<MacJSONValue, Error>) {
        guard let continuation = pending.removeValue(forKey: requestID) else { return }
        timeouts.removeValue(forKey: requestID)?.cancel()
        continuation.resume(with: result)
    }

    private func timeout(requestID: Int) {
        resume(requestID: requestID, with: .failure(MacCodexClientError.transport("Codex 请求超时")))
    }

    private func failAll(with error: Error) {
        let continuations = pending.values
        pending.removeAll()
        timeouts.values.forEach { $0.cancel() }
        timeouts.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
    }
}
