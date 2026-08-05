import Foundation

@main
enum ThreadTurnStarterRegression {
    static func main() async throws {
        let recorder = MethodRecorder()
        let params: [String: JSONValue] = ["threadId": .string("historical-thread")]

        try await ThreadTurnStarter.start(
            threadID: "historical-thread",
            params: params
        ) { method, _ in
            try await recorder.call(method)
            return .object([:])
        }

        let methods = await recorder.methods
        guard methods == ["thread/resume", "turn/start"] else {
            throw RegressionFailure.unexpectedMethods(methods)
        }
        print("PASS: historical thread resumes before turn/start")
    }
}

private actor MethodRecorder {
    private(set) var methods: [String] = []
    private var resumed = false

    func call(_ method: String) throws {
        methods.append(method)
        if method == "thread/resume" {
            resumed = true
        } else if method == "turn/start", !resumed {
            throw RegressionFailure.threadNotFound
        }
    }
}

private enum RegressionFailure: Error {
    case threadNotFound
    case unexpectedMethods([String])
}
