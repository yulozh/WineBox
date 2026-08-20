import SwiftUI

/// Linux 系统管理面板：状态总览 + 包管理（检查更新/升级/修复）+ 应急重装。
/// 所有 apk 操作在真实 Alpine 内执行，输出实时回流到本面板。
struct LinuxAdminView: View {
    @ObservedObject private var runtime = LinuxRuntime.shared
    @Environment(\.dismiss) private var dismiss

    @State private var outputLines: [String] = []
    @State private var busy = false
    @State private var lastResult: String?
    @State private var showReinstallConfirm = false
    @AppStorage("linux.httpMirror") private var httpMirror = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.12))
            statusCard
                .padding(.horizontal, 14)
                .padding(.top, 12)
            actions
                .padding(.horizontal, 14)
                .padding(.top, 12)
            consoleHeader
                .padding(.horizontal, 14)
                .padding(.top, 14)
            console
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
        }
        .background(Color(red: 0.07, green: 0.07, blue: 0.09).opacity(0.96))
        .onAppear {
            runtime.bootIfNeeded()
            runtime.refreshSystemInfo()
        }
        .onChange(of: runtime.isReady) { ready in
            if ready { runtime.refreshSystemInfo() }
        }
        .confirmationDialog("重装 Alpine Linux？", isPresented: $showReinstallConfirm, titleVisibility: .visible) {
            Button("抹掉并重装", role: .destructive) {
                append("[yuix] 开始重装 Alpine Linux …")
                runtime.reinstallRootfs()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除已安装的 rootfs 并从内置镜像完整重装。内核运行中时会拒绝操作（需重启 App）。项目文件不受影响（存放在独立目录）。")
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .foregroundColor(.accentColor)
            Text("Linux 系统管理")
                .font(.headline)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - 状态卡

    private var statusCard: some View {
        VStack(spacing: 8) {
            HStack {
                stateBadge
                Spacer()
                Label(runtime.alpineRelease.map { "Alpine \($0)" } ?? "Alpine Linux",
                      systemImage: "linuxlogo")
                    .font(.caption.monospaced())
                    .foregroundColor(.white.opacity(0.7))
            }
            if case .importingRootfs(let p) = runtime.state {
                ProgressView(value: p)
                    .tint(.orange)
                Text(String(format: "安装进度 %.0f%%", p * 100))
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.6))
            }
            if case .failed(let msg) = runtime.state {
                Text(msg)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(3)
            }
            HStack(spacing: 16) {
                infoItem("rootfs 占用", LinuxRuntime.rootfsSize().formattedBytes)
                infoItem("可用空间", LinuxRuntime.freeDisk().map(\.formattedBytes) ?? "—")
                infoItem("镜像协议", httpMirror ? "HTTP 兼容" : "HTTPS")
            }
            .frame(maxWidth: .infinity)
        }
        .padding(12)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch runtime.state {
        case .idle:
            Label("待安装", systemImage: "circle.dotted").font(.caption).foregroundColor(.white.opacity(0.5))
        case .importingRootfs:
            Label("安装中", systemImage: "arrow.down.doc").font(.caption).foregroundColor(.orange)
        case .bootingKernel:
            Label("启动内核", systemImage: "cpu").font(.caption).foregroundColor(.blue)
        case .ready:
            Label("运行中", systemImage: "checkmark.circle.fill").font(.caption).foregroundColor(.green)
        case .failed:
            Label("失败", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundColor(.red)
        }
    }

    private func infoItem(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption2).foregroundColor(.white.opacity(0.45))
            Text(value).font(.caption.monospaced()).foregroundColor(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 操作区

    private var actions: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                actionButton("检查更新", icon: "arrow.triangle.2.circlepath",
                             disabled: !runtime.isReady || busy) {
                    runApk("apk update --no-progress", title: "检查更新")
                }
                actionButton("一键升级", icon: "arrow.up.circle.fill",
                             disabled: !runtime.isReady || busy) {
                    runApk("apk upgrade --no-progress --no-interactive", title: "系统升级")
                }
            }
            HStack(spacing: 8) {
                actionButton("修复系统", icon: "wrench.and.screwdriver",
                             disabled: !runtime.isReady || busy) {
                    runApk("apk fix --no-progress", title: "修复依赖")
                }
                actionButton("已装软件", icon: "shippingbox",
                             disabled: !runtime.isReady || busy) {
                    runApk("apk info", title: "已安装软件包")
                }
            }
            if case .failed = runtime.state {
                Button {
                    append("[yuix] 重试安装/引导 …")
                    runtime.retryBoot()
                } label: {
                    Label("重试安装", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .padding(.top, 2)
            }
            Button(role: .destructive) {
                showReinstallConfirm = true
            } label: {
                Label("重装系统", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(busy || runtime.kernelStartedFlag)
        }
    }

    private func actionButton(_ title: String, icon: String, disabled: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(disabled)
    }

    // MARK: - 输出控制台

    private var consoleHeader: some View {
        HStack {
            Text("输出")
                .font(.caption.bold())
                .foregroundColor(.white.opacity(0.5))
            Spacer()
            if busy { ProgressView().scaleEffect(0.7) }
            if let r = lastResult {
                Text(r).font(.caption2.monospaced()).foregroundColor(.white.opacity(0.45))
            }
            Button {
                outputLines.removeAll()
                lastResult = nil
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
    }

    private var console: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if outputLines.isEmpty {
                        Text("apk 操作输出将显示在这里")
                            .font(.caption.monospaced())
                            .foregroundColor(.white.opacity(0.3))
                            .padding(.top, 24)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(Array(outputLines.enumerated()), id: \.offset) { idx, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundColor(colorFor(line))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(idx)
                    }
                }
                .padding(10)
            }
            .frame(minHeight: 150, maxHeight: 320)
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            .onChange(of: outputLines.count) { _ in
                if let last = outputLines.indices.last {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    private func colorFor(_ line: String) -> Color {
        if line.hasPrefix("[yuix]") { return .accentColor }
        if line.contains("ERROR") || line.contains("error") { return .red }
        if line.hasPrefix("OK:") || line.hasPrefix("OK ") { return .green }
        return .white.opacity(0.8)
    }

    // MARK: - 命令执行

    private func runApk(_ command: String, title: String) {
        guard !busy else { return }
        busy = true
        lastResult = nil
        append("[yuix] \(title)：\(command)")
        let start = Date()
        runtime.run(command, lineCallback: { line, isError in
            append(isError ? "✗ \(line)" : line)
        }, completion: { [self] result in
            busy = false
            let seconds = Date().timeIntervalSince(start)
            if result.exitCode == 0 {
                lastResult = "退出码 0 · \(String(format: "%.1f", seconds))s"
                append("[yuix] \(title) 完成")
            } else {
                lastResult = "失败 退出码 \(result.exitCode)"
                append("[yuix] \(title) 失败（退出码 \(result.exitCode)）")
            }
        })
    }

    private func append(_ line: String) {
        // 上限 2000 行，超出丢最旧（与终端缓冲策略一致）
        outputLines.append(line)
        if outputLines.count > 2000 {
            outputLines.removeFirst(outputLines.count - 2000)
        }
    }
}

// MARK: - 字节格式化

extension Int64 {
    var formattedBytes: String {
        guard self > 0 else { return "0 B" }
        let units: [(Double, String)] = [(1, "B"), (1024, "KB"), (1024 * 1024, "MB"), (1024 * 1024 * 1024, "GB")]
        var chosen = units[0]
        for u in units where Double(self) >= u.0 { chosen = u }
        let value = Double(self) / chosen.0
        return String(format: "%.1f %@", value, chosen.1)
    }
}

// MARK: - kernelStarted 便捷访问（避免 Swift 直接持有 ObjC 单例属性）

extension LinuxRuntime {
    /// 内核是否已启动（决定能否原地重装）
    var kernelStartedFlag: Bool {
        YXLinuxBoot.shared().kernelStarted
    }
}
