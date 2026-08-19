import SwiftUI

/// 项目运行输出面板：实时展示 Alpine 内进程的 stdout/stderr。
/// 由 ServiceStatusBar 的「控制台」按钮弹出。
struct RunConsoleView: View {
    @ObservedObject var launcher: RuntimeLauncher
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBanner
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(launcher.lines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(color(for: line))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(10)
                    }
                    .onChange(of: launcher.lines.count) { _ in
                        if let last = launcher.lines.indices.last {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(last, anchor: .bottom)
                            }
                        }
                    }
                    .background(Color(red: 0.07, green: 0.07, blue: 0.09))
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle("运行输出")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(launcher.phase == .running ? "停止" : "重新运行") {
                        if launcher.phase == .running {
                            launcher.stop()
                        } else {
                            launcher.start()
                        }
                    }
                    .disabled(launcher.isInstalling)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var statusBanner: some View {
        HStack(spacing: 8) {
            Group {
                switch launcher.phase {
                case .idle, .preparing: ProgressView().scaleEffect(0.8)
                case .running: Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                case .exited: Image(systemName: "stop.circle").foregroundColor(.gray)
                case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                }
            }
            Text(launcher.statusTitle)
                .font(.caption)
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
            Spacer()
            if launcher.isInstalling {
                Text("apk 安装中…")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.06))
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("[yuix]") { return .blue }
        if line.lowercased().contains("error") || line.lowercased().contains("traceback") {
            return Color(red: 0.95, green: 0.45, blue: 0.45)
        }
        if line.lowercased().contains("warning") { return .yellow }
        return Color(red: 0.88, green: 0.89, blue: 0.91)
    }
}
