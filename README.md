# CodeAnywhere

CodeAnywhere 是使用 SwiftUI 与 XcodeGen 构建的局域网 Codex iOS 控制端。它直接连接 Codex `app-server` WebSocket JSON-RPC v2，可浏览历史 Session、查看实时对话、新建桌面端项目目录、选择模型与思考级别，并在任务完成后发送本地通知。

## 生成工程

```bash
xcodegen generate
open CodeAnywhere.xcodeproj
```

最低系统为 iOS 18；使用 iOS 26 SDK 时启用原生 Liquid Glass，旧系统自动降级为系统 Material。

## 启动桌面端

在运行 Codex 的电脑上执行：

```bash
./scripts/start-codex-lan.sh 4500
```

然后在 iPhone 中只填写电脑的局域网 IP 与端口 `4500`。辅助脚本会配置 Codex 要求的 capability token；App 内没有账号或密码输入项。

> 该监听地址可被同一网络中的设备访问，建议仅在可信局域网内运行；结束时在终端按 Control-C。

## 协议能力

- `thread/list` 分页读取所有非归档历史 Session
- `thread/read` 显示用户、Codex、思考、命令和文件变更消息
- `thread/start` + `turn/start` 新建与继续对话
- `model/list` 动态匹配桌面端模型及 reasoning effort
- `fs/createDirectory` 在桌面端新建项目目录
- `item/agentMessage/delta` 实时输出，`turn/completed` 完成提醒

后台提醒使用 `BGAppRefreshTask` 与本地通知。iOS 后台唤醒由系统调度；App 活跃或连接存活时完成事件会即时提醒。

