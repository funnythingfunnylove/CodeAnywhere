import Foundation

private enum ProbeError: Error {
    case missingToken
    case malformedResponse
    case server(String)
}

private final class RPCClient {
    private let socket: URLSessionWebSocketTask
    private var nextID = 1

    init(socket: URLSessionWebSocketTask) {
        self.socket = socket
    }

    func call(method: String, params: [String: Any]) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        let payload: [String: Any] = ["id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try await socket.send(.data(data))

        while true {
            let message = try await socket.receive()
            let data: Data
            switch message {
            case .data(let value): data = value
            case .string(let value): data = Data(value.utf8)
            @unknown default: continue
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            guard (object["id"] as? NSNumber)?.intValue == id else { continue }
            if let error = object["error"] as? [String: Any] {
                throw ProbeError.server(error["message"] as? String ?? "unknown server error")
            }
            guard let result = object["result"] as? [String: Any] else {
                throw ProbeError.malformedResponse
            }
            return result
        }
    }

    func notify(method: String) async throws {
        let data = try JSONSerialization.data(withJSONObject: ["method": method])
        try await socket.send(.data(data))
    }
}

@main
private struct CompletionMonitorLiveProbe {
    static func main() async throws {
        let fileManager = FileManager.default
        let support = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodeAnywhere Mac", isDirectory: true)
        let runtime = support.appendingPathComponent("runtime", isDirectory: true)
        let tokenURLs = try fileManager.contentsOfDirectory(
            at: runtime,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "token" }
        let tokenURL = try tokenURLs.max {
            let lhs = try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            let rhs = try $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            return lhs < rhs
        }
        guard let tokenURL else { throw ProbeError.missingToken }
        let token = try String(contentsOf: tokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ProbeError.missingToken }

        var request = URLRequest(url: URL(string: "ws://127.0.0.1:4500/")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        let client = RPCClient(socket: socket)
        _ = try await client.call(method: "initialize", params: [
            "clientInfo": [
                "name": "codeanywhere-completion-probe",
                "title": "CodeAnywhere completion probe",
                "version": "1"
            ],
            "capabilities": ["experimentalApi": false]
        ])
        try await client.notify(method: "initialized")

        let stateURL = support.appendingPathComponent("completion-state.json")
        let stateData = try Data(contentsOf: stateURL)
        let state = try JSONSerialization.jsonObject(with: stateData) as? [String: Any] ?? [:]
        let baselineReferenceSeconds = (state["baseline"] as? NSNumber)?.doubleValue ?? 0
        let baselineUnixSeconds = baselineReferenceSeconds + Date.timeIntervalBetween1970AndReferenceDate

        var listedByID: [String: [String: Any]] = [:]
        for archived in [false, true] {
            var cursor: String?
            repeat {
                var params: [String: Any] = [
                    "limit": 100,
                    "sortKey": "updated_at",
                    "sortDirection": "desc",
                    "modelProviders": [],
                    "archived": archived
                ]
                if let cursor { params["cursor"] = cursor }
                let result = try await client.call(method: "thread/list", params: params)
                for thread in result["data"] as? [[String: Any]] ?? [] {
                    guard let id = thread["id"] as? String else { continue }
                    listedByID[id] = thread
                }
                cursor = result["nextCursor"] as? String
            } while cursor?.isEmpty == false
        }

        let recent = listedByID.values.filter { thread in
            let raw = (thread["updatedAt"] as? NSNumber)?.doubleValue ?? 0
            let seconds = raw > 10_000_000_000 ? raw / 1_000 : raw
            return seconds >= baselineUnixSeconds - 900
        }.sorted {
            (($0["updatedAt"] as? NSNumber)?.doubleValue ?? 0) > (($1["updatedAt"] as? NSNumber)?.doubleValue ?? 0)
        }

        var summaries: [[String: Any]] = []
        for listed in recent.prefix(20) {
            guard let id = listed["id"] as? String else { continue }
            let result = try await client.call(
                method: "thread/read",
                params: ["threadId": id, "includeTurns": true]
            )
            guard let thread = result["thread"] as? [String: Any] else { continue }
            let turns = (thread["turns"] as? [[String: Any]] ?? []).enumerated().map { index, turn in
                [
                    "index": index,
                    "id": turn["id"] as? String ?? "",
                    "status": turn["status"] as? String ?? "",
                    "startedAt": turn["startedAt"] ?? NSNull(),
                    "completedAt": turn["completedAt"] ?? NSNull()
                ] as [String: Any]
            }
            summaries.append([
                "id": id,
                "name": thread["name"] as? String ?? "",
                "updatedAt": thread["updatedAt"] ?? NSNull(),
                "threadStatus": thread["status"] ?? NSNull(),
                "turnCount": turns.count,
                "turns": turns
            ])
        }

        let output: [String: Any] = [
            "baselineUnixSeconds": baselineUnixSeconds,
            "recentThreads": summaries
        ]
        let outputData = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: outputData, as: UTF8.self))
    }
}
