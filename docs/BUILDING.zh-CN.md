# 从源码构建并安装

[English](BUILDING.md) · [返回首页](../README.zh-CN.md)

当前只提供免费的源码自签安装方式，没有 TestFlight、App Store 或通用 IPA。需要 Mac；只有 iPad 无法安装 ZIP。没有 Windows、Android、iPhone 或独立 macOS 安装包。只有 Mac 时可以用 iPad 模拟器体验。

## 1. 下载并打开工程

1. 在 Mac 上[下载最新源码 ZIP](https://github.com/jessezhang2025-7741/percuscore/archive/refs/heads/main.zip)，无需 GitHub 账号。这个链接跟随 `main`，包含后续维护修正。
2. 在 Finder 双击 ZIP 解压，保留整个解压文件夹。用 Xcode 打开其中的 **Percuscore.xcodeproj**。不要用 `Package.swift` 启动 App，它只用于核心测试。
3. 若需要固定的原始预览版，可下载 [v0.1.0-preview.1 源码 ZIP](https://github.com/jessezhang2025-7741/percuscore/archive/refs/tags/v0.1.0-preview.1.zip)。该快照不包含后续修正。

## 2. 准备工具

需要安装完整 Xcode 26 或更新版本的 Mac、Xcode 对应的 iOS 平台 SDK，以及 Python 3。iPad 需要 iPadOS 17 或更新版本。首次打开 Xcode，完成它提示的组件安装。

如果运行下方终端命令，先进入解压后的文件夹：在 Terminal 输入 `cd `，将文件夹从 Finder 拖入窗口，再按回车。

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -version
python3 --version
```

如果 Xcode 使用其他名称，调整路径。这只设置当前终端的工具位置。Apple 芯片 Mac 应使用原生 ARM Python；旧 Intel Homebrew Python 引起架构错误时，可尝试 `/usr/bin/python3`。项目没有第三方软件包依赖。

## 3. 先用模拟器体验（可选）

在 Xcode 顶部选择 **Percuscore** scheme 和已安装的 **iPad Simulator**，点击三角形 **Run**（⌘R）。模拟器不需要设置个人签名 Team。如果没有模拟器，先按 Xcode 提示安装对应 runtime。

也可仅验证无需签名的构建：

```sh
xcodebuild -project Percuscore.xcodeproj -scheme Percuscore \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

## 4. 安装到自己的 iPad

1. 在 **Xcode → Settings → Accounts** 添加自己的 Apple Account。此安装方式可使用免费的 Personal Team，不要求购买开发者会员。
2. 在左侧工程导航中点击蓝色 **Percuscore** 工程，在 **TARGETS** 下选 **Percuscore**，打开 **Signing & Capabilities**。
3. 勾选 **Automatically manage signing**，在 **Team** 选择自己账号的 Personal Team。Team 表示谁为 App 签名；公开工程没有预设作者的 Team。
4. 设置唯一的 **Bundle Identifier**，例如 `com.yourname.percuscore`，将 `yourname` 改为自己的独特文字。这是 App 的身份标识，不是桌面名称；示例并非已保留的标识。如果 Xcode 提示不可用，换一个。
5. 用线缆连接并解锁 iPad，在设备上确认 **Trust This Computer（信任此电脑）**。在 Xcode 顶部的运行设备选择框中选择自己的 iPad，等待配对完成。
6. 按提示打开 iPad **设置 → 隐私与安全性 → 开发者模式（Developer Mode）**，重启后确认。若尚未出现此选项，先完成 Xcode 配对。若系统另要求信任开发者，在 **设置 → 通用 → VPN 与设备管理** 中信任自己的开发者身份。
7. 点击 Xcode **Run**（⌘R），构建和安装期间保持 iPad 解锁。App 打开后选择 **Try an original practice score** 生成原创练习谱，或选择 **Import PDF** 导入 PDF。

签名失败时，先阅读 Xcode 的具体错误，检查账号、Team、标识和设备配对。不要通过卸载已有 App 来排查。个人签名设置留在自己的工程中，不要提交到公共仓库。

## 5. 免费续签与数据保留

免费 Personal Team 的配置描述文件签发后 **7 天过期**。到期后重新连接 iPad，打开同一工程，保持**相同 Apple Account／Team 和 Bundle Identifier**，再次 Run，覆盖更新现有安装。保留这个工程及签名设置，方便下次续签。参见 [Apple 账号说明](https://developer.apple.com/help/account/basics/about-your-developer-account/)和[真机运行说明](https://developer.apple.com/documentation/xcode/running-your-app-in-simulator-or-on-a-device)。

**不要先卸载 App。** 改变 Team 或 Bundle Identifier 可能改变 App 身份，不能假定新安装会继承旧谱库。卸载或改变身份前，导出 `.percuscorebackup`，并确认备份可恢复；不要仅依赖“文件已导出”。操作说明见[备份与恢复](BACKUP.md)。

## 开发检查和版本记录

```sh
python3 scripts/verify.py --level quick
python3 scripts/verify.py --level full
```

完整检查需要可用的 iPad 模拟器。结果保存在被忽略的 `dist/validation/` 中。详见[验收工具](VALIDATION-RUNNER.md)。Git 克隆构建可记录提交及源码修改状态；不含 `.git` 的 ZIP 构建会显示源码身份不可用，这不妨碍编译。

原始公开预览提交 [`4eb5a6f`](https://github.com/jessezhang2025-7741/percuscore/commit/4eb5a6f0ab809831608e6372246dbd900d1963d1) 的 [main 检查](https://github.com/jessezhang2025-7741/percuscore/actions/runs/43806055141)和[标签检查](https://github.com/jessezhang2025-7741/percuscore/actions/runs/43807180223)已通过。它们不等于新用户账号签名或实体 iPad 验收；下载其他修订时请查看对应的 [Actions](https://github.com/jessezhang2025-7741/percuscore/actions) 和[验证范围](VALIDATION-STATUS.md)。
