import Foundation
import JavaScriptCore

/// 真实 JavaScript 运行时，基于系统 JavaScriptCore。
///
/// 为什么不是 Node/V8：iOS 上 V8 依赖 SSE2 的 JIT 编译，无法运行
/// （iSH 里 `node` 一跑就 illegal instruction 正是这个原因）。
/// JavaScriptCore 是苹果自带的 JIT 引擎，上架应用可直接调用，
/// Node.js Mobile 在 iOS 端也是用 JSC 跑 JS 源码。
///
/// 本运行时注入了一套精简、可上架的 "mini Node" 能力：
///   - console / print         捕获输出
///   - process.env / cwd       环境信息
///   - require + module.exports 本地模块加载（相对路径 + node_modules 向上查找）
///   - fs 模块                  readFileSync / writeFileSync / readdirSync / existsSync / mkdirSync / statSync
///
/// 注意：iOS 沙盒禁止子进程，因此完整的 Node 事件循环 / net / dgram 等
/// 依赖本地 socket 与子进程的模块不在本运行时内——这些由 HTTPFileServer
/// 在原生层补足（端口监听 + HTTP 解析 + /run 脚本路由）。
enum JSScriptRunner {

    struct Result {
        let output: String       // console.log / print 捕获到的所有输出
        let returnValue: String  // 脚本最后一个表达式的求值结果
        let error: String?       // 运行时异常（nil 表示成功）
    }

    // MARK: - 公开入口

    /// 执行 JavaScript 源码。baseDir 作为模块解析与 fs 操作的相对基准目录，
    /// env 会注入 process.env（如端口信息）。
    static func run(_ code: String, baseDir: URL, env: [String: String] = [:]) -> Result {
        guard let context = JSContext() else {
            return Result(output: "", returnValue: "", error: "无法创建 JavaScript 上下文")
        }

        var output = ""

        // 1) 输出捕获：console / print
        let sink: @convention(block) (JSValue?) -> Void = { value in
            output += (value?.toString() ?? "undefined") + "\n"
        }
        let console = JSValue(newObjectIn: context)
        console?.setObject(sink, forKeyedSubscript: "log" as NSString)
        console?.setObject(sink, forKeyedSubscript: "error" as NSString)
        console?.setObject(sink, forKeyedSubscript: "warn" as NSString)
        context.setObject(console, forKeyedSubscript: "console" as NSString)
        context.setObject(sink, forKeyedSubscript: "print" as NSString)

        // 2) process
        let process = JSValue(newObjectIn: context)
        let envObject = JSValue(newObjectIn: context)
        for (key, value) in env { envObject?.setValue(value, forProperty: key) }
        process?.setValue(baseDir.path, forProperty: "cwd")
        process?.setValue(envObject, forProperty: "env")
        process?.setValue(["node", baseDir.lastPathComponent], forProperty: "argv")
        context.setObject(process, forKeyedSubscript: "process" as NSString)

        // 3) 原生辅助（供下面 bootstrap 的 JS 模块系统调用）
        context.setObject(makeReadFileBlock(), forKeyedSubscript: "__readFile" as NSString)
        context.setObject(makeResolveBlock(), forKeyedSubscript: "__resolve" as NSString)

        // 4) fs 模块（直接作为全局对象，也挂到 require）
        let fs = makeFS(baseDir: baseDir, context: context)
        context.setObject(fs, forKeyedSubscript: "fs" as NSString)

        // 5) 模块系统 bootstrap（用 JS 写，避免 Swift/JSValue 回调的边角问题）
        //    注入 require / module / exports / __dirname / __filename。
        let mainPath = baseDir.appendingPathComponent("__main__.js").path
        let mainDir = baseDir.path
        let bootstrap = """
        (function(){
            var __cache = {};
            function __dirnameOf(p){
                var i = p.lastIndexOf('/');
                return i === -1 ? '.' : p.slice(0, i);
            }
            function __require(request){
                if (request === 'fs') return fs;
                if (request === 'process') return process;
                var resolved = __resolve(__dirname, request);
                if (resolved === null) { throw new Error('Cannot find module: ' + request); }
                if (__cache[resolved]) return __cache[resolved].exports;
                var code = __readFile(resolved);
                if (code === null) { throw new Error('Cannot read module: ' + request); }
                var module = { exports: {} };
                __cache[resolved] = module;
                var factory = new Function('module', 'exports', 'require', '__dirname', '__filename', code);
                factory(module, module.exports, __require, __dirnameOf(resolved), resolved);
                return module.exports;
            }
            this.require = __require;
            this.module = { exports: {} };
            this.exports = this.module.exports;
            this.__filename = URLPATH;
            this.__dirname = DIRPATH;
        })();
        """
        let prepared = bootstrap
            .replacingOccurrences(of: "URLPATH", with: "'\(mainPath.replacingOccurrences(of: "'", with: "\\'"))'")
            .replacingOccurrences(of: "DIRPATH", with: "'\(mainDir.replacingOccurrences(of: "'", with: "\\'"))'")
        context.evaluateScript(prepared)

        // 6) 执行用户代码
        let value = context.evaluateScript(code)
        let returnValue: String
        if let v = value, v.isUndefined == false, v.toString() != "undefined" {
            returnValue = v.toString()
        } else {
            returnValue = ""
        }

        return Result(
            output: output,
            returnValue: returnValue,
            error: context.exception?.toString()
        )
    }

