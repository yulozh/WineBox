import Foundation
import SwiftUI

/// 在内置 Alpine Linux 中真实运行 Python / Node.js / PHP 项目。
///
/// 与旧的 JSC 模拟不同，这里跑的是真进程：
/// 1. 自动引导内核（首次启动解压 rootfs，进度见 LinuxRuntime）
/// 2. 运行时缺失时自动 `apk add --no-cache <pkg>`（需网络，一次安装永久可用）
/// 3. 以独立 guest 进程运行入口文件，stdout / stderr 流式回传
/// 4. guest 内监听的端口经引擎映射为宿主真实端口（局域网可访问）
///
/// 一个项目一个实例，由 ProjectStore 持有；输出面板见 RunConsoleView。
@MainActor
final class RuntimeLauncher: ObservableObject, Identifiable {

    enum Phase: Equatable {
        case idle
        case preparing(String)
        case running
        case exited(Int)
        case failed(String)
    }

    nonisolated let id: UUID
    private let project: Project
    private let guestCWD: String

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lines: [String] = []
    @Published private(set) var isInstalling = false

    /// 进程真正跑起来 / 退出时回调（ProjectStore 借此更新服务状态）
    var onRunning: (() -> Void)?
    var onExited: ((Int) -> Void)?

    private var guestPID = -1
    private static let maxLines = 600

    init(project: Project, guestCWD: String) {
        self.project = project
        self.guestCWD = guestCWD
        self.id = project.id
    }

    var statusTitle: String {
        switch phase {
        case .idle: return "待启动"
        case .preparing(let s): return s
        case .running: return "运行中"
        case .exited(let code): return "已退出 (exit \(code))"
        case .failed(let s): return "失败：\(s)"
        }
    }

    // MARK: - 启动

    func start() {
        // 已在运行/安装中则忽略；退出或失败后允许重新运行
        switch phase {
        case .preparing, .running:
            return
        case .idle, .exited, .failed:
            break
        }
        guard let spec = runtimeSpec else {
            phase = .failed("静态项目由内置 HTTP 服务器直接提供，无需运行时")
            return
        }

        lines.removeAll()
        guestPID = -1

        append("[yuix] 启动 \(project.name) · \(project.language.rawValue)")
        append("[yuix] 工作目录 \(guestCWD)")
        append("[yuix] 端口 \(project.port)")

        // 1) 运行时已安装？
        phase = .preparing("检查 \(spec.binary)")
        let pid = LinuxRuntime.shared.run("command -v \(spec.binary)", completion: { [weak self] result in
            guard let self else { return }
            if result.exitCode == 0 {
                self.launch(spec)
            } else {
                self.installThenLaunch(spec)
            }
        })
        if pid < 0 {
            phase = .failed("Linux 内核未就绪（code \(pid)），请稍后重试")
        }
    }

    private func installThenLaunch(_ spec: RuntimeSpec) {
        isInstalling = true
        phase = .preparing("安装 \(spec.package)（需网络）")
        append("[yuix] 运行时未安装，执行 apk add --no-cache \(spec.package) …")

        let pid = LinuxRuntime.shared.run(
            "apk add --no-cache \(spec.package)",
            lineCallback: { [weak self] line, _ in self?.append(line) },
            completion: { [weak self] result in
                guard let self else { return }
                self.isInstalling = false
                if result.exitCode != 0 {
                    self.phase = .failed("安装 \(spec.package) 失败（exit \(result.exitCode)），请检查网络后重试")
                    self.onExited?(result.exitCode)
                    return
                }
                self.append("[yuix] 安装完成")
                self.launch(spec)
            }
        )
        if pid < 0 {
            isInstalling = false
            phase = .failed("Linux 内核未就绪（code \(pid)）")
        }
    }

    private func launch(_ spec: RuntimeSpec) {
        phase = .preparing("启动 \(spec.binary) \(spec.entry)")
        let pid = LinuxRuntime.shared.run(
            "\(spec.binary) \(spec.entry)",
            workingDirectory: guestCWD,
            environment: ["PORT": String(project.port), "HOST": "0.0.0.0"],
            lineCallback: { [weak self] line, _ in self?.append(line) },
            completion: { [weak self] result in
                guard let self else { return }
                self.phase = .exited(result.exitCode)
                if result.truncated { self.append("[yuix] 输出超过上限，仅保留末尾部分") }
                self.append("[yuix] 进程退出，exit code \(result.exitCode)")
                self.onExited?(result.exitCode)
            }
        )

        if pid < 0 {
            phase = .failed("进程启动失败（code \(pid)）")
            return
        }
        guestPID = pid
        phase = .running
        onRunning?()
        append("[yuix] 运行中 · 本机 http://127.0.0.1:\(project.port)/ · 局域网 http://<本机IP>:\(project.port)/")
    }

    func stop() {
        if guestPID > 0 {
            LinuxRuntime.shared.kill(pid: guestPID)
            append("[yuix] 已发送终止信号")
        }
        guestPID = -1
        if case .running = phase { phase = .exited(-1) }
    }

    // MARK: - 语言映射

    private struct RuntimeSpec {
        let package: String   // Alpine 包名
        let binary: String    // guest 内可执行文件
        let entry: String     // 入口文件
    }

    private var runtimeSpec: RuntimeSpec? {
        switch project.language {
        case .python: return RuntimeSpec(package: "python3", binary: "python3", entry: "app.py")
        case .node:   return RuntimeSpec(package: "nodejs", binary: "node", entry: "server.js")
        case .php:    return RuntimeSpec(package: "php83", binary: "php83", entry: "index.php")
        case .html:   return nil
        }
    }

    // MARK: - 输出

    private func append(_ line: String) {
        lines.append(line)
        if lines.count > Self.maxLines {
            lines.removeFirst(lines.count - Self.maxLines)
        }
    }
}
