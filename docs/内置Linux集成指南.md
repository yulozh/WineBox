# 内置 Linux 集成指南（Alpine via iSH）

## 1. 结论：选择 Alpine + iSH

要在 iOS 上「内置一个 Linux 系统」，事实上的标准做法是 **iSH**：它用「用户态 x86 模拟 + 系统调用翻译」在 iOS 上运行 **Alpine Linux**，无需越狱。iSH 是开源项目（实际采用 GPL-3.0，仓库另有 LICENSE.IOS 用于允许 App Store 分发），已在 App Store 以「iSH Shell」上架。

**为什么是 Alpine（而不是 Ubuntu/Debian）**：Alpine 体积仅约 5MB 级别、使用 musl libc + BusyBox、以 apk 管理包，启动快、占用低，是移动端嵌入式 Linux 的最常用选择。Ubuntu/Debian 更「完整」但体积与内存开销大得多，不适合内嵌。

## 2. 两种集成方式

### 方式 A：软集成（推荐，本工程采用）

不把 iSH 源码编译进 YuixServer，而是：

1. **URL Scheme 跳转**：YuixServer 内置「终端」页的「Alpine」按钮通过 `ish://` 打开 iSH。
   - 需在 `Info.plist` 声明 `LSApplicationQueriesSchemes: [ish]`（本工程 `project.yml` 已加入）。
2. **App Group 共享目录**：两个 App 配置相同 App Group，通过 `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` 交换项目文件，实现「在文件管理器里右键 → 在 Linux 中打开/运行」。

优点：规避 GPL 传染和巨大工程复杂度，快速落地。
缺点：iSH 作为独立 App 存在，体验上「跳转」而非完全内嵌。

### 方式 B：深度嵌入（工程量极大，需谨慎）

把 iSH 源码作为子模块直接链接进 YuixServer（iSH 是完整的 x86 模拟器 + Linux 发行版加载器，体量巨大）：

1. `git submodule add https://github.com/iSH-app/ish`。
2. 遵循其 `CONTRIBUTING`/构建脚本（需 Python3 + Ninja + 后端 Java/Kotlin 等）编译。
3. 在你的 View 中嵌入其终端 UIViewController。

⚠️ **许可证风险**：iSH 为 GPL-3.0，深度链接后你的整个分发包很可能必须以 GPL 兼容协议开源。若你计划闭源商用上架，请先做合规评估或优先选方式 A。

## 3. 本工程的接入点

| 文件 | 作用 |
|---|---|
| `Services/LinuxEnvironment.swift` | `LinuxEnvironment.open()` 跳转 iSH；`sharedContainerURL` 返回共享目录 |
| `Services/ShellService.swift` | 沙盒内轻量伪终端（ls/pwd/cat/echo/help），供内置终端页使用 |
| `Views/TerminalView.swift` | 内置「终端」UI（毛玻璃暗色），并挂载「Alpine」打开按钮 |
| `project.yml` | 已声明 `LSApplicationQueriesSchemes: [ish]` |

## 4. 操作步骤（方式 A）

1. 设备从 App Store 安装「iSH Shell」。
2. YuixServer → 设置 → GitHub/网络，或直接进「终端」页，点「Alpine」。
3. 若需共享文件：在 Xcode 给 YuixServer 与 iSH 打开 App Group（见《IPA打包与签名指南》第 3 节），并在 `LinuxEnvironment.swift` 填入相同 group ID。
4. 在 iSH 中用 `apk add python3 nodejs php` 安装运行时，然后用共享目录编辑/运行代码。

## 5. 替代方案（了解即可）

| 方案 | 说明 |
|---|---|
| a-Linux | 另一个 iOS 上的 aarch64 Linux 用户态（基于 Termux 类似思路），提供 Alpine/Ubuntu 等镜像 |
| UTM SE | 基于 QEMU 的无 JIT 全系统虚拟化，可跑完整 Linux 内核但极慢，仅作参考 |

## 6. 术语与许可核对

- iSH 官方仓库：github.com/iSH-app/ish（原 ss18/ish）；许可证 GPL-3.0 + LICENSE.IOS。
- Alpine Linux：alpinelinux.org，musl+BusyBox+apk，极小体积。
- 上架声明中请注明是否包含 iSH 及其许可证；若仅软集成（跳转），无需携带其源码，一般无需开源自己的代码。