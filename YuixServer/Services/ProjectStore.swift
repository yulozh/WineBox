import Foundation
import SwiftUI

/// 应用全局状态中枢：管理项目列表、当前项目、文件树、端口服务与各项配置。
/// 默认容器根目录为沙盒 Documents/YuixServer/。
@MainActor
final class ProjectStore: ObservableObject {
    // 项目与文件
    @Published var projects: [Project] = []
    @Published var activeProject: Project?
    @Published var fileTree: [FileNode] = []
    @Published var selectedFileURL: URL?

    // 端口服务
    @Published var services: [ServiceInfo] = []

    // 配置（密钥在 KeychainStore 中）
    @Published var aiConfig = AIConfig()
    @Published var gitConfig = GitConfig()
    @Published var aiAPIKey: String = ""      // 仅用于输入后写入 Keychain，不持久化
    @Published var gitToken: String = ""      // 仅用于输入后写入 Keychain，不持久化

    // 设备局域网 IP（见 NetworkService）
    @Published var localIP: String = NetworkService.localIPAddress()
    @Published var defaultPortRange: ClosedRange<Int> = 3000...8999

    /// 默认容器根目录
    let rootURL: URL

    private let projectsFileName = "projects.json"

    /// UserDefaults 键（只存非敏感配置；密钥永远走 Keychain）
    private enum DefaultsKey {
        static let activeProjectID = "activeProjectID"
        static let aiConfig = "aiConfig"
        static let gitConfig = "gitConfig"
    }

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        rootURL = docs.appendingPathComponent("YuixServer", isDirectory: true)
        ensureRoot()
        loadConfigs()
        loadProjects()
        // 从 Keychain 恢复密钥（内存中缓存，供请求使用）
        aiAPIKey = KeychainStore.read("ai.apiKey") ?? ""
        gitToken = KeychainStore.read("github.token") ?? ""
    }

    // MARK: - 非敏感配置持久化（修复：baseURL/模型等重启即丢的问题）

    private func loadConfigs() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: DefaultsKey.aiConfig),
           let cfg = try? JSONDecoder().decode(AIConfig.self, from: data) {
            aiConfig = cfg
        }
        if let data = d.data(forKey: DefaultsKey.gitConfig),
           let cfg = try? JSONDecoder().decode(GitConfig.self, from: data) {
            gitConfig = cfg
        }
    }

    func persistConfigs() {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(aiConfig) { d.set(data, forKey: DefaultsKey.aiConfig) }
        if let data = try? JSONEncoder().encode(gitConfig) { d.set(data, forKey: DefaultsKey.gitConfig) }
    }

    /// 切换当前项目（统一入口，顺带持久化选择）
    func setActive(_ project: Project?) {
        activeProject = project
        if let id = project?.id.uuidString {
            UserDefaults.standard.set(id, forKey: DefaultsKey.activeProjectID)
        } else {
            UserDefaults.standard.removeObject(forKey: DefaultsKey.activeProjectID)
        }
    }

    // MARK: - 目录

    private func ensureRoot() {
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func projectURL(_ project: Project) -> URL {
        rootURL.appendingPathComponent(project.name, isDirectory: true)
    }

    // MARK: - 项目 CRUD

    /// 新建项目：创建目录、写入模板入口文件，并分配一个空闲端口。
    /// 返回 nil 时可通过 `lastCreateError` 获取失败原因（供表单展示，不再静默失败）。
    private(set) var lastCreateError: String?

    @discardableResult
    func createProject(name: String, language: Language) -> Project? {
        lastCreateError = nil
        let sanitized = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // 名称规则：字母/数字/-/_/. 组成，不以 . 开头，长度 1-64。
        // 目录名会进入终端命令与 zip 路径，含空格或特殊字符会处处踩坑。
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard (1...64).contains(sanitized.count),
              sanitized.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              !sanitized.hasPrefix(".") else {
            lastCreateError = "名称只能包含字母、数字和 - _ .，且不以点开头"
            return nil
        }
        guard !projects.contains(where: { $0.name == sanitized }) else {
            lastCreateError = "已存在同名项目"
            return nil
        }

        let port = nextFreePort()
        let project = Project(name: sanitized, language: language, port: port)
        let dir = projectURL(project)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try language.template.write(to: dir.appendingPathComponent(language.entryFileName), atomically: true, encoding: .utf8)
        } catch {
            lastCreateError = "创建目录失败：\(error.localizedDescription)"
            return nil
        }
        projects.append(project)
        // 修复：旧版漏了这一行 —— 新建项目不出现在底部服务栏，直到重启 App。
        services.append(ServiceInfo(projectID: project.id, name: project.name, port: project.port, language: project.language, pid: nil, status: .stopped))
        saveProjects()
        setActive(project)
        refreshFileTree()
        return project
    }

    func deleteProject(_ project: Project) {
        try? FileManager.default.removeItem(at: projectURL(project))
        projects.removeAll { $0.id == project.id }
        if activeProject?.id == project.id { setActive(nil) }
        services.removeAll { $0.projectID == project.id }
        saveProjects()
        refreshFileTree()
    }

    /// 在 3000-8999 内找一个未被占用的端口
    func nextFreePort() -> Int {
        let used = Set(projects.map(\.port))
        for p in defaultPortRange where !used.contains(p) { return p }
        return 8999
    }

    // MARK: - 项目持久化（仅元数据；代码文件直接落盘）

    private func saveProjects() {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        try? data.write(to: rootURL.appendingPathComponent(projectsFileName))
    }

    private func loadProjects() {
        let url = rootURL.appendingPathComponent(projectsFileName)
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Project].self, from: data) else { return }
        projects = list
        // 同步重建服务列表初值
        services = list.map { ServiceInfo(projectID: $0.id, name: $0.name, port: $0.port, language: $0.language, pid: nil, status: .stopped) }
        // 恢复上次选中的项目；没有记录则选第一个，避免启动后界面空白
        let savedID = UserDefaults.standard.string(forKey: DefaultsKey.activeProjectID)
        if let p = projects.first(where: { $0.id.uuidString == savedID }) {
            activeProject = p
        } else if activeProject == nil {
            activeProject = projects.first
        }
        refreshFileTree()
    }

    // MARK: - 文件树

    /// 递归读取当前项目目录，构建 FileNode 树。
    func refreshFileTree() {
        guard let project = activeProject else { fileTree = []; return }
        fileTree = buildTree(at: projectURL(project), name: project.name)
    }

    private func buildTree(at url: URL, name: String) -> [FileNode] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) else { return [] }
        // 目录在前、文件在后，各自按名称排序 —— 和 Finder / VS Code 的观感一致
        let nodes = items.map { item -> FileNode in
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return FileNode(name: item.lastPathComponent, url: item, isDirectory: isDir,
                            children: isDir ? buildTree(at: item, name: item.lastPathComponent) : nil)
        }
        return nodes.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - 文件操作（可直接被右键菜单调用）

    func readFile(at url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    /// 覆写文件内容。
    /// 注意：不在这里刷新文件树 —— 编辑器每敲一个字都会走到这里，
    /// 旧版顺带重建整棵树，导致 CPU 空转和 List 身份抖动。结构变化请用 createFile/renameFile/deleteFile。
    @discardableResult
    func writeFile(at url: URL, content: String) -> Bool {
        do { try content.write(to: url, atomically: true, encoding: .utf8); return true }
        catch { return false }
    }

    /// 在当前项目目录下新建文件（用于 AI 写入代码）。
    func createFile(named name: String, content: String) -> Bool {
        guard let project = activeProject else { return false }
        let url = projectURL(project).appendingPathComponent(name)
        let ok = writeFile(at: url, content: content)
        if ok { refreshFileTree() }
        return ok
    }

    func renameFile(at url: URL, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), trimmed != ".", trimmed != ".." else { return false }
        let dest = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        guard !FileManager.default.fileExists(atPath: dest.path) else { return false }
        do {
            try FileManager.default.moveItem(at: url, to: dest)
            if selectedFileURL == url { selectedFileURL = dest }
            refreshFileTree()
            return true
        } catch {
            return false
        }
    }

    func deleteFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        refreshFileTree()
    }

    func moveFile(at url: URL, toDirectory dir: URL) -> Bool {
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        do { try FileManager.default.moveItem(at: url, to: dest); refreshFileTree(); return true }
        catch { return false }
    }

    // MARK: - 服务状态

    func startService(_ project: Project) { updateService(project.id) { $0.status = .starting } }
    func markServiceRunning(_ project: Project) { updateService(project.id) { $0.status = .running } }
    func stopService(_ project: Project) { updateService(project.id) { $0.status = .stopped } }
    func markServiceError(_ project: Project) { updateService(project.id) { $0.status = .error } }

    private func updateService(_ id: UUID, _ mutate: (inout ServiceInfo) -> Void) {
        guard let idx = services.firstIndex(where: { $0.projectID == id }) else { return }
        mutate(&services[idx])
    }
}