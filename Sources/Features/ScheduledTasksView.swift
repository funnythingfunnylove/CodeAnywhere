import SwiftUI

struct ScheduledTasksView: View {
    @EnvironmentObject private var store: RemoteCodexStore
    @State private var showingNewTask = false

    var body: some View {
        RemoteScheduledTaskList(
            taskStore: store.scheduledTasks,
            endpoint: store.endpoint,
            reportError: { store.errorMessage = $0 }
        )
        .navigationTitle("Task")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingNewTask = true } label: {
                    Label("添加定时任务", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingNewTask) {
            ScheduledTaskEditorView()
        }
    }
}

private struct RemoteScheduledTaskList: View {
    @ObservedObject var taskStore: RemoteScheduledTaskStore
    let endpoint: ServerEndpoint
    let reportError: (String) -> Void
    @State private var editingTask: ScheduledTask?

    var body: some View {
        ZStack {
            AmbientBackground()
            if taskStore.tasks.isEmpty, !taskStore.isLoading {
                EmptyStateView(
                    icon: "calendar.badge.clock",
                    title: "还没有定时任务",
                    message: "在 iPhone 上配置，任务由 CodeAnywhere Mac 常驻执行"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: DS.spacingSM) {
                        executionNotice
                        ForEach(taskStore.tasks) { task in
                            ScheduledTaskRow(task: task) { enabled in
                                update(task, enabled: enabled)
                            } onDelete: {
                                delete(task)
                            } onEdit: {
                                editingTask = task
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .refreshable { await refresh() }
            }
            if taskStore.isLoading, taskStore.tasks.isEmpty {
                ProgressView("正在读取 Mac 任务…")
            }
        }
        .task { await refresh() }
        .sheet(item: $editingTask) { task in
            ScheduledTaskEditorView(task: task)
        }
    }

    private var executionNotice: some View {
        Label(
            "任务保存在 Mac，并由 Mac 在运行时触发；iOS 仅用于查看和管理。服务端口为 app-server 端口 + 1。",
            systemImage: "desktopcomputer"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassSurface(radius: 12)
    }

    private func refresh() async {
        do {
            try await taskStore.refresh(endpoint: endpoint)
        } catch {
            reportError(error.localizedDescription)
        }
    }

    private func update(_ task: ScheduledTask, enabled: Bool) {
        var task = task
        task.isEnabled = enabled
        Task {
            do {
                try await taskStore.update(task, endpoint: endpoint)
            } catch {
                reportError(error.localizedDescription)
            }
        }
    }

    private func delete(_ task: ScheduledTask) {
        Task {
            do {
                try await taskStore.delete(id: task.id, endpoint: endpoint)
            } catch {
                reportError(error.localizedDescription)
            }
        }
    }
}

private struct ScheduledTaskRow: View {
    let task: ScheduledTask
    let onEnabledChange: (Bool) -> Void
    let onDelete: () -> Void
    let onEdit: () -> Void
    @State private var showingDeleteConfirmation = false

    private var stateColor: Color {
        switch task.executionState {
        case .never: return .secondary
        case .running: return .orange
        case .succeeded: return .green
        case .failed: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: task.schedule.kind == .cron ? "calendar.badge.clock" : "clock.arrow.circlepath")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 42, height: 42)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text(task.cwd)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    Button(action: onEdit) {
                        Image(systemName: "pencil")
                            .frame(minWidth: 36, minHeight: 36)
                    }
                    .buttonStyle(.bordered)
                    .tint(.accentColor)
                    .accessibilityLabel("编辑任务")

                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .frame(minWidth: 36, minHeight: 36)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("删除任务")
                }
            }

            HStack(spacing: 8) {
                Label(task.schedule.summary, systemImage: task.schedule.kind == .cron ? "calendar" : "repeat")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.10), in: Capsule())
                Spacer()
                Label(task.executionState.title, systemImage: task.executionState == .failed ? "exclamationmark.circle.fill" : "circle.fill")
                    .foregroundStyle(stateColor)
                    .font(.caption.weight(.semibold))
                Toggle("启用", isOn: Binding(
                    get: { task.isEnabled },
                    set: onEnabledChange
                ))
                .labelsHidden()
            }
            .foregroundStyle(.secondary)

