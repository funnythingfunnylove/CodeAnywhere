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
    @State private var selectedTask: ScheduledTask?

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
                List {
                    Section {
                        executionNotice
                    }
                    Section("定时任务") {
                        ForEach(taskStore.tasks) { task in
                            ScheduledTaskListRow(
                                task: task,
                                onOpen: { selectedTask = task },
                                onEnabledChange: { enabled in
                                    update(task, enabled: enabled)
                                },
                                onDelete: { delete(task) },
                                onEdit: { editingTask = task }
                            )
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
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
        .navigationDestination(item: $selectedTask) { task in
            ScheduledTaskDetailView(task: task)
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

private struct ScheduledTaskListRow: View {
    let task: ScheduledTask
    let onOpen: () -> Void
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
        HStack(spacing: 10) {
            Button(action: onOpen) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: task.schedule.kind == .cron ? "calendar.badge.clock" : "clock.arrow.circlepath")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 36, height: 36)
                        .background(
                            Color.accentColor.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        Text(task.schedule.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(task.executionState.title)
                            Text("·")
                            Text(task.cwd)
                                .font(.caption2.monospaced())
                                .lineLimit(1)
                        }
                        .font(.caption2)
                        .foregroundStyle(stateColor)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle("启用", isOn: Binding(
                get: { task.isEnabled },
                set: onEnabledChange
            ))
            .labelsHidden()
            .frame(width: 44)

            Menu {
                Button("编辑", systemImage: "pencil", action: onEdit)
                Button("删除", systemImage: "trash", role: .destructive, action: {
                    showingDeleteConfirmation = true
                })
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("管理 \(task.title)")
        }
        .opacity(task.isEnabled ? 1 : 0.68)
        .accessibilityElement(children: .contain)
        .alert("删除定时任务？", isPresented: $showingDeleteConfirmation) {
            Button("删除", role: .destructive, action: onDelete)
            Button("取消", role: .cancel) { }
        } message: {
            Text("“\(task.title)”将从 Mac 的任务列表中删除。")
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4))
        .listRowSeparator(.visible)
    }
}

private struct ScheduledTaskDetailView: View {
    @EnvironmentObject private var store: RemoteCodexStore
    @Environment(\.dismiss) private var dismiss
    let task: ScheduledTask
    @State private var draftTask: ScheduledTask
    @State private var showingEditor = false
    @State private var showingDeleteConfirmation = false

    init(task: ScheduledTask) {
        self.task = task
        _draftTask = State(initialValue: task)
    }

    var body: some View {
        List {
            Section("任务") {
                LabeledContent("名称", value: draftTask.title)
                LabeledContent("项目路径") {
                    Text(draftTask.cwd)
                        .font(.caption.monospaced())
                        .multilineTextAlignment(.trailing)
                }
                Toggle("启用", isOn: enabledBinding)
            }
            Section("计划") {
                LabeledContent("类型", value: draftTask.schedule.kind.title)
                LabeledContent("规则", value: draftTask.schedule.summary)
                if let nextRunAt = draftTask.nextRunAt, draftTask.isEnabled {
                    LabeledContent("下次执行") {
                        Text(nextRunAt, format: .dateTime.month().day().hour().minute())
                    }
                }
            }
            Section("执行") {
                LabeledContent("状态", value: draftTask.executionState.title)
                if let lastRunAt = draftTask.lastRunAt {
                    LabeledContent("上次执行") {
                        Text(lastRunAt, format: .dateTime.month().day().hour().minute())
                    }
                }
                if let message = draftTask.executionMessage, !message.isEmpty {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(draftTask.executionState == .failed ? .red : .secondary)
                }
            }
            Section("提示词") {
                Text(draftTask.prompt)
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("任务详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("编辑", systemImage: "pencil") { showingEditor = true }
                    Button("删除", systemImage: "trash", role: .destructive) {
                        showingDeleteConfirmation = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("管理任务")
            }
        }
        .sheet(isPresented: $showingEditor) {
            ScheduledTaskEditorView(task: draftTask)
        }
        .onChange(of: store.scheduledTasks.tasks) { _, tasks in
            if let latest = tasks.first(where: { $0.id == draftTask.id }) {
                draftTask = latest
            }
        }
        .alert("删除定时任务？", isPresented: $showingDeleteConfirmation) {
            Button("删除", role: .destructive) { delete() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("“\(draftTask.title)”将从 Mac 的任务列表中删除。")
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { draftTask.isEnabled },
            set: { enabled in
                draftTask.isEnabled = enabled
                Task {
                    do {
                        try await store.scheduledTasks.update(draftTask, endpoint: store.endpoint)
                    } catch {
                        store.errorMessage = error.localizedDescription
                    }
                }
            }
        )
    }

    private func delete() {
        Task {
            do {
                try await store.scheduledTasks.delete(id: draftTask.id, endpoint: store.endpoint)
                dismiss()
            } catch {
                store.errorMessage = error.localizedDescription
            }
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
