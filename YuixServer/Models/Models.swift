import Foundation

// MARK: - 运行时语言

/// 应用内置的多语言运行时类型。
/// - Static / Node.js：可直接运行。静态站由 HTTPFileServer 提供真实端口监听；
///   JS 脚本由 JSScriptRunner 基于系统 JavaScriptCore 真实执行（无需子进程）。
/// - Python / PHP：需要把解释器编译成静态库嵌入（libPython / php-embed），
///   属后续增强，不依赖子进程，上架合规。
enum Language: String, CaseIterable, Codable, Identifiable {
    case python = "Python"
    case php = "PHP"
    case node = "Node.js"
    case html = "Static"

    var id: String { rawValue }

    /// 该语言默认的入口文件名
    var entryFileName: String {
        switch self {
        case .python: return "app.py"
        case .php:     return "index.php"
        case .node:    return "server.js"
        case .html:    return "index.html"
        }
    }

    /// 新建项目时自动写入的模板代码
    var template: String {
        switch self {
        case .python:
            return "# app.py\nprint('YuixServer: Python 环境已就绪')\n"
        case .php:
            return "<?php\n// index.php\necho 'YuixServer: PHP 环境已就绪';\n"
        case .node:
            return """
            // server.js —— 由 YuixServer 内置 JavaScriptCore 运行时真实执行
            const fs = require('fs');
            console.log('PORT =', process.env.PORT || '(本地运行，未设端口)');
            console.log('工作目录 =', process.cwd());
            console.log('目录内文件数 =', fs.readdirSync('.').length);
            function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
            console.log('fib(10) =', fib(10));
            """
        case .html:
            return "<!doctype html>\n<html><body><h1>YuixServer</h1><p>Static site</p></body></html>\n"
        }
    }
}

// MARK: - 项目

/// 一个「项目」对应一个运行环境（代码目录 + 依赖 + 配置 + 端口）。
struct Project: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var language: Language
    var port: Int
    var createdAt: Date

    init(id: UUID = UUID(), name: String, language: Language, port: Int, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.language = language
        self.port = port
        self.createdAt = createdAt
    }
}

// MARK: - 服务与端口

enum ServiceStatus: String, Codable {
    case stopped, starting, running, error
}

/// 端口服务列表中的一项。
struct ServiceInfo: Identifiable {
    let id = UUID()
    let projectID: UUID
    var name: String
    var port: Int
    var language: Language
    var pid: Int?          // 侧载/进程版可用；沙盒版为 nil
    var status: ServiceStatus
}

// MARK: - 文件树节点

/// 文件浏览器中的节点。children 仅在目录时非空。
/// id 使用文件路径而非随机 UUID：否则每次刷新树，整棵 List 的身份都会变，
/// 展开状态与动画全部丢失（旧实现的真实 Bug）。
struct FileNode: Identifiable {
    let name: String
    let url: URL
    let isDirectory: Bool
    var children: [FileNode]?

    var id: String { url.path }
}

// MARK: - AI 对话

enum ChatRole: String, Codable {
    case system, user, assistant
}

/// 单条对话消息（system 用于设定 AI 角色与重写写入文件的规则）。
struct ChatMessage: Identifiable, Codable {
    let id = UUID()
    var role: ChatRole
    var content: String
    var timestamp: Date

    /// 转为 OpenAI 兼容接口所需的字典
    var apiDict: [String: String] { ["role": role.rawValue, "content": content] }
}

// MARK: - AI 配置

/// AI 服务商配置。apiKey 明文不保存在内存结构体里，而存入 Keychain。
/// Codable：非敏感部分（baseURL/模型名）会持久化到 UserDefaults。
struct AIConfig: Equatable, Codable {
    var providerName: String = "OpenAI"
    var baseURL: String = "https://api.openai.com/v1"   // 兼容 OpenAI 的 /chat/completions 端点
    var model: String = "gpt-4o"                        // 默认模型，可配置
}

// MARK: - GitHub 配置

/// GitHub 账号信息（仅用于组织/命名空间提示）。Token 存 Keychain，不落盘明文。
struct GitConfig: Equatable, Codable {
    var defaultOwner: String = "yulozh"                 // 默认仓库命名空间
}