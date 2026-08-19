import SwiftUI

/// 端口测试面板：输入 主机:端口 发起 TCP 握手，查看开放/拒绝/超时，
/// 并可一键检测当前项目的本机服务端口。
struct PortTestView: View {
    @EnvironmentObject var store: ProjectStore
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var portText = ""
    @State private var testing = false
    @State private var history: [PortTestService.Outcome] = []

    private var portNumber: UInt16? {
        guard let n = UInt16(portText), n > 0 else { return nil }
        return n
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("目标") {
                    TextField("主机（IP 或域名）", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("端口（1-65535）", text: $portText)
                        .keyboardType(.numberPad)
                    Button(testing ? "测试中…" : "开始测试") { run() }
                        .disabled(testing || !isInputValid)
                    if let project = store.activeProject {
                        Button("测本机服务 :\(project.port)（\(project.name)）") {
                            host = "127.0.0.1"
                            portText = String(project.port)
                            run()
                        }
                        .disabled(testing)
                    }
                }

                if !history.isEmpty {
                    Section("最近结果") {
                        ForEach(history.reversed()) { item in
                            row(item)
                        }
                        Button("清空记录", role: .destructive) { history = [] }
                    }
                }
            }
            .navigationTitle("端口测试")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
            }
        }
    }

    private var isInputValid: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && portNumber != nil
    }

    private func row(_ item: PortTestService.Outcome) -> some View {
        HStack {
            Image(systemName: iconName(item.result))
                .foregroundColor(color(item.result))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(item.host):\(item.port)")
                    .font(.caption.monospaced())
                Text(label(item.result))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    private func run() {
        guard let port = portNumber else { return }
        let target = host.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        testing = true
        Task {
            let outcome = await PortTestService.test(host: target, port: port)
            history.append(outcome)
            testing = false
        }
    }

    private func iconName(_ result: PortTestService.ResultKind) -> String {
        switch result {
        case .open:    return "checkmark.circle.fill"
        case .closed:  return "xmark.circle.fill"
        case .timeout: return "exclamationmark.triangle.fill"
        }
    }

    private func color(_ result: PortTestService.ResultKind) -> Color {
        switch result {
        case .open:    return .green
        case .closed:  return .red
        case .timeout: return .orange
        }
    }

    private func label(_ result: PortTestService.ResultKind) -> String {
        switch result {
        case .open(let ms):    return "开放 · \(Int(ms.rounded())) ms"
        case .closed:          return "无法连接（拒绝或未监听）"
        case .timeout:         return "超时（3 秒无响应）"
        }
    }
}
