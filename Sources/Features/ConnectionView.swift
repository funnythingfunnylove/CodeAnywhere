import SwiftUI

struct ConnectionView: View {
    @EnvironmentObject private var store: RemoteCodexStore
    @State private var host = ""
    @State private var port = ""
    @FocusState private var focusedField: Field?

    private enum Field { case host, port }

    var body: some View {
        ZStack {
            AmbientBackground()
            ScrollView {
                VStack(spacing: DS.spacingXL) {
                    Spacer(minLength: 64)
                    brand
                    connectionPanel
                    Text("同一局域网 · 无账号 · 无密码")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, DS.spacingLG)
                .padding(.bottom, DS.spacingXL)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear {
            host = store.endpoint.host
            port = String(store.endpoint.port)
        }
    }

    private var brand: some View {
        VStack(spacing: DS.spacingMD) {
            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Color.accentColor.gradient)
                    .frame(width: 88, height: 88)
                    .shadow(color: Color.accentColor.opacity(0.35), radius: 24, y: 12)
                Image(systemName: "terminal.fill")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(spacing: DS.spacingSM) {
                Text("CodeAnywhere")
                    .font(.largeTitle.bold())
                Text("把桌面端 Codex 放进口袋")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var connectionPanel: some View {
        VStack(alignment: .leading, spacing: DS.spacingLG) {
            VStack(alignment: .leading, spacing: DS.spacingXS) {
                Text("连接桌面端")
                    .font(.title2.bold())
                Text("输入运行 Codex app-server 的电脑地址")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: DS.spacingMD) {
                LabeledContent("IP 地址") {
                    TextField("192.168.1.10", text: $host)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                        .focused($focusedField, equals: .host)
                        .accessibilityLabel("桌面端 IP 地址")
                }
                Divider()
                LabeledContent("端口") {
                    TextField("4500", text: $port)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                        .focused($focusedField, equals: .port)
                        .accessibilityLabel("桌面端端口")
                }
            }
            .padding(DS.spacingMD)
            .contentCard()

            Button {
                focusedField = nil
                store.updateActiveEndpoint(ServerEndpoint(host: host, port: Int(port) ?? 0))
                Task { await store.connect() }
            } label: {
                HStack {
                    if store.connectionState == .connecting {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "network")
                    }
                    Text(store.connectionState == .connecting ? "正在连接…" : "连接")
                }
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Color.accentColor.gradient, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(store.connectionState == .connecting || host.isEmpty || port.isEmpty)

            if case .failed(let message) = store.connectionState {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.spacingLG)
        .glassSurface()
    }
}
