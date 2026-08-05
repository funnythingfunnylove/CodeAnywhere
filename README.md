# CodeAnywhere

CodeAnywhere 是使用 SwiftUI 与 XcodeGen 构建的局域网 Codex 客户端，由 iOS 控制端和 macOS 伴侣端组成。iPhone 直接连接 Mac 上的 Codex `app-server` WebSocket JSON-RPC v2；Mac App 负责服务器启停、完成状态监控和 Bark 提醒。

## 生成工程

```bash
xcodegen generate
open CodeAnywhere.xcodeproj
```

最低系统为 iOS 18 和 macOS 15；使用 iOS 26 SDK 时启用原生 Liquid Glass，旧系统自动降级为系统 Material。

## 使用 Mac 伴侣端

正常使用时，在 Xcode 中选择 `CodeAnywhereMac` scheme 并运行。也可以在终端构建后打开：

```bash
xcodebuild build \
  -project CodeAnywhere.xcodeproj \
  -scheme CodeAnywhereMac \
  -destination 'platform=macOS,arch=arm64'
```

在 Mac App 中确认端口后点击“启动服务器”，然后在 iPhone 中填写这台 Mac 的局域网 IP 和相同端口。Mac App 只管理自己启动的 Codex 进程，停止服务器或退出应用不会终止其他 Codex 进程。

首次启动默认不会自动启动服务器，避免与已有的 `4500` 端口服务冲突。确认迁移完成后，可在 Mac App 中开启自动启动。

如果旧版 `scripts/start-codex-lan.sh` 仍在终端运行，请先回到原终端按 Control-C 停止，再从 Mac App 启动；Mac App 不会接管或停止脚本创建的外部进程。脚本暂时保留为开发和故障排查备用入口。

> 该监听地址可被同一网络中的设备访问，建议仅在可信局域网内运行；结束时在 Mac App 中点击“停止服务器”。

## Bark 完成提醒

在 Mac App 中填写 Bark Server URL，并把 Bark Device Key 保存到 macOS Keychain。Device Key 不会写入项目、UserDefaults、URL 或日志。Mac App 轮询对话状态，在任务完成、失败或中断后通过 JSON `POST /push` 发送 Bark，并附带对应对话的深层链接。

点击 Bark 通知会打开：

```text
codeanywhere://thread/<对话 ID>
```

iOS App 会切换到“对话”Tab、连接并刷新列表，然后打开对应对话。“已接受”只表示 Bark Server 返回 HTTP 成功且业务 `code` 为 `200`，是否在 iPhone 上实际显示仍需在真机确认。

## 协议能力

- `thread/list` 分页读取所有非归档历史 Session
- `thread/read` 显示用户、Codex、思考、命令和文件变更消息
- `thread/start` + `turn/start` 新建与继续对话
- 回答、reasoning 与命令输出按 app-server delta 事件流式显示；reasoning 和命令行默认折叠，可随时展开
- `model/list` 动态匹配桌面端模型及 reasoning effort
- `fs/createDirectory` 在桌面端新建项目目录
- `item/agentMessage/delta` 实时输出，`turn/completed` 完成提醒

iOS 端仍保留 `BGAppRefreshTask` 与本地通知作为辅助能力，但 iOS 后台唤醒由系统调度，不能保证常驻。可靠的离线完成提醒由持续运行的 CodeAnywhere Mac 监控并通过 Bark 发送。
