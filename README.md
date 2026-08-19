# YuixServer 使用文档

> 把 iPhone / iPad 变成一台本地开发服务器：多语言环境、文件管理、端口服务，并内置 AI 编程助手。
> 技术栈：SwiftUI（原生毛玻璃 UI，iOS 16+，同时支持 iPhone 与 iPad）。

---

## 1. 项目结构

```
YuixServer/
├── project.yml                 # XcodeGen 工程配置（可一键生成 .xcodeproj）
├── .gitignore
├── docs/
│   └── 架构说明.md
└── YuixServer/
    ├── App/
    │   └── YuixServerApp.swift # @main 入口
    ├── Models/
    │   └── Models.swift        # 语言/项目/服务/文件树/对话/AI 配置模型
    ├── Services/
    │   ├── ProjectStore.swift  # 全局状态中枢（项目、文件树、服务、目录）
    │   ├── KeychainStore.swift # 凭证安全存储（API Key / GitHub Token）
    │   ├── ArchiveService.swift# 压缩导出/导入（.zip）
    │   ├── ServiceRegistry.swift# 运行时抽象（WASM / 侧载子进程接入点）
    │   ├── NetworkService.swift# 局域网 IP 获取
    │   ├── AIService.swift     # AI Agent（OpenAI 兼容接口）
    │   ├── GitService.swift    # Git 操作（GitHub REST API）
    │   ├── LinuxEnvironment.swift # 内置 Linux（Alpine/iSH）集成
    │   ├── ShellService.swift  # 沙盒伪终端命令
    │   └── GitHubAuthService.swift # GitHub OAuth 脚手架
    ├── Utilities/
    │   └── SyntaxHighlighter.swift # 正则语法高亮
    └── Views/
        ├── ContentView.swift   # 主界面（毛玻璃布局）
        ├── Glass.swift         # 毛玻璃/背景修饰器
        ├── FileTreeView.swift  # 侧边栏文件树
        ├── CodeEditorView.swift# 高亮代码编辑器
        ├── AIPanelView.swift   # AI 聊天面板
        ├── ServiceStatusBar.swift# 底部服务状态栏
        ├── WebPreviewView.swift# 内置浏览器预览
        ├── TerminalView.swift  # 内置终端（含 Alpine 入口）
        ├── SettingsView.swift  # 设置
        └── DocumentPicker.swift# 系统文件选择器
```

## 2. 快速开始

### 方式 A：XcodeGen（推荐）

1. 安装 XcodeGen：`brew install xcodegen`
2. 在 `YuixServer/` 目录执行：

```bash
xcodegen generate
```

3. 打开生成的 `YuixServer.xcodeproj`，选择目标设备，直接运行。

### 方式 B：手动新建工程

1. Xcode 新建「iOS App」，Language 选 Swift、Interface 选 SwiftUI。
2. 把 `YuixServer/YuixServer/` 下所有源码拖入工程。
3. 「File → Add Package Dependencies」添加 `https://github.com/weichsel/ZIPFoundation.git`（版本 ≥ 0.9.19）。

### 依赖

| 依赖 | 用途 | 说明 |
|---|---|---|
| ZIPFoundation | `.zip` 压缩导出/导入 | 纯 Swift，App Store 合规 |

> 若 ZIPFoundation 版本不同导致 API 差异，请参考其 README 微调 `ArchiveService.swift` 中的 `addEntry` / `extract` 调用。

## 3. 功能与流程

- **新建项目**：顶部「新建项目」→ 输入名称、选择语言（Python/PHP/Node/Static）→ 自动创建目录、写入入口模板并分配端口（默认 3000–8999）。
- **文件管理**：左侧文件树支持展开、打开、右键「预览 / 重命名 / 删除 / 运行脚本」。
- **代码编辑**：中间编辑器对 `.py/.php/.js/.html/.json` 做语法高亮，实时保存。
- **服务管理**：底部状态栏显示局域网 IP、服务列表（名称/端口/状态/运行与预览按钮）。
- **AI 助手**：右侧面板用自然语言描述需求，AI 生成代码（代码块形式），点「将代码写入项目」即可写入/追加到入口文件。
- **压缩导出/导入**：底部「导出容器」调起系统文件选择器保存 `.zip`；「导入」选择 `.zip` 恢复环境。

