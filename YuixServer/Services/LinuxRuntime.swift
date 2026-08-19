import Foundation
import Combine

/// Swift 门面：封装 YXLinuxBoot / YXLinuxShell（内置 Alpine Linux 引擎）。
///
/// - `shared.boot()` 首次调用导入 rootfs（带进度）并启动内核
/// - `run()` 在 Alpine 内执行命令（`sh -c`），流式回调每一行
/// - `guestPath(for:)` 把 iOS 沙盒路径映射为 guest 内的 `/root/projects/...`
@MainActor
final class LinuxRuntime: ObservableObject {

    static let shared = LinuxRuntime()

    // MARK: - 状态（供 UI 观察）

    enum BootState: Equatable {
        case idle
        case importingRootfs(progress: Double)
        case bootingKernel
        case ready
        case failed(String)
    }

    @Published private(set) var state: BootState = .idle
    @Published private(set) var kernelDiedMessage: String?

    /// 内核是否已就绪（用于「运行」按钮可用性等）
    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    private let boot = YXLinuxBoot.shared()
    private var exitedObserver: NSObjectProtocol?
    private var diedObserver: NSObjectProtocol?
    private var booting = false

    private init() {
        exitedObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("YXLinuxProcessExitedNotification"), object: nil, queue: .main
        ) { [weak self] note in
            // 只关心错误码：命令结束的收尾由 YXLinuxShell 的 completion 处理
            guard let self,
                  let pid = note.userInfo?["pid"] as? Int,
                  let code = note.userInfo?["code"] as? Int,
                  code != 0 else { return }
            NSLog("LinuxRuntime: guest pid \(pid) exited with \(code)")
        }
        diedObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("YXLinuxKernelDiedNotification"), object: nil, queue: .main
        ) { [weak self] note in
            let msg = (note.userInfo?["message"] as? String) ?? "内核异常退出"
            self?.kernelDiedMessage = msg
            self?.state = .failed(msg)
        }
    }

    deinit {
        if let exitedObserver { NotificationCenter.default.removeObserver(exitedObserver) }
        if let diedObserver { NotificationCenter.default.removeObserver(diedObserver) }
    }

    // MARK: - 启动

    /// 启动（幂等）。在后台线程执行阻塞引导，主线程回调。
    func bootIfNeeded() {
        if case .ready = state { return }
        if case .failed = state { return } // 失败后不再自动重试，避免循环崩溃
        guard !booting else { return }
        booting = true

        // 轻量轮询引导进度（rootfs 导入期间 stateDetail/importProgress 更新）
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch self.boot.state {
                case .importingRootfs:
                    self.state = .importingRootfs(progress: self.boot.importProgress)
                case .bootingKernel:
                    self.state = .bootingKernel
                default: break
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let boot = YXLinuxBoot.shared()
            // 注意：bootWithError: 被 Swift 导入为 throws 方法，
            // 这里用 bootWithFailureMessage: 避免错误约定转换。
            var failureMessage: NSString?
            let ok = boot.bootWithFailureMessage(&failureMessage)
            let message = failureMessage as String?
            Task { @MainActor [weak self] in
                timer.invalidate() // Timer 必须在创建它的线程（主线程）上 invalidate
                guard let self else { return }
                self.booting = false
                if ok {
                    self.state = .ready
                } else {
                    self.state = .failed(message ?? "启动失败")
                }
            }
        }
    }

    // MARK: - 控制台（真实 Alpine 终端）

    /// 注册控制台输出监听（终端 UI 用）。返回 token，用于取消。
    func addConsoleOutputHandler(_ handler: @escaping (Data) -> Void) -> NSNumber? {
        let token = boot.addOutputHandler { data in
            handler(data)
        }
        return NSNumber(value: token)
    }

    func removeConsoleOutputHandler(_ token: NSNumber?) {
        guard let token else { return }
        boot.removeOutputHandler(token.uintValue)
    }

    /// 向 Alpine 终端发送原始输入（命令行、控制字符、Tab 补全等）
    func sendConsoleInput(_ data: Data) {
        boot.sendConsoleInput(data)
    }

    func sendConsoleInput(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        sendConsoleInput(data)
    }

    func setConsoleSize(cols: Int, rows: Int) {
        boot.setConsoleSize(Int32(cols), rows: Int32(rows))
    }

    // MARK: - 命令执行（sh -c，独立会话）

    struct CommandResult {
        var exitCode: Int = -1
        var output: String = ""
        var errorOutput: String = ""
        var duration: TimeInterval = 0
        var truncated = false
    }

    /// 在 Alpine 内执行命令。lineCallback 在主线程回调每一行输出。
    /// completion 在主线程回调（exitCode < 0 表示启动失败）。
    @discardableResult
    func run(_ command: String,
             workingDirectory guestCWD: String? = nil,
             environment: [String: String]? = nil,
             lineCallback: ((String, Bool) -> Void)? = nil,
             completion: ((CommandResult) -> Void)? = nil) -> Int {

        let pid = YXLinuxShell.executeCommand(
            command,
            workingDirectory: guestCWD,
            environment: environment,
            lineCallback: { line, isError in
                lineCallback?(line, isError)
            },
            completion: { r in
                var result = CommandResult()
                result.exitCode = Int(r.exitCode)
                result.output = r.output
                result.errorOutput = r.errorOutput
                result.duration = r.duration
                result.truncated = r.truncated
                completion?(result)
            })
        return Int(pid)
    }

    /// 同步执行（阻塞当前线程；不要在主线程调用）。
    nonisolated func runSync(_ command: String,
                             timeout: TimeInterval = 60) -> CommandResult {
        let r = YXLinuxShell.executeCommandSync(command, timeout: timeout, lineCallback: nil)
        var result = CommandResult()
        guard let r else { return result }
        result.exitCode = Int(r.exitCode)
        result.output = r.output
        result.errorOutput = r.errorOutput
        result.duration = r.duration
        result.truncated = r.truncated
        return result
    }

    func kill(pid: Int) {
        YXLinuxShell.killProcess(Int32(pid), withSignal: 9)
    }

    // MARK: - 路径映射

    /// iOS 沙盒 Documents → guest /root/projects
    static let guestProjectsRoot = "/root/projects"

    /// 把本机 URL 映射为 Alpine 内路径；不在映射范围内的返回 nil。
    nonisolated static func guestPath(for url: URL) -> String? {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first
            ?? NSHomeDirectory() + "/Documents"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(docs) else { return nil }
        let rel = String(path.dropFirst(docs.count))
        return rel.isEmpty ? guestProjectsRoot : guestProjectsRoot + rel
    }

    /// 项目在 guest 内的路径（MainActor：ProjectStore 是 @MainActor，
    /// 唯一调用点 startService 同样运行在主 actor 上）
    static func guestPath(forProject project: Project, in store: ProjectStore) -> String? {
        guestPath(for: store.projectURL(project))
    }
}
