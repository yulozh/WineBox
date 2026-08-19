# YuixServer IPA 打包与签名指南

## 0. 重要说明（为什么不能直接给你 IPA）

一个可安装到真机的 iOS `.ipa` 必须满足两个硬性条件，而这两点都**只能在你的 Mac 上完成**：

1. **编译环境**：iOS 应用只能用 Apple 的 Xcode（macOS）+ iOS SDK 工具链构建，无法在 Linux/Windows/云端无头环境交叉编译。
2. **代码签名**：iOS 只允许安装被 Apple 认可的证书签名的应用。签名需要 Apple 开发者账号生成的证书与描述文件（Provisioning Profile），并且设备 UDID 要登记到该账号下。

因此，任何「无签名 IPA」都无法装进真机。下面给出从本工程到可安装 IPA / TestFlight 的完整路径。

## 1. 准备

| 项目 | 要求 |
|---|---|
| 硬件 | 一台 Mac |
| 系统 | macOS 13 Ventura 或更高 |
| 工具 | Xcode 15+（App Store 免费下载） |
| 账号 | Apple Developer 账号（免费 Personal Team 可用于真机调试；上架/TestFlight 需付费 $99/年） |
| 设备 | iPhone/iPad，iOS 16+，用数据线接入 Mac |

## 2. 生成并打开工程

本工程用 XcodeGen 管理，先安装并生成 `.xcodeproj`：

```bash
brew install xcodegen
cd YuixServer
xcodegen generate
open YuixServer.xcodeproj
```

> 若不用 XcodeGen：新建 SwiftUI iOS 工程，把 `YuixServer/YuixServer/` 下所有源码拖入，再用 SPM 添加依赖 `https://github.com/weichsel/ZIPFoundation.git`。

首次打开会自动解析 ZIPFoundation 依赖，等待 SPM 拉取完成。

## 3. 配置签名

1. 选中工程 → 目标 `YuixServer` → **Signing & Capabilities**。
2. 勾选 **Automatically manage signing**。
3. Team 选择你的开发者账号（免费 Personal Team 或付费团队）。
4. 把 Bundle Identifier 改为唯一值（如 `com.yourname.YuixServer`）。

> 若要启用「内置 Linux（iSH）App Group 共享目录」，还需：
> - 在 **Signing & Capabilities** 点击 `+ Capability` → 添加 **App Groups**；
> - 新建一个 group，如 `group.com.yourname.YuixServer`；
> - 在 `LinuxEnvironment.swift` 中把相同的 group ID 填进 `containerURL(forSecurityApplicationGroupIdentifier:)`。

## 4. 真机调试（最快验证）

1. 设备用数据线连接 Mac，信任此电脑。
2. Xcode 顶部选择你的设备（而非模拟器）。
3. 点击 **Run（▶）**。首次会提示在设备上「设置 → 通用 → VPN 与设备管理」信任你的开发者证书。

## 5. 导出 IPA（三种方式）

### 方式 A：Xcode Organizer（推荐）

1. 设备选择 **Any iOS Device (arm64)**。
2. 菜单 **Product → Archive**。
3. 归档完成后打开 **Window → Organizer**，选中该归档 → **Distribute App**。
4. 选择分发方式：
   - **App Store Connect**：上传后走 TestFlight / 上架。
   - **Ad Hoc**：给登记了 UDID 的设备安装。
   - **Development**：开发测试。
5. 按向导导出，最终得到 `.ipa` 文件（或直接上传）。

### 方式 B：命令行 `xcodebuild`

```bash
cd YuixServer
xcodegen generate

# 归档
xcodebuild -project YuixServer.xcodeproj \
  -scheme YuixServer -configuration Release \
  -archivePath build/YuixServer.xcarchive \
  -destination "generic/platform=iOS" archive

# 导出 IPA（需要 build/ExportOptions.plist）
xcodebuild -exportArchive \
  -archivePath build/YuixServer.xcarchive \
  -exportOptionsPlist build/ExportOptions.plist \
  -exportPath build/
```

`ExportOptions.plist` 示例（Development 分发）：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>development</string>
    <key>teamID</key><string>你的TeamID</string>
    <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
```

## 6. 分发到设备

| 场景 | 方式 |
|---|---|
| 个人多台设备 | Ad Hoc 分发（登记每台设备 UDID）后拖入 Apple Configurator / Finder 安装 |
| 测试团队 | **TestFlight**（推荐，无需 UDID 安装测试） |
| 长期个人侧载 | AltStore / Sideloadly（用个人 Apple ID 每 7 天需重签一次） |
| 正式发布 | App Store 上架 |

> ⚠️ 关于本应用的「子进程/端口监听」：**App Store 审核版本**不能真正运行 Python/PHP/Node 子进程或监听 3000–8999 端口；要真端口监听，只能用个人开发者证书侧载并在 `RuntimeProviding` 里用 `Process` 实现（详见《内置Linux集成指南》与 `ServiceRegistry.swift` 注释）。

## 7. 常见问题

- **签名报错 "No signing certificate"**：先在 Xcode 的 Preferences → Accounts 登录 Apple ID，让 Xcode 自动生成证书。
- **依赖拉取失败**：确认网络可访问 GitHub，或在 Xcode → File → Packages 里手动 Resolve。
- **真机无法安装**：检查 UDID 是否登记、证书是否被信任、系统版本是否 ≥ iOS 16。