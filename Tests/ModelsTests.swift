import XCTest
import UserNotifications
@testable import CodeAnywhere

final class ModelsTests: XCTestCase {
    func testSavedEndpointEnablesAutoConnectAndExplicitDisconnectDisablesIt() throws {
        let suiteName = "CodeAnywhereTests.ConnectionPreferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(ConnectionPreferences.shouldAutoConnect(defaults: defaults))
        defaults.set(try JSONEncoder().encode(ServerEndpoint(host: "127.0.0.1", port: 4500)), forKey: StorageKey.endpoint)
        XCTAssertTrue(ConnectionPreferences.shouldAutoConnect(defaults: defaults))

        ConnectionPreferences.setAutoConnect(false, defaults: defaults)
        XCTAssertFalse(ConnectionPreferences.shouldAutoConnect(defaults: defaults))
        ConnectionPreferences.setAutoConnect(true, defaults: defaults)
        XCTAssertTrue(ConnectionPreferences.shouldAutoConnect(defaults: defaults))
    }

    func testCompletionNotificationContainsThreadNavigationPayload() {
        let content = NotificationManager.completionContent(title: "修复列表", threadID: "thread-123")
        XCTAssertEqual(content.title, "Codex 已完成")
        XCTAssertEqual(content.body, "修复列表")
        XCTAssertEqual(content.userInfo["threadId"] as? String, "thread-123")
        XCTAssertNotNil(content.sound)
    }

    func testBackgroundWatchStoreTracksAndRemovesThread() throws {
        let suiteName = "CodeAnywhereTests.BackgroundWatchStore.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        BackgroundWatchStore.add(threadID: "thread-1", title: "首次标题", defaults: defaults)
        BackgroundWatchStore.add(threadID: "thread-1", title: "更新标题", defaults: defaults)
        XCTAssertEqual(
            BackgroundWatchStore.all(defaults: defaults),
            [WatchedThread(id: "thread-1", title: "更新标题")]
        )
        XCTAssertTrue(BackgroundWatchStore.remove(threadID: "thread-1", defaults: defaults))
        XCTAssertFalse(BackgroundWatchStore.remove(threadID: "thread-1", defaults: defaults))
        XCTAssertTrue(BackgroundWatchStore.all(defaults: defaults).isEmpty)
    }

    @MainActor
    func testContinuingHistoricalThreadResumesItBeforeStartingTurn() async throws {
        let client = RecordingCodexClient()
        let store = RemoteCodexStore(client: client)

        try await store.send(
            prompt: "继续提问",
            threadID: "historical-thread",
            modelID: nil,
            effort: nil
        )

        let methods = await client.recordedMethods()
        XCTAssertEqual(Array(methods.prefix(2)), ["thread/resume", "turn/start"])
    }

    func testLiveCodexAppServerHandshakeAndCatalogWhenAvailable() async throws {
        let client = CodexWebSocketClient(endpoint: ServerEndpoint(host: "127.0.0.1", port: 4500))
        let userAgent: String
        do {
            userAgent = try await client.connect()
        } catch {
            await client.disconnect()
            throw XCTSkip("未连接到本机 Codex app-server，跳过协议 smoke test：\(error.localizedDescription)")
        }

        do {
            XCTAssertFalse(userAgent.isEmpty)

            let models = try await client.call(method: "model/list", params: ["limit": .number(10)])
            XCTAssertFalse(models["data"]?.arrayValue?.isEmpty ?? true)

            let threads = try await client.call(method: "thread/list", params: ["limit": .number(1)])
            XCTAssertNotNil(threads["data"]?.arrayValue)
            if let threadID = threads["data"]?.arrayValue?.first?["id"]?.stringValue {
                let resumed = try await client.call(
                    method: "thread/resume",
                    params: ["threadId": .string(threadID)]
                )
                XCTAssertEqual(resumed["thread"]?["id"]?.stringValue, threadID)

                let read = try await client.call(
                    method: "thread/read",
                    params: ["threadId": .string(threadID), "includeTurns": .bool(true)]
                )
                let threadJSON = try XCTUnwrap(read["thread"])
                XCTAssertNotNil(ThreadDetail(json: threadJSON))
            }
        } catch {
            await client.disconnect()
            throw error
        }
        await client.disconnect()
    }

