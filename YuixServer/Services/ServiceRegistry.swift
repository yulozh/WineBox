import Foundation

/// 运行时/服务抽象层。
///
/// ⚠️ 关键说明（iOS 平台限制）：
/// App Store 上架的 iOS/iPadOS 应用运行在沙盒中，**无法**通过 `Process`/`child_process`
/// 启动子进程，也**无法**监听任意网络端口。因此：
///  - 合规版：多语言运行时（Python/PHP/Node）以 **WASM** 方式内嵌，服务在应用内
///    `WKWebView` 中预览，不暴露真实局域网端口；
///  - 侧载版（企业签名/个人开发者自签名）：可通过真子进程实现真实端口监听，
///    供同一 Wi-Fi 下其他设备访问。
///
/// 本协议把两者统一成一个接口，便于后续替换实现（开闭原则）。
protocol RuntimeProviding {
    /// 启动服务；返回进程/会话标识（沙盒版返回 nil）
    func start(project: Project, completion: @escaping (Result<Int?, Error>) -> Void)
    /// 停止服务
    func stop(project: Project)
    /// 该服务可供预览的 URL（沙盒版为应用内地址，侧载版为局域网地址）
    func previewURL(project: Project) -> URL?
}

/// 默认实现：占位运行时。
/// 当前版本在应用内用 WKWebView 预览项目入口文件（静态 HTML/文本），
/// 真实多语言运行时请替换为 WASM 子模块或侧载子进程实现。
final class DefaultRuntime: RuntimeProviding {
    private let root: URL

    init(root: URL) {
        self.root = root
    }

    func start(project: Project, completion: @escaping (Result<Int?, Error>) -> Void) {
        // TODO(WASM): 在此挂载 Node/Python/PHP 的 WASM 运行时，返回会话 id。
        // TODO(侧载): 使用 Process 启动子进程并监听 project.port。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            completion(.success(nil))
        }
    }

    func stop(project: Project) {
        // TODO(WASM): 终止对应 WASM 会话。
    }

    func previewURL(project: Project) -> URL? {
        // 沙盒内无法监听真实端口，因此「预览/访问」统一在内置浏览器中打开项目入口文件：
        //  - Static(HTML) 会被当作网页渲染；
        //  - Python/PHP/Node 脚本会以文本形式展示（真实运行时接入后改为 http://局域网IP:port）。
        let dir = root.appendingPathComponent(project.name)
        let entry = dir.appendingPathComponent(project.language.entryFileName)
        if FileManager.default.fileExists(atPath: entry.path) { return entry }
        return dir
    }
}