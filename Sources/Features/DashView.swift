import SwiftUI

struct DashView: View {
    @EnvironmentObject private var store: RemoteCodexStore

    private var activeCount: Int { store.threads.filter { $0.activity == .active }.count }
    private var completedCount: Int { store.threads.filter { $0.activity == .idle }.count }
    private var failedCount: Int { store.threads.filter { $0.activity == .systemError }.count }

    var body: some View {
        ZStack {
            AmbientBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: DS.spacingMD) {
                    connectionCard
                    summaryGrid
                    runtimeCard
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .refreshable {
                await store.refreshThreads()
                await store.refreshRuntimeInfo()
            }
        }
        .navigationTitle("Dash")
        .task {
            var tick = 0
            while !Task.isCancelled {
                await store.refreshThreads()
                if tick % 3 == 0 { await store.refreshRuntimeInfo() }
                tick += 1
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: store.connectionState.isConnected ? "checkmark.circle.fill" : "wifi.exclamationmark")
                    .font(.title2)
                    .foregroundStyle(store.connectionState.isConnected ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.connectionState.isConnected ? "Mac 已连接" : "Mac 未连接")
                        .font(.headline)
                    Text(store.endpoint.host + ":" + String(store.endpoint.port))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task {
                        await store.refreshThreads()
                        await store.refreshRuntimeInfo()
                    }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(!store.connectionState.isConnected)
            }
            Text("Dash 只展示运行信息；对话内容请在“对话”Tab 查看。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .glassSurface(radius: DS.radiusMD)
    }

    private var summaryGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: DS.spacingSM)], spacing: DS.spacingSM) {
            DashMetricCard(title: "运行中", value: activeCount, systemImage: "sparkles", color: .orange)
            DashMetricCard(title: "已完成", value: completedCount, systemImage: "checkmark.circle.fill", color: .green)
            DashMetricCard(title: "异常", value: failedCount, systemImage: "exclamationmark.triangle.fill", color: .red)
            DashMetricCard(title: "对话总数", value: store.threads.count, systemImage: "bubble.left.and.bubble.right", color: .accentColor)
        }
    }

    private var runtimeCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("远端运行环境", systemImage: "desktopcomputer")
                .font(.headline)
                .padding(.bottom, 10)

            RuntimeInfoRow(label: "远端 CodeAnywhere", value: store.scheduledTasks.runtimeInfo?.codeAnywhereVersion ?? "未获取")
            RuntimeInfoRow(label: "远端 Codex CLI", value: store.scheduledTasks.runtimeInfo?.codexVersion ?? "未获取")
            RuntimeInfoRow(label: "远端系统", value: store.scheduledTasks.runtimeInfo.map { "\($0.operatingSystem) · \($0.architecture)" } ?? "未获取")
            RuntimeInfoRow(label: "app-server", value: store.scheduledTasks.runtimeInfo?.appServerPort.map(String.init) ?? String(store.endpoint.port))
            RuntimeInfoRow(label: "Task 服务", value: store.scheduledTasks.runtimeInfo?.taskServicePort.map(String.init) ?? "端口 + 1")
            RuntimeInfoRow(label: "本机 iOS 客户端", value: CodeAnywhereClientInfo.version)
        }
        .padding(14)
        .glassSurface(radius: DS.radiusMD)
    }
}

private struct RuntimeInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .font(.caption)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Divider().opacity(0.35) }
    }
}

private enum CodeAnywhereClientInfo {
    static var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (version, build) {
        case let (.some(version), .some(build)): return "版本 \(version)（\(build)）"
        case let (.some(version), .none): return "版本 \(version)"
        case let (.none, .some(build)): return "构建 \(build)"
        default: return "未知"
        }
    }
}

private struct DashMetricCard: View {
    let title: String
    let value: Int
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(color)
                .frame(width: 38, height: 38)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(value, format: .number)
                    .font(.title2.bold().monospacedDigit())
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .glassSurface(radius: DS.radiusMD)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(value)")
    }
}