    func testJSONValueRoundTrip() throws {
        let value: JSONValue = .object([
            "name": .string("Codex"),
            "count": .number(3),
            "enabled": .bool(true),
            "items": .array([.string("a"), .null])
        ])
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), value)
    }

    func testThreadMapsObjectStatusAndTimestamp() throws {
        let json: JSONValue = .object([
            "id": .string("thread-1"),
            "cwd": .string("/Users/demo/MyProject"),
            "name": .string("修复登录流程"),
            "preview": .string("preview"),
            "createdAt": .number(1_700_000_000),
            "updatedAt": .number(1_700_000_100),
            "status": .object(["type": .string("active")]),
            "isPinned": .bool(true)
        ])
        let thread = try XCTUnwrap(CodexThread(json: json))
        XCTAssertEqual(thread.title, "修复登录流程")
        XCTAssertEqual(thread.projectName, "MyProject")
        XCTAssertEqual(thread.activity, .active)
        XCTAssertTrue(thread.isPinned)
    }

    func testThreadDetailExtractsConversationItems() throws {
        let threadJSON: JSONValue = .object([
            "id": .string("thread-1"),
            "cwd": .string("/tmp/project"),
            "preview": .string("hello"),
            "createdAt": .number(1_700_000_000),
            "updatedAt": .number(1_700_000_100),
            "status": .object(["type": .string("idle")]),
            "turns": .array([
                .object([
                    "id": .string("turn-1"),
                    "status": .string("completed"),
                    "items": .array([
                        .object([
                            "id": .string("user-1"),
                            "type": .string("userMessage"),
                            "content": .array([.object(["type": .string("text"), "text": .string("你好")])])
                        ]),
                        .object([
                            "id": .string("assistant-1"),
                            "type": .string("agentMessage"),
                            "text": .string("你好，我在。")
                        ])
                    ])
                ])
            ])
        ])
        let detail = try XCTUnwrap(ThreadDetail(json: threadJSON))
        XCTAssertEqual(detail.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(detail.messages.map(\.text), ["你好", "你好，我在。"])
        XCTAssertEqual(detail.latestTurnID, "turn-1")
    }

    func testThreadDetailParsesStructuredImagesAndNewItemFormats() throws {
        let threadJSON: JSONValue = .object([
            "id": .string("thread-rich"),
            "cwd": .string("/tmp/project"),
            "preview": .string("rich"),
            "createdAt": .number(1_700_000_000),
            "updatedAt": .number(1_700_000_100),
            "status": .object(["type": .string("idle")]),
            "turns": .array([
                .object([
                    "id": .string("turn-rich"),
                    "status": .string("completed"),
                    "items": .array([
                        .object([
                            "id": .string("user-rich"),
                            "type": .string("userMessage"),
                            "content": .array([
                                .object(["type": .string("text"), "text": .string("你好\u{001B}[31m世界\u{001B}[0m")]),
                                .object(["type": .string("image"), "url": .string("https://example.com/image.png")]),
                                .object(["type": .string("localImage"), "path": .string("/tmp/screenshot.png")])
                            ])
                        ]),
                        .object([
                            "id": .string("reasoning-rich"),
                            "type": .string("reasoning"),
                            "summary": .array([]),
                            "content": .array([.string("推理详情")])
                        ]),
                        .object([
                            "id": .string("file-change"),
                            "type": .string("fileChange"),
                            "status": .string("completed"),
                            "changes": .array([
                                .object([
                                    "path": .string("Sources/App.swift"),
                                    "diff": .string("diff"),
                                    "kind": .object(["type": .string("update")])
                                ])
                            ])
                        ]),
                        .object([
                            "id": .string("dynamic-tool"),
                            "type": .string("dynamicToolCall"),
                            "tool": .string("render"),
                            "status": .string("completed"),
                            "arguments": .object([:]),
                            "contentItems": .array([
                                .object([
                                    "type": .string("inputImage"),
                                    "imageUrl": .string("data:image/png;base64,aGVsbG8=")
                                ])
                            ])
                        ]),
                        .object([
                            "id": .string("image-view"),
                            "type": .string("imageView"),
                            "path": .string("/tmp/result.png")
                        ]),
                        .object([
                            "id": .string("collab"),
                            "type": .string("collabToolCall"),
                            "tool": .string("spawnAgent"),
                            "status": .string("completed"),
                            "receiverThreadIds": .array([.string("child-1")]),
                            "prompt": .string("检查图片渲染")
                        ]),
                        .object([
                            "id": .string("sleep"),
                            "type": .string("sleep"),
                            "durationMs": .number(1_500)
                        ]),
                        .object([
                            "id": .string("generated-image"),
                            "type": .string("imageGeneration"),
                            "status": .string("completed"),
                            "result": .string("data:image/png;base64,aGVsbG8=")
                        ])
                    ])
                ])
            ])
        ])

        let detail = try XCTUnwrap(ThreadDetail(json: threadJSON))
        XCTAssertEqual(detail.messages.count, 8)
        XCTAssertEqual(detail.messages[0].text, "你好世界")
        XCTAssertEqual(detail.messages[0].images.count, 2)
        XCTAssertEqual(detail.messages[0].images[0].source, .remoteURL("https://example.com/image.png"))
        XCTAssertEqual(detail.messages[0].images[1].source, .localPath("/tmp/screenshot.png"))
        XCTAssertEqual(detail.messages[1].text, "推理详情")
        XCTAssertTrue(detail.messages[2].text.contains("Sources/App.swift"))
        XCTAssertEqual(detail.messages[3].images.first?.source, .dataURL("data:image/png;base64,aGVsbG8="))
        XCTAssertEqual(detail.messages[4].images.first?.source, .localPath("/tmp/result.png"))
        XCTAssertTrue(detail.messages[5].text.contains("目标代理：1"))
        XCTAssertEqual(detail.messages[6].text, "等待 1.5 秒")
        XCTAssertEqual(detail.messages[7].text, "生成的图片")
        XCTAssertEqual(detail.messages[7].images.first?.source, .dataURL("data:image/png;base64,aGVsbG8="))
    }

    func testMessageSanitizerRemovesTerminalEscapesAndControlCharacters() {
        let input = "正常\u{001B}[31m红色\u{001B}[0m\u{0000}结束\r\n下一行"
        XCTAssertEqual(ChatTextSanitizer.clean(input), "正常红色结束\n下一行")
    }

    func testMessageSanitizerRepairsDoubleEscapesAndUTF8Mojibake() {
        XCTAssertEqual(ChatTextSanitizer.clean("\"第一行\\n第二行\\u4F60\\u597D\""), "第一行\n第二行你好")
        XCTAssertEqual(ChatTextSanitizer.clean("ä½ å¥½"), "你好")
        XCTAssertEqual(ChatTextSanitizer.clean("Café déjà vu"), "Café déjà vu")
    }

    func testMessageBlockParserSupportsRichMarkdownAndRemoteImages() throws {
        let markdown = """
        # 标题

        - [x] 已完成
        - [ ] 待处理

        | 名称 | 状态 |
        | --- | --- |
        | 构建 | **通过** |

        ```swift
        let value = 1
        ```

        ![预览](https://example.com/preview.png)
        """

        let blocks = MessageBlockParser.parse(markdown)
        XCTAssertEqual(blocks[0], .heading(level: 1, text: "标题"))
        XCTAssertEqual(blocks[1], .taskList([
            MessageTaskItem(text: "已完成", isCompleted: true),
            MessageTaskItem(text: "待处理", isCompleted: false)
        ]))
        XCTAssertEqual(blocks[2], .table(headers: ["名称", "状态"], rows: [["构建", "**通过**"]]))
        XCTAssertEqual(blocks[3], .code(language: "swift", text: "let value = 1"))
        guard case .image(let image) = blocks[4] else {
            return XCTFail("应解析 Markdown 图片")
        }
        XCTAssertEqual(image.source, .remoteURL("https://example.com/preview.png"))
        XCTAssertEqual(image.altText, "预览")
    }

    func testMessageBlockParserRecognizesSafeBareImageURL() throws {
        let blocks = MessageBlockParser.parse("https://images.example.com/path/preview.webp")
        guard case .image(let image) = try XCTUnwrap(blocks.first) else {
            return XCTFail("应识别独立图片 URL")
        }
        XCTAssertEqual(image.source, .remoteURL("https://images.example.com/path/preview.webp"))
    }

    func testImagePolicyRejectsUnsafeSchemesAndCredentialedURLs() {
        XCTAssertNil(ChatImagePolicy.remoteURL(from: "file:///tmp/image.png"))
        XCTAssertNil(ChatImagePolicy.remoteURL(from: "javascript:alert(1)"))
        XCTAssertNil(ChatImagePolicy.remoteURL(from: "https://user:password@example.com/image.png"))
        XCTAssertNotNil(ChatImagePolicy.remoteURL(from: "https://example.com/image.png"))
        XCTAssertFalse(ChatImagePolicy.isAllowedDataURL("data:text/html;base64,PGgxPk5vPC9oMT4="))
    }

    func testMarkdownLocalPathIsNotTurnedIntoRemoteFileRead() {
        XCTAssertEqual(
            MessageBlockParser.parse("![敏感文件](/etc/passwd)"),
            [.paragraph("![敏感文件](/etc/passwd)")]
        )
    }

    @MainActor
    func testRemoteImageFileIsReadOnceAndCached() async throws {
        let client = RecordingCodexClient()
        let store = RemoteCodexStore(client: client)

        let first = try await store.imageData(atRemotePath: "/tmp/image.png")
        let second = try await store.imageData(atRemotePath: "/tmp/image.png")

        XCTAssertEqual(first, Data("image".utf8))
        XCTAssertEqual(second, first)
        let methods = await client.recordedMethods()
        XCTAssertEqual(methods.filter { $0 == "fs/readFile" }.count, 1)
    }

    func testAppearanceModesIncludeSystemLightAndDark() {
        XCTAssertEqual(AppAppearance.allCases, [.system, .light, .dark])
        XCTAssertNil(AppAppearance.system.preferredColorScheme)
        XCTAssertEqual(AppAppearance.light.preferredColorScheme, .light)
        XCTAssertEqual(AppAppearance.dark.preferredColorScheme, .dark)
    }

    func testModelUsesServerReasoningOptions() throws {
        let json: JSONValue = .object([
            "id": .string("gpt-5"),
            "model": .string("gpt-5"),
            "displayName": .string("GPT-5"),
            "description": .string("Model"),
            "isDefault": .bool(true),
            "defaultReasoningEffort": .string("high"),
            "supportedReasoningEfforts": .array([
                .object(["reasoningEffort": .string("medium"), "description": .string("Balanced")]),
                .object(["reasoningEffort": .string("high"), "description": .string("Deep")])
            ])
        ])
        let model = try XCTUnwrap(CodexModel(json: json))
        XCTAssertEqual(model.defaultReasoningEffort, "high")
        XCTAssertEqual(model.reasoningOptions.map(\.id), ["medium", "high"])
    }
}

