import Foundation

/// Git 集成：通过 GitHub REST API（Git Data API）实现 clone/pull/push/commit/branch，
/// 不依赖本地 `git` 二进制（iOS 沙盒禁止子进程）。凭证使用 OAuth Token 或个人访问令牌，
/// 存 Keychain，绝不硬编码。
final class GitService {
    static let apiBase = "https://api.github.com"

    struct GitError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 通用请求封装。token 传 nil 表示匿名（公共仓库读取）。
    private static func request(_ path: String, token: String?, method: String = "GET", body: Data? = nil) async throws -> Any {
        guard let url = URL(string: apiBase + path) else { throw GitError(message: "URL 不合法") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(code) else {
            throw GitError(message: String(data: data, encoding: .utf8) ?? "HTTP \(code)")
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: - 仓库

    /// 登录用户可见的仓库列表
    static func listRepos(token: String) async throws -> [[String: Any]] {
        let data = try await request("/user/repos?per_page=100", token: token)
        return data as? [[String: Any]] ?? []
    }

    /// 创建新仓库（用于 AI 自动「推送到一个还不存在的仓库」）
    @discardableResult
    static func createRepo(name: String, owner: String? = nil, `private`: Bool = false, token: String) async throws -> String {
        let body: [String: Any] = ["name": name, "private": `private`, "auto_init": true]
        let data = try await request("/user/repos", token: token, method: "POST", body: try JSONSerialization.data(withJSONObject: body))
        guard let repo = data as? [String: Any],
              let fullName = repo["full_name"] as? String else { throw GitError(message: "创建仓库失败") }
        return fullName
    }

    // MARK: - 分支

    static func listBranches(owner: String, repo: String, token: String) async throws -> [String] {
        let data = try await request("/repos/\(owner)/\(repo)/branches", token: token)
        return (data as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
    }

    /// 从指定 commit/分支创建新分支
    static func createBranch(owner: String, repo: String, branch: String, from: String, token: String) async throws {
        let body: [String: Any] = ["ref": "refs/heads/\(branch)", "sha": from]
        _ = try await request("/repos/\(owner)/\(repo)/git/refs", token: token, method: "POST", body: try JSONSerialization.data(withJSONObject: body))
    }

    // MARK: - Clone（通过 trees + blobs 递归拉取，无需 tar/gzip 解析）

    static func cloneRepo(owner: String, repo: String, into destination: URL, token: String?, progress: @escaping (String) -> Void) async throws {
        // 1. 取默认分支
        let repoInfo = try await request("/repos/\(owner)/\(repo)", token: token) as? [String: Any]
        let branch = repoInfo?["default_branch"] as? String ?? "main"
        progress("获取仓库树（\(branch)）…")

        // 2. 递归获取整棵树（trees 端点接受分支名）
        let treeData = try await request("/git/trees/\(branch)?recursive=1", token: token) as? [String: Any]
        guard let entries = treeData?["tree"] as? [[String: Any]] else { throw GitError(message: "仓库为空或无法读取") }

        let rootDir = destination.appendingPathComponent(repo, isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)

        for entry in entries {
            guard let type = entry["type"] as? String, type == "blob",
                  let path = entry["path"] as? String,
                  let sha = entry["sha"] as? String else { continue }
            progress("下载 \(path)")
            let blob = try await request("/repos/\(owner)/\(repo)/git/blobs/\(sha)", token: token) as? [String: Any]
            guard let content = blob?["content"] as? String,
                  let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters) else { continue }

            let fileURL = rootDir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL)
        }
    }

    // MARK: - Commit + Push（Git Data API 完整流程）

    /// 把一组文件变更提交并推送到指定分支。
    /// - Parameter files: [相对路径: 文件内容]
    static func commitAndPush(owner: String, repo: String, branch: String, files: [String: String], message: String, token: String) async throws {
        // 1. 取分支当前提交
        let refData = try await request("/repos/\(owner)/\(repo)/git/ref/heads/\(branch)", token: token) as? [String: Any]
        guard let obj = refData?["object"] as? [String: Any], let baseSHA = obj["sha"] as? String else {
            throw GitError(message: "无法获取分支 \(branch) 的引用")
        }

        // 2. 取该提交的 tree sha（作为 base_tree）
        let commitData = try await request("/repos/\(owner)/\(repo)/git/commits/\(baseSHA)", token: token) as? [String: Any]
        guard let tree = commitData?["tree"] as? [String: Any], let baseTreeSHA = tree["sha"] as? String else {
            throw GitError(message: "无法获取提交的 tree")
        }

        // 3. 为每个文件创建 blob
        var treeEntries: [[String: Any]] = []
        for (path, content) in files {
            let b64 = Data(content.utf8).base64EncodedString()
            let blobBody: [String: Any] = ["content": b64, "encoding": "base64"]
            let blob = try await request("/repos/\(owner)/\(repo)/git/blobs", token: token, method: "POST", body: try JSONSerialization.data(withJSONObject: blobBody)) as? [String: Any]
            guard let blobSHA = blob?["sha"] as? String else { throw GitError(message: "创建 blob 失败: \(path)") }
            treeEntries.append(["path": path, "mode": "100644", "type": "blob", "sha": blobSHA])
        }

        // 4. 基于 base_tree 创建新 tree
        let treeBody: [String: Any] = ["base_tree": baseTreeSHA, "tree": treeEntries]
        let newTree = try await request("/repos/\(owner)/\(repo)/git/trees", token: token, method: "POST", body: try JSONSerialization.data(withJSONObject: treeBody)) as? [String: Any]
        guard let newTreeSHA = newTree?["sha"] as? String else { throw GitError(message: "创建 tree 失败") }

        // 5. 创建提交
        let commitBody: [String: Any] = ["message": message, "tree": newTreeSHA, "parents": [baseSHA]]
        let newCommit = try await request("/repos/\(owner)/\(repo)/git/commits", token: token, method: "POST", body: try JSONSerialization.data(withJSONObject: commitBody)) as? [String: Any]
        guard let commitSHA = newCommit?["sha"] as? String else { throw GitError(message: "创建 commit 失败") }

        // 6. 更新分支引用（即 push）
        let updateBody: [String: Any] = ["sha": commitSHA, "force": false]
        _ = try await request("/repos/\(owner)/\(repo)/git/refs/heads/\(branch)", token: token, method: "PATCH", body: try JSONSerialization.data(withJSONObject: updateBody))
    }
}