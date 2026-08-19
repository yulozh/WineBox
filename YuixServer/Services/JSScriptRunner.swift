import Foundation
import JavaScriptCore

/// 真实 JavaScript 执行器，基于系统 JavaScriptCore。
///
/// 为什么不是 Node/V8：iOS 上 V8 依赖 SSE2 的 JIT 编译，无法运行
/// （iSH 里 `node` 一跑就 illegal instruction 正是这个原因）。
/// JavaScriptCore 是苹果自带的 JIT 引擎，上架应用可直接调用，
/// Node.js Mobile 在 iOS 端也是用 JSC 跑 JS 源码。
/// 因此这里用 JSContext 执行脚本，并注入 console/print 捕获输出。
enum JSScriptRunner {

    struct Result {
        let output: String       // console.log / print 捕获到的所有输出
        let returnValue: String  // 脚本最后一个表达式的求值结果
        let error: String?       // 运行时异常（nil 表示成功）
    }

    /// 执行一段 JavaScript 源码，返回输出、返回值与可能的异常。
    static func run(_ code: String) -> Result {
        guard let context = JSContext() else {
            return Result(output: "", returnValue: "", error: "无法创建 JavaScript 上下文")
        }

        var output = ""
        let sink: @convention(block) (JSValue?) -> Void = { value in
            let text = value?.toString() ?? "undefined"
            output += text + "\n"
        }

        // console.log / console.error 都汇入 output
        let console = JSValue(newObjectIn: context)
        console?.setObject(sink, forKeyedSubscript: "log" as NSString)
        console?.setObject(sink, forKeyedSubscript: "error" as NSString)
        context.setObject(console, forKeyedSubscript: "console" as NSString)

        // 顶层 print（脚本里最常见的调试方法）
        context.setObject(sink, forKeyedSubscript: "print" as NSString)

        let value = context.evaluateScript(code)
        let resultText = value?.toString() ?? ""   // 求值为 undefined 时 toString 给 "undefined"
        let error = context.exception?.toString()

        return Result(
            output: output,
            returnValue: resultText,
            error: error
        )
    }

    /// 运行文件：读磁盘内容后交给 run()。
    static func runFile(at url: URL) -> Result {
        guard let code = try? String(contentsOf: url, encoding: .utf8) else {
            return Result(output: "", returnValue: "", error: "无法读取文件：\(url.lastPathComponent)")
        }
        return run(code)
    }
}