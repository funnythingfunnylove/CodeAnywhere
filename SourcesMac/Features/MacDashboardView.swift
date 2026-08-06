import SwiftUI

private enum MacDashboardSection: String, CaseIterable, Identifiable {
    case codex
    case notify
    case logs
    case settings

    var id: String { rawValue }

    private var metadata: (title: String, subtitle: String, systemImage: String) {
        switch self {
        case .codex: return ("Codex", "服务与版本", "terminal")
        case .notify: return ("Notify", "Bark 完成提醒", "bell.badge")
        case .logs: return ("Logs", "运行记录", "text.alignleft")
        case .settings: return ("Settings", "连接与安全", "gearshape")
        }
    }

    var title: String { metadata.title }
    var subtitle: String { metadata.subtitle }
    var systemImage: String { metadata.systemImage }
}

struct MacDashboardView: View {
    @ObservedObject var model: MacAppModel
    @State private var selection: MacDashboardSection = .codex
    @State private var newDeviceKey = ""

    var body: some View {
        NavigationSplitView {
            List(MacDashboardSection.allCases, selection: $selection) { section in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(section.title)
                            .font(.body.weight(.medium))
                        Text(section.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: section.systemImage)
                        .symbolRenderingMode(.hierarchical)
                }
                .tag(section)
                .padding(.vertical, 4)
            }
            .listStyle(.sidebar)
            .navigationTitle("CodeAnywhere")
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
            .safeAreaInset(edge: .bottom) {
                SidebarStatus(model: model)
            }
        } detail: {
            Group {
                switch selection {
                case .codex:
                    CodexDashboardPage(model: model)
                case .notify:
                    NotifyDashboardPage(model: model)
                case .logs:
                    LogsDashboardPage(model: model)
                case .settings:
                    SettingsDashboardPage(model: model, newDeviceKey: $newDeviceKey)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 860, minHeight: 620)
    }
}

private struct SidebarStatus: View {
    @ObservedObject var model: MacAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider()
            Label(model.server.state.label, systemImage: model.server.state.isRunning ? "circle.fill" : "circle")
                .foregroundStyle(model.server.state.isRunning ? .green : .secondary)
                .lineLimit(1)
            Text("Codex \(model.codex.version) · \(model.versionDisplay)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
    }
}

private struct CodexDashboardPage: View {
    @ObservedObject var model: MacAppModel

