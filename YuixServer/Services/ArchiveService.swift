import Foundation
import ZIPFoundation

/// 容器压缩导出/导入：使用 ZIPFoundation 生成 .zip（纯 Swift、App Store 合规）。
/// 导出时通过 UIDocumentPickerViewController 让用户选择保存位置（见 Views/DocumentPicker.swift）。
enum ArchiveService {
    enum ArchiveError: LocalizedError {
        case createFailed, extractFailed, notAFolder, nameTaken

        var errorDescription: String? {
            switch self {
            case .createFailed: return "创建压缩包失败"
            case .extractFailed: return "解压失败"
            case .notAFolder:   return "目标不是文件夹"
            case .nameTaken:    return "已存在同名项目"
            }
        }
    }

    /// 将某个项目目录打包为 .zip 并写入指定目录。
    /// - Returns: 生成的 zip 文件 URL
    static func exportProject(_ project: Project, root: URL, to destinationDir: URL) throws -> URL {
        let source = root.appendingPathComponent(project.name, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else {
            throw ArchiveError.notAFolder
        }

        // 文件名：myapp_20260819.zip；同日再次导出先删旧包，避免 create 模式失败
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        let zipURL = destinationDir.appendingPathComponent("\(project.name)_\(formatter.string(from: Date())).zip")
        try? FileManager.default.removeItem(at: zipURL)

        guard let archive = Archive(url: zipURL, accessMode: .create) else {
            throw ArchiveError.createFailed
        }

        // 递归把目录内所有文件按相对路径加入压缩包。
        // 相对路径用前缀长度截取（旧版 replacingOccurrences 会替换字符串中任意位置，
        // 若深层子路径里恰好再次出现项目根路径字符串，条目名就会被截坏）。
        let fm = FileManager.default
        let prefix = source.path + "/"
        if let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let fileURL as URL in enumerator {
                var isDirectory: ObjCBool = false
                fm.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
                if isDirectory.boolValue { continue }
                let relative = String(fileURL.path.dropFirst(prefix.count))
                try archive.addEntry(with: relative, relativeTo: source)
            }
        }
        return zipURL
    }

    /// 从 .zip 恢复（导入）一个项目到根目录，返回新项目目录 URL。
    static func importArchive(at zipURL: URL, root: URL) throws -> URL {
        guard let archive = Archive(url: zipURL, accessMode: .read) else {
            throw ArchiveError.extractFailed
        }
        let name = zipURL.deletingPathExtension().lastPathComponent
        let destination = root.appendingPathComponent(name, isDirectory: true)

        // 同名项目直接拒绝，而不是把两个项目悄悄合并成一个
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ArchiveError.nameTaken
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        for entry in archive {
            _ = try archive.extract(entry, to: destination)
        }
        return destination
    }

    /// 根据目录内容猜测项目语言（导入时不再一律按 Node 处理）
    static func detectLanguage(in dir: URL) -> Language {
        let fm = FileManager.default
        let candidates: [(fileName: String, language: Language)] = [
            ("index.html", .html),
            ("app.py", .python),
            ("index.php", .php),
            ("server.js", .node)
        ]
        for candidate in candidates where fm.fileExists(atPath: dir.appendingPathComponent(candidate.fileName).path) {
            return candidate.language
        }
        return .node
    }
}
