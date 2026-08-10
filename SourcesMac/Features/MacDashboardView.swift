import SwiftUI

private enum MacDashboardSection: String, CaseIterable, Identifiable {
    case dash
    case task
    case codex
    case notify
    case logs
    case settings

    var id: String { rawValue }

    private var metadata: (title: String, subtitle: String, systemImage: String) {
        switch self {
        case .dash: return ("Dash", "全局对话进度", "gauge.with.dots.needle.67percent")
        case .task: return ("Task", "定时与 Cron", "calendar.badge.clock")
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
    @State private var selection: MacDashboardSection = .dash
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
                case .dash:
                    MacProgressDashboardPage(model: model)
                case .task:
                    MacTaskDashboardPage(model: model)
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

private struct MacProgressDashboardPage: View {
    @ObservedObject var model: MacAppModel

    private var snapshots: [MonitoredThreadSnapshot] { model.monitor.threadSnapshots }
    private var activeCount: Int { snapshots.filter { $0.state == .active }.count }
    private var completedCount: Int { snapshots.filter { $0.state == .completed }.count }
    private var failedCount: Int { snapshots.filter { $0.state == .failed }.count }

    var body: some View {
        DashboardPage(
            title: "Dash",
            subtitle: "全局查看所有 Codex 对话的运行、完成与异常状态。"
        ) {
            HStack(spacing: 12) {
                MacMetricCard(title: "运行中", value: activeCount, systemImage: "sparkles", color: .orange)
                MacMetricCard(title: "已完成", value: completedCount, systemImage: "checkmark.circle.fill", color: .green)
                MacMetricCard(title: "异常", value: failedCount, systemImage: "exclamationmark.triangle.fill", color: .red)
                MacMetricCard(title: "全部", value: snapshots.count, systemImage: "bubble.left.and.bubble.right", color: .accentColor)
            }

            DashboardCard(title: "对话进度", systemImage: "list.bullet.rectangle") {
                HStack {
                    Text(model.monitor.lastSuccessfulPoll.map {
                        "最近刷新 \($0.formatted(date: .omitted, time: .standard))"
                    } ?? "尚未完成第一次刷新")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        model.monitor.pollNow()
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .disabled(!model.server.state.isRunning)
                }

                if snapshots.isEmpty {
                    ContentUnavailableView(
                        "暂无对话进度",
                        systemImage: "gauge.with.dots.needle.67percent",
                        description: Text("启动 app-server 后，Dash 会自动汇总对话状态。")
                    )
                    .frame(minHeight: 180)
                } else {
                    VStack(spacing: 0) {
                        ForEach(snapshots, id: \.id) { snapshot in
                            MacThreadProgressRow(snapshot: snapshot)
                            if snapshot.id != snapshots.last?.id { Divider() }
                        }
                    }
                }
            }
        }
    }
}

private struct MacMetricCard: View {
    let title: String
    let value: Int
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 1) {
                Text(value, format: .number)
                    .font(.title2.bold().monospacedDigit())
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct MacThreadProgressRow: View {
    let snapshot: MonitoredThreadSnapshot

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(snapshot.state.color.opacity(0.12))
                    .frame(width: 34, height: 34)
                if snapshot.state == .active {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: snapshot.state.systemImage)
                        .foregroundStyle(snapshot.state.color)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(snapshot.state.title)
                        .foregroundStyle(snapshot.state.color)
                    if let turnID = snapshot.turnID {
                        Text("Turn \(String(turnID.prefix(8)))")
                    }
                }
                .font(.caption)
            }
            Spacer()
            Text(snapshot.updatedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
    }
}

private struct MacTaskDashboardPage: View {
    @ObservedObject var model: MacAppModel
    @State private var showingNewTask = false
    @State private var editingTask: ScheduledTask?

    var body: some View {
        DashboardPage(
            title: "Task",
            subtitle: "所有计划均保存在这台 Mac，并由 Mac 常驻触发。"
        ) {
            DashboardCard(title: "任务服务", systemImage: "network") {
                HStack {
                    StatusGlyph(isActive: model.taskService.isRunning)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.taskService.isRunning ? "iOS 管理接口已就绪" : "任务服务未运行")
                            .font(.headline)
                        Text(model.taskService.port.map { "HTTP · 端口 \($0) · Bearer 认证" } ?? "随 app-server 一起启动")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await model.runDueScheduledTasks() }
                    } label: {
                        Label("检查到期任务", systemImage: "play.circle")
                    }
                    .disabled(!model.server.state.isRunning)
                    Button {
                        showingNewTask = true
                    } label: {
                        Label("添加任务", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
                Text("iPhone 只通过局域网接口增删查改；实际调度、cron 计算与对话启动全部由 Mac 完成。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DashboardCard(title: "计划列表", systemImage: "calendar.badge.clock") {
                if model.scheduledTasks.tasks.isEmpty {
                    ContentUnavailableView(
                        "暂无定时任务",
                        systemImage: "calendar.badge.plus",
                        description: Text("添加单次、固定间隔或五段 cron 计划。")
                    )
                    .frame(minHeight: 160)
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.scheduledTasks.tasks) { task in
                            MacScheduledTaskRow(
                                task: task,
                                onEnabledChange: { model.scheduledTasks.setEnabled($0, id: task.id) },
                                onDelete: { model.scheduledTasks.delete(id: task.id) },
                                onEdit: { editingTask = task }
                            )
                            if task.id != model.scheduledTasks.tasks.last?.id { Divider() }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingNewTask) {
            MacScheduledTaskEditorView(catalog: model.scheduledTasks)
        }
        .sheet(item: $editingTask) { task in
            MacScheduledTaskEditorView(catalog: model.scheduledTasks, task: task)
        }
    }
}

private struct MacScheduledTaskRow: View {
    let task: ScheduledTask
    let onEnabledChange: (Bool) -> Void
    let onDelete: () -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: task.schedule.kind == .cron ? "calendar.badge.clock" : "clock.arrow.circlepath")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.callout.weight(.semibold))
                Text(task.cwd)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 10) {
                    Label(task.schedule.summary, systemImage: "repeat")
                    if let nextRunAt = task.nextRunAt, task.isEnabled {
                        Text("下次 \(nextRunAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                    Text(task.executionState.title)
                        .foregroundStyle(task.executionState == .failed ? .red : .secondary)
                }
                .font(.caption)
                if let message = task.executionMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(task.executionState == .failed ? .red : .secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Toggle("启用", isOn: Binding(get: { task.isEnabled }, set: onEnabledChange))
                .toggleStyle(.switch)
                .labelsHidden()
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除任务")
            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("编辑任务")
        }
        .padding(.vertical, 10)
        .opacity(task.isEnabled ? 1 : 0.65)
    }
}

private struct MacScheduledTaskEditorView: View {
    @ObservedObject var catalog: ScheduledTaskCatalog
    @Environment(\.dismiss) private var dismiss
    private let existingTask: ScheduledTask?
    @State private var title = ""
    @State private var prompt = ""
    @State private var path = ""
    @State private var modelID = ""
    @State private var effort = "high"
    @State private var scheduleKind = ScheduledTaskScheduleKind.once
    @State private var runAt = Date().addingTimeInterval(300)
    @State private var intervalMinutes = 60
    @State private var cronExpression = "0 9 * * 1-5"

    init(catalog: ScheduledTaskCatalog, task: ScheduledTask? = nil) {
        self.catalog = catalog
        existingTask = task
        _title = State(initialValue: task?.title ?? "")
        _prompt = State(initialValue: task?.prompt ?? "")
        _path = State(initialValue: task?.cwd ?? "")
        _modelID = State(initialValue: task?.modelID ?? "")
        _effort = State(initialValue: task?.reasoningEffort ?? "high")
        _scheduleKind = State(initialValue: task?.schedule.kind ?? .once)
        _runAt = State(initialValue: task?.schedule.runAt ?? Date().addingTimeInterval(300))
        _intervalMinutes = State(initialValue: task?.schedule.intervalMinutes ?? 60)
        _cronExpression = State(initialValue: task?.schedule.cronExpression ?? "0 9 * * 1-5")
    }

    private var schedule: ScheduledTaskSchedule {
        switch scheduleKind {
        case .once: return .once(at: runAt)
        case .interval: return .interval(minutes: intervalMinutes)
        case .cron: return .cron(cronExpression)
        }
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && path.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")
            && schedule.validationMessage == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Text(existingTask == nil ? "新建定时任务" : "编辑定时任务").font(.headline)
                Spacer()
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
            .padding(18)
            Divider()
            Form {
                TextField("任务名称", text: $title)
                TextField("项目绝对路径", text: $path)
                TextField("执行提示词", text: $prompt, axis: .vertical)
                    .lineLimit(3...8)
                TextField("模型 ID（留空使用服务端默认）", text: $modelID)
                Picker("思考级别", selection: $effort) {
                    ForEach(["low", "medium", "high", "xhigh", "max", "ultra"], id: \.self) {
                        Text($0).tag($0)
                    }
                }
                Picker("计划类型", selection: $scheduleKind) {
                    ForEach(ScheduledTaskScheduleKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                switch scheduleKind {
                case .once:
                    DatePicker("执行时间", selection: $runAt, in: Date()...)
                case .interval:
                    Stepper("每 \(intervalMinutes) 分钟", value: $intervalMinutes, in: 1...10_080)
                case .cron:
                    TextField("Cron：0 9 * * 1-5", text: $cronExpression)
                        .font(.system(.body, design: .monospaced))
                }
                if let message = schedule.validationMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else if let next = schedule.nextDate(after: Date()) {
                    LabeledContent("下次执行", value: next.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .formStyle(.grouped)
            .padding(18)
        }
        .frame(width: 620, height: 620)
    }

    private func save() {
        var task = existingTask ?? ScheduledTask(
            title: title,
            prompt: prompt,
            cwd: path,
            schedule: schedule
        )
        task.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        task.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        task.cwd = path.trimmingCharacters(in: .whitespacesAndNewlines)
        task.modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : modelID
        task.reasoningEffort = effort
        task.schedule = schedule
        if existingTask == nil {
            catalog.add(task)
        } else {
            catalog.replace(task)
        }
        dismiss()
    }
}

private extension MonitoredThreadState {
    var title: String {
        switch self {
        case .active: return "运行中"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .interrupted: return "已中断"
        case .unknown: return "未知"
        }
    }

    var color: Color {
        switch self {
        case .active: return .orange
        case .completed: return .green
        case .failed: return .red
        case .interrupted: return .secondary
        case .unknown: return .secondary
        }
    }

    var systemImage: String {
        switch self {
        case .active: return "sparkles"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .interrupted: return "stop.circle.fill"
        case .unknown: return "questionmark.circle"
        }
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