    var body: some View {
        DashboardPage(
            title: "Codex",
            subtitle: "控制局域网 app-server，查看 CLI 信息并使用官方更新命令。"
        ) {
            DashboardCard(title: "App Server", systemImage: "server.rack") {
                HStack(alignment: .center, spacing: 18) {
                    StatusGlyph(isActive: model.server.state.isRunning)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.server.state.label)
                            .font(.title3.weight(.semibold))
                        Text(model.localServerEndpoint ?? "未检测到可用的局域网 IPv4 地址")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.server.state.isRunning {
                        Button("停止服务器", role: .destructive) { model.stopServer() }
                    } else {
                        Button("启动服务器") { model.startServer() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(!model.canStartServer)
                    }
                }
            }

            DashboardCard(title: "Codex CLI", systemImage: "shippingbox") {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                    InfoRow(label: "版本", value: model.codex.version)
                    InfoRow(label: "可执行文件", value: model.codex.executablePath, selectable: true)
                    if let checkedAt = model.codex.lastCheckedAt {
                        InfoRow(
                            label: "最近检查",
                            value: checkedAt.formatted(date: .abbreviated, time: .standard)
                        )
                    }
                }

                Divider()

                HStack(spacing: 10) {
                    Button {
                        Task { await model.codex.refresh() }
                    } label: {
                        Label("刷新信息", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.codex.updateState.isWorking)

                    Button {
                        Task { await model.updateCodex() }
                    } label: {
                        Label("更新 Codex", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canUpdateCodex)

                    if model.codex.updateState.isWorking {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(model.codex.updateState.label)
                        .font(.callout)
                        .foregroundStyle(codexStatusColor)
                    Spacer()
                }

                if model.server.state.isRunning {
                    Label("更新前请先停止 app-server，避免运行中的进程继续使用旧版本。", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("“更新 Codex”会直接执行当前安装位置的 `codex update`，完成后重新读取版本。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            DashboardCard(title: "运行环境", systemImage: "desktopcomputer") {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                    InfoRow(label: "CodeAnywhere Mac", value: model.versionDisplay)
                    InfoRow(label: "系统", value: model.operatingSystemDisplay)
                    InfoRow(label: "架构", value: model.architectureDisplay)
                    InfoRow(
                        label: "iPhone Endpoint",
                        value: model.localServerEndpoint ?? "未检测到局域网 IPv4"
                    )
                    InfoRow(label: "iPhone Turn 权限", value: "Full Access · approvalPolicy never")
                }
            }
        }
    }

    private var codexStatusColor: Color {
        if case .failed = model.codex.updateState { return .red }
        if case .succeeded = model.codex.updateState { return .green }
        return .secondary
    }
}

private struct NotifyDashboardPage: View {
    @ObservedObject var model: MacAppModel

    var body: some View {
        DashboardPage(
            title: "Notify",
            subtitle: "设置 Codex 完成提醒的内容与 Bark 展示方式。"
        ) {
            DashboardCard(title: "通知预览", systemImage: "bell.and.waves.left.and.right") {
                BarkNotificationPreview(style: model.barkStyle)
            }

            DashboardCard(title: "格式", systemImage: "textformat") {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("标题模板", text: $model.barkStyle.titleTemplate)
                    TextField("副标题模板", text: $model.barkStyle.subtitleTemplate)
                    TextField("正文模板", text: $model.barkStyle.bodyTemplate, axis: .vertical)
                        .lineLimit(2...5)
                    Text("可用变量：{thread} 对话标题、{status} 终态、{time} 完成时间、{detail} 错误详情")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("正文使用 Bark Markdown", isOn: $model.barkStyle.usesMarkdown)
                }
                .textFieldStyle(.roundedBorder)
            }

            DashboardCard(title: "样式", systemImage: "paintbrush") {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("中断级别", selection: $model.barkStyle.level) {
                        ForEach(BarkInterruptionLevel.allCases) { level in
                            Text(level.label).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(model.barkStyle.level.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if model.barkStyle.level == .critical {
                        HStack {
                            Text("重要警告音量")
                            Slider(
                                value: Binding(
                                    get: { Double(model.barkStyle.criticalVolume) },
                                    set: { model.barkStyle.criticalVolume = Int($0.rounded()) }
                                ),
                                in: 0...10,
                                step: 1
                            )
                            Text("\(model.barkStyle.criticalVolume)")
                                .monospacedDigit()
                                .frame(width: 20, alignment: .trailing)
                        }
                    }

                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                        GridRow {
                            Text("分组")
                            TextField("CodeAnywhere", text: $model.barkStyle.group)
                        }
                        GridRow {
                            Text("声音")
                            TextField("留空使用 Bark 默认声音", text: $model.barkStyle.sound)
                        }
                        GridRow {
                            Text("图标 URL")
                            TextField("https://…", text: $model.barkStyle.icon)
                        }
                    }
                    .textFieldStyle(.roundedBorder)

                    Link(
                        destination: URL(string: "https://bark.day.app/#/tutorial")!
                    ) {
                        Label("查看 Bark 官方参数教程", systemImage: "arrow.up.right.square")
                    }
                    .font(.callout)
                }
            }

            DashboardCard(title: "完成监控", systemImage: "waveform.path.ecg") {
                HStack {
                    StatusGlyph(isActive: model.monitor.status == .monitoring)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.monitor.status.label)
                            .font(.headline)
                        HStack(spacing: 16) {
                            Label("待发送 \(model.monitor.pendingCount)", systemImage: "clock")
                            Label("已接受 \(model.monitor.deliveredCount)", systemImage: "checkmark.circle")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("立即检查") { model.monitor.pollNow() }
                        .disabled(!model.server.state.isRunning)
                    Button("重试待发送") { model.monitor.retryFailedDeliveries() }
                        .disabled(model.monitor.pendingCount == 0)
                    Button("发送测试提醒") {
                        Task { await model.sendBarkTest() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.hasStoredDeviceKey || model.barkStatus == .working)
                }

                if let message = model.barkStatus.message {
                    Label(message, systemImage: barkStatusImage)
                        .font(.caption)
                        .foregroundStyle(barkStatusColor)
                }

                Text("“已接受”仅表示 Bark Server 返回 HTTP 成功且业务 code 为 200；iPhone 是否显示仍需在设备上确认。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DashboardCard(title: "提醒记录", systemImage: "clock.arrow.circlepath") {
                HStack {
                    Text("最近显示 20 条服务端已接受记录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("清除记录") { model.monitor.clearNotificationHistory() }
                        .disabled(model.monitor.notificationHistory.isEmpty && model.monitor.deliveredCount == 0)
                }

                if model.monitor.notificationHistory.isEmpty {
                    ContentUnavailableView(
                        "暂无提醒记录",
                        systemImage: "bell.slash",
                        description: Text("Codex Turn 完成、失败或中断并被 Bark Server 接受后会显示在这里。")
                    )
                    .frame(minHeight: 110)
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.monitor.notificationHistory.prefix(20)) { record in
                            NotificationHistoryRow(record: record)
                            if record.id != model.monitor.notificationHistory.prefix(20).last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    private var barkStatusColor: Color {
        if case .failure = model.barkStatus { return .red }
        if case .success = model.barkStatus { return .green }
        return .secondary
    }

    private var barkStatusImage: String {
        if case .failure = model.barkStatus { return "exclamationmark.triangle" }
        if case .success = model.barkStatus { return "checkmark.circle" }
        return "arrow.triangle.2.circlepath"
    }
}

private struct LogsDashboardPage: View {
    @ObservedObject var model: MacAppModel

    var body: some View {
        DashboardPage(
            title: "Logs",
            subtitle: "查看已脱敏的 app-server 输出和最近一次 Codex 更新结果。"
        ) {
            DashboardCard(title: "App Server", systemImage: "terminal") {
                HStack {
                    Label(model.server.state.label, systemImage: "circle.fill")
                        .foregroundStyle(model.server.state.isRunning ? .green : .secondary)
                    Spacer()
                    Button("清空") { model.server.clearLogs() }
                        .disabled(model.server.logLines.isEmpty)
                }
                LogConsole(
                    text: model.server.logLines.isEmpty
                        ? "暂无 app-server 日志"
                        : model.server.logLines.joined(separator: "\n")
                )
            }

            DashboardCard(title: "Codex Update", systemImage: "arrow.down.circle") {
                HStack {
                    Text(model.codex.updateState.label)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("再次检查版本") {
                        Task { await model.codex.refresh() }
                    }
                    .disabled(model.codex.updateState.isWorking)
                }
                LogConsole(
                    text: model.codex.lastCommandOutput.isEmpty
                        ? "尚未在本应用中执行 codex update"
                        : model.codex.lastCommandOutput
                )
            }
        }
    }
}

private struct SettingsDashboardPage: View {
    @ObservedObject var model: MacAppModel
    @Binding var newDeviceKey: String

    var body: some View {
        DashboardPage(
            title: "Settings",
            subtitle: "管理连接、启动行为与 Bark 凭据。"
        ) {
            DashboardCard(title: "Codex App Server", systemImage: "network") {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                    GridRow {
                        Text("监听端口")
                        TextField(
                            "端口",
                            value: $model.configuredPort,
                            format: .number.grouping(.never)
                        )
                            .frame(width: 140)
                    }
                    GridRow {
                        Text("局域网地址")
                        Text(model.localServerEndpoint ?? "未检测到局域网 IPv4")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                Toggle("打开 CodeAnywhere Mac 时自动启动服务器", isOn: $model.startsAutomatically)
                Text("服务器监听所有网络接口，只应在可信局域网中使用。修改端口会在下次启动服务器时生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DashboardCard(title: "Bark Server", systemImage: "bell") {
                TextField("Bark Server URL", text: $model.barkServerURL)
                    .textFieldStyle(.roundedBorder)
                Text("应用通过 JSON POST /push 发送 Device Key 与通知参数。URL 中不应包含 Key、查询参数或凭据。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DashboardCard(title: "Bark Device Key", systemImage: "key") {
                HStack {
                    SecureField("Device Key（不会写入设置或日志）", text: $newDeviceKey)
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
                        systemImage: model.hasStoredDeviceKey ? "checkmark.shield.fill" : "key"
                    )
                    .foregroundStyle(model.hasStoredDeviceKey ? .green : .secondary)
                    Spacer()
                    Button("删除 Key", role: .destructive) { model.deleteDeviceKey() }
                        .disabled(!model.hasStoredDeviceKey)
                }
            }

            DashboardCard(title: "关于", systemImage: "info.circle") {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                    InfoRow(label: "应用", value: "CodeAnywhere Mac")
                    InfoRow(label: "应用版本", value: model.versionDisplay)
                    InfoRow(label: "Codex CLI", value: model.codex.version)
                    InfoRow(label: "系统", value: model.operatingSystemDisplay)
                }
                Text("关闭窗口后应用仍会在后台运行，可从菜单栏图标重新打开。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct BarkNotificationPreview: View {
    let style: BarkNotificationStyle

    private var preview: BarkNotification {
        style.notification(
            threadTitle: "重新设计 Mac 端界面",
            statusTitle: "Codex 已完成",
            terminalAt: Date(),
            url: "codeanywhere://thread/preview",
            id: "preview"
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.gradient)
                .frame(width: 42, height: 42)
                .overlay {
                    Image(systemName: "terminal.fill")
                        .foregroundStyle(.white)
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(preview.title)
                        .font(.headline)
                    Spacer()
                    Text("现在")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if let subtitle = preview.subtitle {
                    Text(subtitle)
                        .font(.subheadline.weight(.medium))
                }
                Text(preview.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                HStack(spacing: 8) {
                    Text(preview.group)
                    Text("·")
                    Text(preview.level.label)
                    if preview.usesMarkdown {
                        Text("· Markdown")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.separator.opacity(0.6), lineWidth: 1)
        }
    }
}

private struct NotificationHistoryRow: View {
    let record: CompletionNotificationRecord

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title)
                    .font(.callout.weight(.semibold))
                Text(record.body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Text(record.deliveredAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
    }
}

private struct DashboardPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)
                content
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

private struct DashboardCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .symbolRenderingMode(.hierarchical)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        }
    }
}

private struct StatusGlyph: View {
    let isActive: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isActive ? Color.green.opacity(0.16) : Color.secondary.opacity(0.12))
                .frame(width: 46, height: 46)
            Circle()
                .fill(isActive ? Color.green : Color.secondary)
                .frame(width: 12, height: 12)
                .shadow(color: isActive ? .green.opacity(0.45) : .clear, radius: 5)
        }
        .accessibilityLabel(isActive ? "运行中" : "未运行")
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    var selectable = false

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            if selectable {
                Text(value)
                    .textSelection(.enabled)
            } else {
                Text(value)
            }
        }
    }
}

private struct LogConsole: View {
    let text: String

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(minHeight: 150, maxHeight: 300)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator.opacity(0.5), lineWidth: 1)
        }
    }
}