            Text(task.prompt)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if let nextRunAt = task.nextRunAt, task.isEnabled {
                LabeledContent("下次执行") {
                    Text(nextRunAt, format: .dateTime.month().day().hour().minute())
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if let message = task.executionMessage, !message.isEmpty {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(task.executionState == .failed ? .red : .secondary)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .contentCard(radius: 12)
        .opacity(task.isEnabled ? 1 : 0.68)
        .accessibilityElement(children: .contain)
        .alert("删除定时任务？", isPresented: $showingDeleteConfirmation) {
            Button("删除", role: .destructive, action: onDelete)
            Button("取消", role: .cancel) { }
        } message: {
            Text("“\(task.title)”将从 Mac 的任务列表中删除。")
        }
    }
}

private struct ScheduledTaskEditorView: View {
    @EnvironmentObject private var store: RemoteCodexStore
    @Environment(\.dismiss) private var dismiss
    private let existingTask: ScheduledTask?
    @State private var title = ""
    @State private var prompt = ""
    @State private var path = ""
    @State private var modelID = ""
    @State private var effort = OpenAIReasoningLevel.high.rawValue
    @State private var scheduleKind = ScheduledTaskScheduleKind.once
    @State private var runAt = Date().addingTimeInterval(300)
    @State private var intervalMinutes = 60
    @State private var cronExpression = "0 9 * * 1-5"
    @State private var isSaving = false

    init(task: ScheduledTask? = nil) {
        existingTask = task
        _title = State(initialValue: task?.title ?? "")
        _prompt = State(initialValue: task?.prompt ?? "")
        _path = State(initialValue: task?.cwd ?? "")
        _modelID = State(initialValue: task?.modelID ?? "")
        _effort = State(initialValue: task?.reasoningEffort ?? OpenAIReasoningLevel.high.rawValue)
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
            && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("任务") {
                    TextField("任务名称", text: $title)
                    TextField("Mac 上的项目绝对路径", text: $path, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("执行提示词", text: $prompt, axis: .vertical)
                        .lineLimit(3...8)
                }

                Section("模型") {
                    Picker("模型", selection: $modelID) {
                        Text("服务端默认").tag("")
                        ForEach(store.models) { model in
                            Text(model.displayName).tag(model.model)
                        }
                    }
                    Picker("思考级别", selection: $effort) {
                        ForEach(OpenAIReasoningLevel.allCases) { level in
                            Text(level.title).tag(level.rawValue)
                        }
                    }
                }

                Section("计划") {
                    Picker("类型", selection: $scheduleKind) {
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
                        TextField("0 9 * * 1-5", text: $cronExpression)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text("格式：分钟 小时 日期 月份 星期；支持 *、*/n、范围和逗号。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let message = schedule.validationMessage {
                        Label(message, systemImage: "exclamationmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    } else if let next = schedule.nextDate(after: Date()) {
                        LabeledContent("下次执行") {
                            Text(next, format: .dateTime.month().day().hour().minute())
                        }
                    }
                }

                Section {
                    Label("计划由 Mac 保存并执行；iPhone 关闭后不会影响任务。", systemImage: "desktopcomputer")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(existingTask == nil ? "新建任务" : "编辑任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "保存中…" : "保存") { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear {
                if path.isEmpty, existingTask == nil { path = store.projects.first?.path ?? "" }
            }
        }
    }

    private func save() {
        isSaving = true
        var task = existingTask ?? ScheduledTask(
            title: title,
            prompt: prompt,
            cwd: path,
            schedule: schedule
        )
        task.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        task.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        task.cwd = path.trimmingCharacters(in: .whitespacesAndNewlines)
        task.modelID = modelID.isEmpty ? nil : modelID
        task.reasoningEffort = effort
        task.schedule = schedule
        Task {
            do {
                if existingTask == nil {
                    try await store.scheduledTasks.add(task, endpoint: store.endpoint)
                } else {
                    try await store.scheduledTasks.update(task, endpoint: store.endpoint)
                }
                dismiss()
            } catch {
                store.errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}
