import Foundation
import ZIPFoundation

/// 容器压缩导出/导入：使用 ZIPFoundation 生成 .zip（纯 Swift、App Store 合规）。
/// 导出时通过 UIDocumentPickerViewController 让用户选择保存位置（见 Views/DocumentPicker.swift）。
enum ArchiveService {
    enum ArchiveError: LocalizedError {
        case createFailed, extractFailed, notAFolder
        var errorDescription: String? {
            switch self {
            case .createFailed: return "创建压缩包失败"
            case .extractFailed: return "解压失败"
            case .notAFolder: return "目标不是文件夹"
            }
        }
    }

    /// 将某个项目目录打包为 .zip 并写入用户指定的目录。
    /// - Returns: 生成的 zip 文件 URL
    static func exportProject(_ project: Project, root: URL, to destinationDir: URL) throws -> URL {
        let source = root.appendingPathComponent(project.name, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else {
            throw ArchiveError.notAFolder
        }

        // 文件名：myapp_20260819.zip
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        let fileName = "\(project.name)_\(formatter.string(from: Date())).zip"
        let zipURL = destinationDir.appendingPathComponent(fileName)

        guard let archive = Archive(url: zipURL, accessMode: .create) else {
            throw ArchiveError.createFailed
        }

        // 递归把目录内所有文件按相对路径加入压缩包
        let fm = FileManager.default
        if let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                let relative = fileURL.path.replacingOccurrences(of: source.path + "/", with: "")
                var isDirectory: ObjCBool = false
                fm.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
                if isDirectory.boolValue {
                    continue // ZIPFoundation 会在添加文件时自动保留目录
                }
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
        let destination = root.appendingPathComponent(zipURL.deletingPathExtension().lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        for entry in archive {
            _ = try archive.extract(entry, to: destination)
        }
        return destination
    }
}