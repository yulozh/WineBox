import SwiftUI

/// 内置终端视图（毛玻璃暗色主题）。
/// 在沙盒内执行 ShellService 提供的轻量命令，与当前项目 cwd 联动。
/// 完整 Linux 命令环境请点顶部「Alpine」通过 LinuxEnvironment 打开 iSH。
struct TerminalView: View {
    @EnvironmentObject var store: ProjectStore
    @State private var input = ""
    @State private var lines: [String] = []
    @FocusState private var focused: Bool
    private let prompt = "yuix$"

    /// 终端工作目录 = 当前项目目录（无项目则用根目录）
    private var cwd: URL {
        if let p = store.activeProject { return store.projectURL(p) }
        return store.rootURL
    }

    var body: some View {
        VStack(spacing: 0) {
            terminalHeader
            Divider().background(Color.white.opacity(0.15))
            outputArea
            inputBar
        }
        .background(Color.black.opacity(0.38))
        .onAppear(perform: warmUp)
    }

    // MARK: - 头部（信号灯 + 路径 + 打开 Alpine）

    private var terminalHeader: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(red: 1.00, green: 0.38, blue: 0.35)).frame(width: 12, height: 12)
            Circle().fill(Color(red: 1.00, green: 0.78, blue: 0.27)).frame(width: 12, height: 12)
            Circle().fill(Color(red: 0.32, green: 0.84, blue: 0.44)).frame(width: 12, height: 12)
            Spacer()
            Text("bash ~/\(cwd.lastPathComponent)")
                .font(.caption2.monospaced())
                .foregroundColor(.white.opacity(0.55))
            Button { lines = []; warmUp() } label: {
                Image(systemName: "trash").foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("清空终端")

            Button { LinuxEnvironment.open() } label: {
                Label("Alpine", systemImage: "terminal.fill")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .disabled(!LinuxEnvironment.isAvailable)
            .help(LinuxEnvironment.isAvailable ? "打开 iSH（Alpine Linux）" : "未安装 iSH，请先从 App Store 安装")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - 输出区

    private var outputArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(line.hasPrefix("exit ") ? .red : .white.opacity(0.9))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // 滚动锚点
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(10)
            }
            .onChange(of: lines) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    // MARK: - 输入栏

    private var inputBar: some View {
        HStack(spacing: 8) {
            Text("$")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(.green)
            TextField("输入命令（如 ls）", text: $input)
                .font(.system(size: 13, design: .monospaced))
                .textFieldStyle(.plain)
                .foregroundColor(.white)
                .focused($focused)
                .onSubmit(runCommand)
        }
        .padding(10)
        .background(Color.white.opacity(0.05))
    }

    // MARK: - 逻辑

    private func warmUp() {
        lines = [
            "YuixServer 内置终端（沙盒模式）",
            "输入 help 查看可用命令；完整 Linux 请点右上角「Alpine」。",
            ""
        ]
        let r = ShellService.execute("pwd", cwd: cwd)
        if !r.output.isEmpty { lines.append(r.output) }
        lines.append("")
    }

    private func runCommand() {
        let cmd = input.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("\(prompt) \(input)")
        input = ""
        guard !cmd.isEmpty else { return }
        if cmd == "clear" { lines = []; return }

        let result = ShellService.execute(cmd, cwd: cwd)
        if !result.output.isEmpty {
            lines.append(contentsOf: result.output.components(separatedBy: "\n"))
        }
        if result.status != 0 {
            lines.append("exit \(result.status)")
        }
    }
}