private actor RecordingCodexClient: CodexClientProtocol {
    nonisolated let notifications: AsyncStream<RPCNotification> = AsyncStream { continuation in
        continuation.finish()
    }

    private var methods: [String] = []
    private var resumedThreadIDs: Set<String> = []

    func connect() async throws -> String { "Test Codex" }

    func disconnect() async {}

    func call(method: String, params: [String: JSONValue]) async throws -> JSONValue {
        methods.append(method)
        switch method {
        case "thread/resume":
            if let threadID = params["threadId"]?.stringValue {
                resumedThreadIDs.insert(threadID)
            }
            return .object(["thread": Self.threadJSON])
        case "turn/start":
            guard let threadID = params["threadId"]?.stringValue,
                  resumedThreadIDs.contains(threadID) else {
                throw CodexClientError.server(code: -32000, message: "thread not found")
            }
            return .object([:])
        case "thread/read":
            return .object(["thread": Self.threadJSON])
        case "thread/list":
            return .object(["data": .array([])])
        case "fs/readFile":
            return .object(["dataBase64": .string(Data("image".utf8).base64EncodedString())])
        default:
            throw CodexClientError.server(code: -1, message: "Unexpected method: \(method)")
        }
    }

    func recordedMethods() -> [String] { methods }

    private static let threadJSON: JSONValue = .object([
        "id": .string("historical-thread"),
        "cwd": .string("/tmp/project"),
        "preview": .string("历史对话"),
        "createdAt": .number(1_700_000_000),
        "updatedAt": .number(1_700_000_100),
        "status": .object(["type": .string("idle")]),
        "turns": .array([])
    ])
}
