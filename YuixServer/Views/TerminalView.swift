import SwiftUI
import UIKit

/// 真实 Alpine Linux 终端（内核内置，非沙盒模拟）。
///
/// - 启动时自动引导内核；首次启动展示 rootfs 导入进度
/// - 控制台输出经 VT100 渲染（颜色 / 光标 / 清屏）
/// - 隐藏输入框捕获键盘：每个字符原样发往 guest 的 tty（含 Tab 补全）
/// - 工具栏提供 Ctrl-C / Tab / 方向键 / Esc（iOS 键盘打不出这些键）
struct TerminalView: View {
    @EnvironmentObject var store: ProjectStore
    @ObservedObject private var runtime = LinuxRuntime.shared
    @State private var consoleModel = ConsoleModel()
    @FocusState private var keyboardFocused: Bool
    @State private var showAdmin = false
    @State private var showReinstallConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
            consoleArea
            toolbar
        }
        .background(Color(red: 0.07, green: 0.07, blue: 0.09).opacity(0.92))
        .onAppear {
            consoleModel.start()
            runtime.bootIfNeeded()
        }
        .onDisappear {
            consoleModel.stop()
        }
        .sheet(isPresented: $showAdmin) {
            LinuxAdminView()
                .presentationDetents([.large])
        }
        .confirmationDialog("重装 Alpine Linux？", isPresented: $showReinstallConfirm, titleVisibility: .visible) {
            Button("抹掉并重装", role: .destructive) { runtime.reinstallRootfs() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("从内置镜像完整重装系统，项目文件不受影响。")
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal.fill")
                .foregroundColor(.green)
            Text("Alpine Linux · aarch64")
                .font(.caption2.monospaced())
                .foregroundColor(.white.opacity(0.55))
            Spacer()
            statusBadge
            Button {
                showAdmin = true
            } label: {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("系统管理：更新/升级/修复/重装")
            Button {
                consoleModel.reset()
            } label: {
                Image(systemName: "trash").foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("清空终端")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch runtime.state {
        case .idle:
            Label("待启动", systemImage: "circle.dotted")
                .font(.caption2).foregroundColor(.white.opacity(0.5))
        case .importingRootfs(let p):
            Label(String(format: "解压 rootfs %.0f%%", p * 100), systemImage: "arrow.down.doc")
                .font(.caption2).foregroundColor(.orange)
        case .bootingKernel:
            Label("启动内核…", systemImage: "cpu")
                .font(.caption2).foregroundColor(.blue)
        case .ready:
            Label("运行中", systemImage: "checkmark.circle.fill")
                .font(.caption2).foregroundColor(.green)
        case .failed(let msg):
            Label("失败：\(msg)", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2).foregroundColor(.red)
                .lineLimit(1)
        }
    }

    // MARK: - 控制台

    private var consoleArea: some View {
        GeometryReader { geo in
            ZStack(alignment: .center) {
                if runtime.isReady {
                    ConsoleTextView(model: consoleModel, focused: $keyboardFocused)
                        .onTapGesture { keyboardFocused = true }
                } else {
                    bootingOverlay
                }
            }
            .onChange(of: geo.size.width) { w in
                consoleModel.updateWidth(w)
            }
            .onAppear {
                consoleModel.updateWidth(geo.size.width)
            }
        }
    }

    private var bootingOverlay: some View {
        VStack(spacing: 14) {
            ProgressView()
                .scaleEffect(1.1)
            switch runtime.state {
            case .idle:
                Text("正在准备 Alpine Linux…").font(.caption).foregroundColor(.white.opacity(0.6))
            case .importingRootfs(let p):
                VStack(spacing: 6) {
                    Text("首次启动：正在解压 Alpine rootfs").font(.caption).foregroundColor(.white.opacity(0.7))
                    ProgressView(value: p)
                        .frame(width: 220)
                }
            case .bootingKernel:
                Text("正在启动 Linux 内核…").font(.caption).foregroundColor(.white.opacity(0.6))
            case .failed(let msg):
                VStack(spacing: 12) {
                    Text("启动失败：\(msg)")
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    // 100% 保障闭环：安装阶段失败 → 重试自愈；顽固问题 → 一键重装
                    HStack(spacing: 10) {
                        Button {
                            runtime.retryBoot()
                        } label: {
                            Label("重试", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)

                        Button(role: .destructive) {
                            showReinstallConfirm = true
                        } label: {
                            Label("重装系统", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                    Text("安装采用「临时目录 → 完整性校验 → 原子上线」三段式，重试/重装不会留下半成品系统。")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.4))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            default:
                EmptyView()
            }
        }
    }

    // MARK: - 工具栏（iOS 键盘缺失的控制键）

    private var toolbar: some View {
        HStack(spacing: 6) {
            keyButton("^C", data: "\u{03}")        // Ctrl-C
            keyButton("Tab", data: "\t")           // Tab 补全
            keyButton("↑", data: "\u{1B}[A")       // 上（历史）
            keyButton("↓", data: "\u{1B}[B")       // 下
            keyButton("←", data: "\u{1B}[D")       // 左
            keyButton("→", data: "\u{1B}[C")       // 右
            keyButton("Esc", data: "\u{1B}")
            Spacer()
            Button {
                keyboardFocused.toggle()
            } label: {
                Image(systemName: keyboardFocused ? "keyboard.chevron.compact.down" : "keyboard")
                    .foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.05))
    }

    private func keyButton(_ title: String, data: String) -> some View {
        Button {
            runtime.sendConsoleInput(data)
            keyboardFocused = true
        } label: {
            Text(title)
                .font(.caption2.monospaced().bold())
                .foregroundColor(.white.opacity(0.8))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 控制台模型

@MainActor
final class ConsoleModel: ObservableObject {
    private let vt = VT100()
    private var token: NSNumber?
    private var pendingData = Data()
    private var renderTask: Task<Void, Never>?
    private var lastRender = Date.distantPast
    private(set) var isRunning = false

    let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    /// 渲染回调（ConsoleTextView 持有）
    var onRender: (() -> Void)?

    func start() {
        guard !isRunning else { return }
        isRunning = true
        token = LinuxRuntime.shared.addConsoleOutputHandler { [weak self] data in
            // handler 在引擎的私有队列上回调，切回主 actor 合并数据
            Task { @MainActor [weak self] in
                self?.receive(data)
            }
        }
    }

    func stop() {
        LinuxRuntime.shared.removeConsoleOutputHandler(token)
        token = nil
        isRunning = false
    }

    func reset() {
        vt.feed(Data("\u{1B}[2J\u{1B}[H".utf8))
        onRender?()
    }

    private func receive(_ data: Data) {
        pendingData.append(data)
        scheduleRender()
    }

    /// 合并高频输出：最多每 50ms 渲染一次，避免 byte 级 UI 抖动
    private func scheduleRender() {
        guard renderTask == nil else { return }
        renderTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard let self else { return }
            self.renderTask = nil
            guard !self.pendingData.isEmpty else { return }
            let chunk = self.pendingData
            self.pendingData.removeAll()
            self.vt.feed(chunk)
            self.lastRender = Date()
            self.onRender?()
        }
    }

    private var updateWidthTask: Task<Void, Never>?

    func updateWidth(_ width: CGFloat) {
        updateWidthTask?.cancel()
        updateWidthTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000) // 防抖
            guard let self, !Task.isCancelled else { return }
            let charWidth = self.vtCharWidth
            let cols = max(20, Int(width / charWidth))
            LinuxRuntime.shared.setConsoleSize(cols: cols, rows: 40)
        }
    }

    private var vtCharWidth: CGFloat {
        ("0" as NSString).size(withAttributes: [.font: font]).width
    }

    var attributedContent: NSAttributedString {
        vt.attributedString(baseFont: font)
    }
}

// MARK: - UITextView 封装

struct ConsoleTextView: UIViewRepresentable {
    @ObservedObject var model: ConsoleModel
    @FocusState.Binding var focused: Bool

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.backgroundColor = .clear
        tv.isEditable = false
        tv.isSelectable = true
        tv.showsVerticalScrollIndicator = true
        tv.contentInsetAdjustmentBehavior = .never
        tv.attributedText = model.attributedContent
        tv.layoutManager.allowsNonContiguousLayout = false

        // 隐藏输入代理：捕获物理/软件键盘的每个按键
        let proxy = UITextField(frame: CGRect(x: 0, y: -100, width: 10, height: 10))
        proxy.autocorrectionType = .no
        proxy.autocapitalizationType = .none
        proxy.spellCheckingType = .no
        proxy.smartInsertDeleteType = .no
        proxy.keyboardType = .default
        proxy.delegate = context.coordinator
        tv.addSubview(proxy)
        context.coordinator.proxy = proxy

        model.onRender = { [weak tv, weak model] in
            guard let tv, let model else { return }
            let pos = tv.contentOffset.y
            let atBottom = pos >= tv.contentSize.height - tv.frame.height - 60
            let sel = tv.selectedRange
            tv.attributedText = model.attributedContent
            tv.selectedRange = sel
            if atBottom {
                let target = max(0, tv.contentSize.height - tv.frame.height + tv.contentInset.bottom)
                tv.setContentOffset(CGPoint(x: 0, y: target), animated: false)
            }
        }
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        focused = context.coordinator.proxy?.isFirstResponder ?? false
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        weak var proxy: UITextField?

        func textField(_ textField: UITextField,
                       shouldChangeCharactersIn range: NSRange,
                       replacementString string: String) -> Bool {
            guard !string.isEmpty else {
                // 删除键：DEL (0x7F)
                LinuxRuntime.shared.sendConsoleInput(Data([0x7F]))
                return false
            }
            LinuxRuntime.shared.sendConsoleInput(string)
            return false // 不显示在代理输入框里（tty 自己会回显）
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            LinuxRuntime.shared.sendConsoleInput("\n")
            return false
        }
    }
}
