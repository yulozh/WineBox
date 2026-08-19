import Foundation
import Network

/// 极简 HTTP/1.1 静态文件服务器，基于 Network.framework 的 NWListener。
///
/// 澄清一个常见误解：iOS 沙盒禁止的是 fork/exec 子进程，
/// 而「监听 TCP 端口」是允许的 —— NWListener 在上架应用里就能用。
/// 所以本类能在真机上打开真实端口，把项目目录作为静态站点提供给局域网访问。
/// 限制依旧存在：Python/PHP/Node 脚本没有解释器可跑（那需要子进程），
/// 但 HTML/CSS/JS/图片等静态资源的端口服务是货真价实的。
final class HTTPFileServer {

    enum ServerError: LocalizedError {
        case badPort(Int)

        var errorDescription: String? {
            switch self {
            case .badPort(let p): return "端口 \(p) 不可用或已被占用"
            }
        }
    }

    let port: UInt16
    private let root: URL
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.yuixserver.http-server")
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let stateLock = NSLock()
    private var _isRunning = false

    /// 端口绑定成功（主线程回调）
    var onReady: (() -> Void)?
    /// 端口绑定失败（主线程回调）
    var onFailed: ((Error) -> Void)?

    var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _isRunning
    }

    init(root: URL, port: UInt16) throws {
        guard let endpoint = NWEndpoint.Port(rawValue: port) else {
            throw ServerError.badPort(Int(port))
        }
        self.root = root
        self.port = port
        do {
            listener = try NWListener(using: .tcp, on: endpoint)
        } catch {
            // 端口被占 / 权限不足时 NWListener 构造直接抛错
            throw ServerError.badPort(Int(port))
        }
    }

    func start() {
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.setRunning(true)
                DispatchQueue.main.async { self.onReady?() }
            case .failed(let error):
                self.setRunning(false)
                DispatchQueue.main.async { self.onFailed?(error) }
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener.cancel()
            self.connections.values.forEach { $0.cancel() }
            self.connections.removeAll()
        }
        setRunning(false)
    }

    private func setRunning(_ value: Bool) {
        stateLock.lock()
        _isRunning = value
        stateLock.unlock()
    }

    // MARK: - 连接与请求

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.connections.removeValue(forKey: key)
            default:
                break
            }
        }
        receiveHead(from: connection, buffer: Data())
    }

    /// 逐段读入，直到出现空行（请求头结束）
    private func receiveHead(from connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var head = buffer
            if let data { head.append(data) }

            if let range = head.range(of: Data("\r\n\r\n".utf8)) {
                let text = String(data: head.subdata(in: head.startIndex..<range.lowerBound), encoding: .utf8) ?? ""
                self.serve(requestHead: text, connection: connection)
                return
            }
            if error != nil || isComplete || head.count > 65536 {
                connection.cancel()
                return
            }
            self.receiveHead(from: connection, buffer: head)
        }
    }

    private func serve(requestHead: String, connection: NWConnection) {
        let requestLine = requestHead.components(separatedBy: "\r\n").first ?? ""
        let fields = requestLine.split(separator: " ")
        guard fields.count >= 2 else {
            respond(status: "400 Bad Request", contentType: "text/plain; charset=utf-8",
                    body: Data("400 Bad Request\n".utf8), method: "GET", connection: connection)
            return
        }
        let method = String(fields[0])
        guard method == "GET" || method == "HEAD" else {
            respond(status: "405 Method Not Allowed", contentType: "text/plain; charset=utf-8",
                    body: Data("仅支持 GET / HEAD\n".utf8), method: "GET", connection: connection)
            return
        }
        let target = String(fields[1])
        let path = target.split(separator: "?").first.map(String.init) ?? "/"
        serve(path: path, method: method, connection: connection)
    }

    private func serve(path rawPath: String, method: String, connection: NWConnection) {
        // 脚本执行路由：GET /run/<路径>.js 真正执行项目内的 JavaScript 并返回输出
        if rawPath.hasPrefix("/run/") {
            let rel = String(rawPath.dropFirst("/run/".count))
            serveRun(rel, method: method, connection: connection)
            return
        }

        let decoded = rawPath.removingPercentEncoding ?? rawPath
        // 重组安全相对路径：丢弃 . 与 .. 段，杜绝目录穿越
        let segments = decoded.split(separator: "/").filter { $0 != "." && $0 != ".." }
        let target = root.appendingPathComponent(segments.joined(separator: "/"))

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir) else {
            respond(status: "404 Not Found", contentType: "text/plain; charset=utf-8",
                    body: Data("404 Not Found\n".utf8), method: method, connection: connection)
            return
        }

        var fileURL = target
        if isDir.boolValue {
            let index = target.appendingPathComponent("index.html")
            if FileManager.default.fileExists(atPath: index.path) {
                fileURL = index
            } else {
                // 无 index.html 时给出目录列表
                respond(status: "200 OK", contentType: "text/html; charset=utf-8",
                        body: Data(Self.listingHTML(for: target).utf8),
                        method: method, connection: connection)
                return
            }
        }

        guard let body = try? Data(contentsOf: fileURL) else {
            respond(status: "403 Forbidden", contentType: "text/plain; charset=utf-8",
                    body: Data("403 Forbidden\n".utf8), method: method, connection: connection)
            return
        }
        respond(status: "200 OK", contentType: Self.mime(for: fileURL.path),
                body: body, method: method, connection: connection)
    }

    /// 执行路由：真正运行项目目录内的 .js 脚本，把 console 输出作为响应返回。
    private func serveRun(_ rel: String, method: String, connection: NWConnection) {
        let segments = rel.split(separator: "/").filter { $0 != "." && $0 != ".." }
        guard let name = segments.last, name.lowercased().hasSuffix(".js") else {
            respond(status: "400 Bad Request", contentType: "text/plain; charset=utf-8",
                    body: Data("只支持执行 .js 脚本\n".utf8), method: method, connection: connection)
            return
        }
        let fileURL = root.appendingPathComponent(segments.joined(separator: "/"))
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            respond(status: "404 Not Found", contentType: "text/plain; charset=utf-8",
                    body: Data("脚本不存在\n".utf8), method: method, connection: connection)
            return
        }

        let result = JSScriptRunner.runFile(at: fileURL)
        var text = result.output
        if !result.returnValue.isEmpty, result.returnValue != "undefined" {
            text += "=> \(result.returnValue)\n"
        }
        if let error = result.error {
            text += "错误: \(error)\n"
        }

        let status = result.error == nil ? "200 OK" : "500 Internal Server Error"
        respond(status: status, contentType: "text/plain; charset=utf-8",
                body: Data(text.utf8), method: method, connection: connection)
    }

    private func respond(status: String, contentType: String, body: Data,
                         method: String, connection: NWConnection) {
        let head = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n"
            + "Server: YuixServer\r\n\r\n"
        var payload = Data(head.utf8)
        if method != "HEAD" { payload.append(body) }
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - 静态页面

    private static func listingHTML(for dir: URL) -> String {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let rows = names.sorted().map { name -> String in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path, isDirectory: &isDir)
            let href = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
            let label = escape(name) + (isDir.boolValue ? "/" : "")
            return "<li><a href=\"\(href)\">\(label)</a></li>"
        }.joined(separator: "\n")
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>Index</title>
        <style>body{font:15px -apple-system;margin:2rem;color:#1d1d1f}li{margin:.25rem 0}a{color:#0066cc}</style>
        </head><body><h3>YuixServer</h3><ul>\(rows)</ul></body></html>
        """
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func mime(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "css":         return "text/css; charset=utf-8"
        case "js":          return "text/javascript; charset=utf-8"
        case "json":        return "application/json; charset=utf-8"
        case "png":         return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":         return "image/gif"
        case "svg":         return "image/svg+xml"
        case "ico":         return "image/x-icon"
        case "pdf":         return "application/pdf"
        case "txt", "md":   return "text/plain; charset=utf-8"
        default:            return "application/octet-stream"
        }
    }
}
