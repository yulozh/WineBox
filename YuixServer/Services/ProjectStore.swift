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

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        rootURL = docs.appendingPathComponent("YuixServer", isDirectory: true)
        ensureRoot()
        loadProjects()
        // 从 Keychain 恢复密钥（内存中缓存，供请求使用）
        aiAPIKey = KeychainStore.read("ai.apiKey") ?? ""
        gitToken = KeychainStore.read("github.token") ?? ""
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
    @discardableResult
    func createProject(name: String, language: Language) -> Project? {
        // 名称合法性校验，防止路径穿越
        let sanitized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty, !sanitized.contains("/"), !sanitized.contains("..") else { return nil }
        guard !projects.contains(where: { $0.name == sanitized }) else { return nil }

        let port = nextFreePort()
        let project = Project(name: sanitized, language: language, port: port)
        let dir = projectURL(project)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try language.template.write(to: dir.appendingPathComponent(language.entryFileName), atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        projects.append(project)
        saveProjects()
        activeProject = project
        refreshFileTree()
        return project
    }

    func deleteProject(_ project: Project) {
        try? FileManager.default.removeItem(at: projectURL(project))
        projects.removeAll { $0.id == project.id }
        if activeProject?.id == project.id { activeProject = nil }
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
        return items.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { item in
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            var node = FileNode(name: item.lastPathComponent, url: item, isDirectory: isDir, children: nil)
            if isDir { node.children = buildTree(at: item, name: item.lastPathComponent) }
            return node
        }
    }

    // MARK: - 文件操作（可直接被右键菜单调用）

    func readFile(at url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    @discardableResult
    func writeFile(at url: URL, content: String) -> Bool {
        do { try content.write(to: url, atomically: true, encoding: .utf8); refreshFileTree(); return true }
        catch { return false }
    }

    /// 在当前项目目录下新建文件（用于 AI 写入代码）。
    func createFile(named name: String, content: String) -> Bool {
        guard let project = activeProject else { return false }
        let url = projectURL(project).appendingPathComponent(name)
        return writeFile(at: url, content: content)
    }

    func renameFile(at url: URL, to newName: String) -> Bool {
        let dest = url.deletingLastPathComponent().appendingPathComponent(newName)
        do { try FileManager.default.moveItem(at: url, to: dest); refreshFileTree(); return true }
        catch { return false }
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