# 用你的证书出一道可安装的 IPA（无需本地 Mac）

> 针对你上传的签名材料：`证书文件.p12` + `描述文件.mobileprovision` + `密码.txt`。
> 我已校验：这是 **iPhone Distribution** 证书（TeamID `283M9R6THP`），配套 **Ad Hoc 单设备描述文件**，
> 已锁定你的设备 UDID `00008030-001A605C3A40A02E` 和 Bundle ID `app.star2977.grape6286`，
> 有效期到 **2027-05-16**，p12 口令为 `1`。

## 0. 先厘清：为什么在聊天里"直接发 IPA"做不到

| 环节 | 需要什么 | 你已提供 |
|---|---|---|
| ① 编译（源码 → arm64 二进制） | macOS + Xcode + iOS SDK | ❌（本地没有 Mac） |
| ② 签名（二进制 → 可安装 IPA） | .p12 + .mobileprovision + UDID | ✅（刚上传） |
| ③ 源码管理 | GitHub 账号 | ✅（yulozh） |

Git 只能做 ③，证书只能做 ②，都做不了 ①。所以采用 **GitHub Actions 的 macOS 云端机** 补上 ①，
再用你的证书做 ②，最终产出可下载的 IPA。全程你不需要 Mac、不需要 Xcode。

## 1. 把工程推到你的 GitHub

在电脑（任意系统）执行（仓库名可自定，这里用 `YuixServer`）：

```bash
git init
git add .
git commit -m "YuixServer 初始版本"
git branch -M main
git remote add origin https://github.com/yulozh/YuixServer.git
# 如果没有该仓库，先在 github.com 新建一个空仓库 YuixServer
git push -u origin main
```

> 需要用你的 GitHub 凭据；若开了两步验证，改用 Personal Access Token 代替密码。

我会把 `YuixServer/` 完整工程放到你的工作目录，直接就是可推的仓库（已含 `.github/workflows/build-ipa.yml`）。

## 2. 在 GitHub 仓库里添加 3 个 Secrets

打开仓库 **Settings → Secrets and variables → Actions → New repository secret**，依次添加：

| Name | 值 |
|---|---|
| `P12_BASE64` | 证书文件的 Base64（见下） |
| `MOBILEPROVISION_BASE64` | 描述文件的 Base64（见下） |
| `P12_PASSWORD` | `1` |

生成 Base64（Mac / Linux 终端）：

```bash
base64 -i 证书文件.p12 | pbcopy        # 或直接输出复制
base64 -i 描述文件.mobileprovision
```

生成 Base64（Windows）：用 `certutil -encode 证书文件.p12 tmp.txt`，
把输出第一行 `-----BEGIN CERTIFICATE-----` 和最后一行 `-----END CERTIFICATE-----` 之间的部分拼接成一行。

## 3. 触发打包

两种方式任选：

- **方式 A**：仓库 **Actions → "Build & Sign IPA" → Run workflow → Run workflow**（手动触发）。
- **方式 B**：本地打个 tag 再 push：

```bash
git tag v0.1.0
git push origin v0.1.0
```

一次构建约 10–20 分钟（云端下载 Xcode 工具链 + 编译 + 签名）。

## 4. 下载 IPA

构建成功后，在该次运行的 **Artifacts** 区下载 `YuixServer.ipa`。

## 5. 安装到你那台 iPhone

这是 Ad Hoc 单设备签名，**只能装到 UDID 为 `00008030-001A605C3A40A02E` 的那台设备**。安装方式（任选）：

| 工具 | 平台 | 说明 |
|---|---|---|
| 爱思助手 | Windows/Mac | 连接手机 →「应用游戏/签名」→ 导入 IPA 安装 |
| iMazing | Windows/Mac | 拖入 IPA 安装 |
| Apple Configurator 2 | Mac | 免费官方工具 |
| Sideloadly / AltStore | Win/Mac | 若用你的个人 Apple ID 重签则无需本次证书 |

> 首次安装后，在 iPhone「设置 → 通用 → VPN 与设备管理」里信任这个签名描述文件即可打开。

## 6. 重要限制（再次提醒）

- 这个证书是**第三方签名服务**发出的 Ad Hoc 证书，不是 App Store 上架证书；`app.star2977.grape6286` 是它约定的固定 Bundle ID。
- **App Store 版本**无论如何都不能真正运行 Python/PHP/Node 子进程或监听 3000–8999 端口（iOS 沙盒限制）。你现在出的这台侧载版，代码里运行时仍走 `RuntimeProviding` 的占位实现；要真正监听端口，还需在 `ServiceRegistry.swift` 里用 `Process` 补全（个人签名下可运行）。
- 证书 2027-05-16 到期，到期后需重新向签名服务购买/续期并更新 Secrets。

## 7. 排错

| 现象 | 处理 |
|---|---|
| 归档报 "Provisioning profile not found" | 检查 `MOBILEPROVISION_BASE64` 是否正确的文件、是否含换行被截断 |
| 报 "No signing certificate" | `P12_BASE64` 或口令 `1` 不对，或 p12 未成功导入 |
| ZIPFoundation 依赖解析失败 | 云端网络偶发，重跑一次 workflow |
| 设备装不上/闪退 | 确认目标设备 UDID 是 `...A02E`，并已信任描述文件 |