    /// 运行文件：以文件所在目录作为 baseDir。
    static func runFile(at url: URL, env: [String: String] = [:]) -> Result {
        guard let code = try? String(contentsOf: url, encoding: .utf8) else {
            return Result(output: "", returnValue: "", error: "无法读取文件：\(url.lastPathComponent)")
        }
        return run(code, baseDir: url.deletingLastPathComponent(), env: env)
    }

    // MARK: - fs 模块

    private static func makeFS(baseDir: URL, context: JSContext) -> JSValue? {
        let fs = JSValue(newObjectIn: context)

        let readFileSync: @convention(block) (String) -> String? = { path in
            let url = resolvePath(path, baseDir: baseDir)
            return try? String(contentsOf: url, encoding: .utf8)
        }
        fs?.setObject(readFileSync, forKeyedSubscript: "readFileSync" as NSString)

        let writeFileSync: @convention(block) (String, String) -> Void = { path, content in
            let url = resolvePath(path, baseDir: baseDir)
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
        fs?.setObject(writeFileSync, forKeyedSubscript: "writeFileSync" as NSString)

        let existsSync: @convention(block) (String) -> Bool = { path in
            FileManager.default.fileExists(atPath: resolvePath(path, baseDir: baseDir).path)
        }
        fs?.setObject(existsSync, forKeyedSubscript: "existsSync" as NSString)

        let readdirSync: @convention(block) (String) -> [String] = { path in
            let url = resolvePath(path, baseDir: baseDir)
            return (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        }
        fs?.setObject(readdirSync, forKeyedSubscript: "readdirSync" as NSString)

        let mkdirSync: @convention(block) (String) -> Void = { path in
            let url = resolvePath(path, baseDir: baseDir)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        fs?.setObject(mkdirSync, forKeyedSubscript: "mkdirSync" as NSString)

        let statSync: @convention(block) (String) -> [String: Any] = { path in
            let url = resolvePath(path, baseDir: baseDir)
            let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
            let size = (attrs[.size] as? UInt64) ?? 0
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            return ["isDirectory": isDir.boolValue, "size": Double(size)]
        }
        fs?.setObject(statSync, forKeyedSubscript: "statSync" as NSString)

        return fs
    }

    // MARK: - 模块解析

    private static func makeReadFileBlock() -> @convention(block) (String) -> String? {
        return { path in
            try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        }
    }

    private static func makeResolveBlock() -> @convention(block) (String, String) -> String? {
        return { currentDir, request in
            resolveModule(request, from: URL(fileURLWithPath: currentDir, isDirectory: true))?.path
        }
    }

    static func resolvePath(_ path: String, baseDir: URL) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return baseDir.appendingPathComponent(path).standardizedFileURL
    }

    static func resolveModule(_ request: String, from baseDir: URL) -> URL? {
        let fm = FileManager.default

        func tryCandidates(_ url: URL) -> URL? {
            for candidate in candidates(for: url) where fm.fileExists(atPath: candidate.path) {
                return candidate
            }
            return nil
        }

        if request.hasPrefix("./") || request.hasPrefix("../") || request.hasPrefix("/") {
            let start = request.hasPrefix("/") ? URL(fileURLWithPath: request) : baseDir.appendingPathComponent(request)
            return tryCandidates(start)
        }

        // 裸名（内置或 node_modules）：向上逐级查找
        var dir: URL? = baseDir
        while let d = dir {
            let nodeModules = d.appendingPathComponent("node_modules", isDirectory: true)
            if let hit = tryCandidates(nodeModules.appendingPathComponent(request)) { return hit }
            let parent = d.deletingLastPathComponent()
            dir = (parent.path == d.path) ? nil : parent
        }
        return nil
    }

    private static func candidates(for url: URL) -> [URL] {
        var list = [url]
        if url.pathExtension.isEmpty {
            list.append(url.appendingPathExtension("js"))
            list.append(url.appendingPathComponent("index.js"))
        }
        return list
    }
}