## 4. 配置 AI（OpenAI / DeepSeek 等，不限定服务商）

「设置 → AI 编程助手」：

| 字段 | 示例 |
|---|---|
| 服务商名称 | OpenAI 或 DeepSeek |
| Base URL | `https://api.openai.com/v1` 或 `https://api.deepseek.com` |
| 模型 | `gpt-4o`（默认，可改） |
| API Key | 输入后点「保存 AI 配置」，写入 iOS 钥匙串（Keychain） |

> 接口走 OpenAI 兼容的 `/chat/completions`；只要服务商兼容该协议即可替换。

## 5. 配置 Git（GitHub）

「设置 → GitHub 集成」：

- **默认组织/用户名**：`yulozh`（作为仓库命名空间提示）。
- **Personal Access Token（推荐）**：在 GitHub 生成 Fine-grained PAT（权限选 `Contents: Read and write`），粘贴后「保存 Token」存入钥匙串。这是最简单、无需后端的方式。
- **OAuth（可选）**：填写 OAuth Client ID 后点「通过 GitHub OAuth 登录」。完整授权码流程需要 `client_secret`，**不应**写进客户端；建议由你的后端代理换取 token（见 `GitHubAuthService.swift` 注释）。

Git 操作支持：`clone`（递归拉取）、`pull`（重新 clone 覆盖）、`push`、`commit`、`branch`（创建/列出），基于 GitHub REST API + Git Data API 实现，无需本地 `git` 二进制。

## 6. 安全与隐私

- 所有 **AI API Key / GitHub Token** 仅存于 iOS **钥匙串（Keychain）**，绝不硬编码进源码或明文写入 UserDefaults。
- 应用运行在沙盒内，默认根目录 `~/Documents/YuixServer/`，无法访问系统文件。
- `Info.plist` 声明了本地网络权限（`NSLocalNetworkUsageDescription`），仅在需要展示局域网 IP / 供其他设备访问时使用。

> ⚠️ 若你曾把 GitHub 密码以明文形式发给过我，请立即前往 GitHub 重置该密码与对应 Token。

## 7. 重要平台限制（务必阅读）

| 事项 | 说明 |
|---|---|
| 子进程 | App Store 上架的 iOS 沙盒**禁止** `Process`/`child_process` 启动子进程 |
| 端口监听 | 沙盒**禁止**监听任意端口，无法真正把 3000–8999 暴露给局域网 |
| 合规方案 | Python/PHP/Node 以 **WASM** 内嵌，服务在应用内 `WKWebView` 预览 |
| 侧载方案 | 企业签名/个人自签名可用真子进程实现真实端口监听 |

这些限制已抽象成 `RuntimeProviding` 协议（`ServiceRegistry.swift`），替换实现即可切换合规版/侧载版。

## 8. 交付物说明

- ✅ Xcode 工程源码（`project.yml` + 完整源码树，含内置 Linux 集成与终端）
- ✅ 代码注释（关键逻辑均有中文说明）
- ✅ 使用文档（本文档）+ 架构说明（`docs/架构说明.md`）
- ✅ 新增：IPA 打包签名指南（`docs/IPA打包与签名指南.md`）、内置 Linux 集成指南（`docs/内置Linux集成指南.md`）
- ✅ 高保真毛玻璃 UI 原型（`../YuixServer-prototype/index.html`，浏览器直接打开）
- ⏳ 演示视频/GIF 与可安装 IPA：需 Mac + Xcode + Apple 开发者证书，本交付环境无法生成（见打包指南）

## 9. 开发路线（对应需求中的进度建议）

1. 基础文件管理 + 环境启动（已完成骨架）
2. 端口管理 + 压缩导出（已完成骨架）
3. AI Agent + Git 集成（已完成骨架）
4. 接入真实 WASM 运行时（Node.js/Python/PHP），替换 `DefaultRuntime`
5. 打磨编辑体验（接入 Runestone / CodeMirror），完善 Git diff/merge