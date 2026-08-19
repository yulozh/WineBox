import UIKit

/// 内置 Linux 环境抽象。
///
/// 推荐方案：Alpine Linux 用户态 —— 即 iSH 项目（开源，GPL-3.0）。
/// Alpine 是安全优先、极小化的发行版：基础系统仅数 MB，使用 musl libc + BusyBox，
/// 以 apk 作为包管理器，最适合在 iOS/移动设备上内嵌。
/// iSH 以「用户态 x86 模拟 + 系统调用翻译」在 iOS 上运行 Alpine，无需越狱。
///
/// 许可证提示：iSH 采用 GPL-3.0（仓库另有 LICENSE.IOS 用于允许上架分发）。
/// 若把其源码直接编译进本应用，可能触发 GPL 传染，要求本应用整体以 GPL 兼容方式开源。
/// 故本工程采用「软集成」：URL Scheme 跳转 iSH，配合 App Group 共享目录交换文件，
/// 不直接链接/打包 iSH 源码，规避许可证与工程复杂度风险。
enum LinuxEnvironment {
    private static let scheme = "ish"

    /// 是否已安装 iSH（Alpine Linux）
    static var isAvailable: Bool {
        guard let url = URL(string: "\(scheme)://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    /// 打开 iSH（Alpine Linux）终端
    static func open() {
        guard let url = URL(string: "\(scheme)://") else { return }
        UIApplication.shared.open(url)
    }

    /// App Group 共享目录：用于在 YuixServer 与 iSH 之间共享项目文件。
    /// 需要：1) 开发者账号开启 App Group；2) 签名时为两个 App 配置相同 group ID。
    static var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.yulozh.YuixServer")
    }

    /// 占位：将项目内容同步到共享目录，供 iSH(Alpine) 访问。
    /// 实际复制逻辑应在「导出容器」或手动触发时执行（见文档《内置Linux集成指南》）。
    @discardableResult
    static func exportRootToShared() -> URL? {
        return sharedContainerURL
    }
}