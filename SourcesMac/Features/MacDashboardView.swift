import SwiftUI

struct MacDashboardView: View {
    @ObservedObject var model: MacAppModel
    @State private var newDeviceKey = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                serverSection
                monitorSection
                barkSection
                logSection
            }
            .padding(24)
        }
        .frame(minWidth: 700, minHeight: 680)
        .onAppear { model.handleInitialLaunch() }
    }

    private var serverSection: some View {
        GroupBox("Codex app-server") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Circle()
                        .fill(model.server.state.isRunning ? Color.green : Color.secondary)
                        .frame(width: 10, height: 10)
                    Text(model.server.state.label)
                    Spacer()
                    if model.server.state.isRunning {
                        Button("停止服务器", role: .destructive) { model.stopServer() }
                    } else {
                        Button("启动服务器") { model.startServer() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                HStack {
                    TextField("监听端口", value: $model.configuredPort, format: .number)
                        .frame(width: 180)
                    Text("iPhone 连接此 Mac 的局域网地址和该端口")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("启动 CodeAnywhere Mac 时自动启动服务器", isOn: $model.startsAutomatically)
            }
            .padding(8)
        }
    }

    private var monitorSection: some View {
        GroupBox("完成监控") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(model.monitor.status.label)
                    Spacer()
                    Button("立即检查") { model.monitor.pollNow() }
                        .disabled(!model.server.state.isRunning)
                    Button("重试待发送") { model.monitor.retryFailedDeliveries() }
                        .disabled(model.monitor.pendingCount == 0)
                }
                HStack(spacing: 18) {
                    Label("待发送 \(model.monitor.pendingCount)", systemImage: "clock")
                    Label("已接受 \(model.monitor.deliveredCount)", systemImage: "checkmark.circle")
                    if let date = model.monitor.lastSuccessfulPoll {
                        Text("上次成功检查：\(date.formatted(date: .omitted, time: .standard))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    private var barkSection: some View {
        GroupBox("Bark 提醒") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Bark Server URL", text: $model.barkServerURL)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    SecureField("Bark Device Key（不会写入设置或日志）", text: $newDeviceKey)
                        .textFieldStyle(.roundedBorder)
                    Button("保存到 Keychain") {
                        model.saveDeviceKey(newDeviceKey)
                        newDeviceKey = ""
                    }
                    .disabled(newDeviceKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                HStack {
                    Label(
                        model.hasStoredDeviceKey ? "Keychain 中已有 Device Key" : "尚未保存 Device Key",
                        systemImage: model.hasStoredDeviceKey ? "key.fill" : "key"
                    )
                    Spacer()
                    Button("删除 Key", role: .destructive) { model.deleteDeviceKey() }
                        .disabled(!model.hasStoredDeviceKey)
                    Button("发送测试提醒") {
                        Task { await model.sendBarkTest() }
                    }
                    .disabled(!model.hasStoredDeviceKey || model.barkStatus == .working)
                }
                if let message = model.barkStatus.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(barkStatusColor)
                }
                Text("“已接受”只代表 Bark Server 返回 HTTP 成功且业务 code 为 200，不代表 iPhone 已显示通知。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    private var logSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("最近日志")
                        .font(.headline)
                    Spacer()
                    Button("清空") { model.server.clearLogs() }
                }
                ScrollView {
                    Text(model.server.logLines.isEmpty ? "暂无日志" : model.server.logLines.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(height: 180)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .padding(8)
        }
    }

    private var barkStatusColor: Color {
        if case .failure = model.barkStatus { return .red }
        return .secondary
    }
}
