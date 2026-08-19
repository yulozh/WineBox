import Foundation

/// 沙盒内轻量伪终端：对当前目录执行常用命令（ls/pwd/cat/echo/help/clear）。
/// 注意：这不是真正的 Linux 内核；完整的 Alpine Linux 由 LinuxEnvironment（iSH）提供。
/// 本服务让内置「终端」页面对项目目录做基础文件操作，并与文件管理、运行脚本联动。
enum ShellService {

    struct Result {
        let output: String
        let status: Int   // 0 成功；非 0 失败
    }

    static let helpText = """
    可用命令（沙盒模式）:
      help        显示本帮助
      pwd         打印当前目录
      ls [path]   列出文件
      cat <file>  输出文件内容
      echo <text> 回显文本
      clear       清屏
    完整 Linux 命令请点顶部「Alpine」打开 iSH。
    """

    /// 解析并执行一行命令，cwd 为当前工作目录。
    static func execute(_ raw: String, cwd: URL) -> Result {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return Result(output: "", status: 0) }
        let parts = line.split(separator: " ").map(String.init)
        let cmd = parts[0]
        let args = Array(parts.dropFirst())

        switch cmd {
        case "help", "?", "man":
            return Result(output: helpText, status: 0)
        case "pwd":
            return Result(output: cwd.path, status: 0)
        case "ls":
            return list(cwd, args: args)
        case "cat":
            return cat(args, cwd: cwd)
        case "echo":
            return Result(output: args.joined(separator: " "), status: 0)
        default:
            return Result(output: "sh: \(cmd): command not found", status: 127)
        }
    }

    private static func list(_ cwd: URL, args: [String]) -> Result {
        let dir = args.first.map { cwd.appendingPathComponent($0) } ?? cwd
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return Result(output: "ls: \(dir.lastPathComponent): No such file or directory", status: 1)
        }
        let out = names.sorted().joined(separator: "\n")
        return Result(output: out, status: 0)
    }

    private static func cat(_ args: [String], cwd: URL) -> Result {
        guard let first = args.first else {
            return Result(output: "cat: missing file operand", status: 1)
        }
        let url = cwd.appendingPathComponent(first)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return Result(output: "cat: \(first): No such file or directory", status: 1)
        }
        return Result(output: content, status: 0)
    }
}