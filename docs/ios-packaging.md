# WLOC iOS 更新与打包指南（方案 A）

本文用于以后修改 WLOC iOS 功能后，重新测试、生成 IPA、签名安装和完成真机验收。当前 iOS App 位于 `codex/ios-scheme-a` 分支，依赖 Shadowrocket 模块，不包含 Network Extension。

## 最短打包流程

每次更新 App 后按下面顺序执行：

1. 修改版本号和代码。
2. 在 Mac 上运行测试，或把代码推送到 `codex/ios-scheme-a` 让 GitHub Actions 自动测试。
3. 从 Actions 下载 `WLOC-SchemeA-unsigned.ipa`。
4. 在 Windows 上用 Sideloadly 和原来的 Apple ID 覆盖安装，不要先删除旧 App。
5. 在真实 iPhone 上完成定位切换、外部地图精度和恢复真实定位验收。

无签名 IPA 只是待签名的安装包，不能在 iPhone“文件”App 中直接打开安装。编译成功也不等于真机功能已经通过。

## 分支约定

- GitHub 首页使用 `master`，这里只维护通用的根目录 `README.md`。
- iOS App 的开发和打包使用 `codex/ios-scheme-a`。
- 更新 iOS 功能时不要把尚未验收的代码直接推入 `master`。

开始修改前：

```sh
git switch codex/ios-scheme-a
git pull --ff-only origin codex/ios-scheme-a
git status --short
```

如果工作树已经有未提交改动，先确认这些改动的所有者和用途，不要使用 `git reset --hard` 或直接覆盖。

## 常用文件位置

- App 界面：`ios/App/Views/`
- 定位切换流程：`ios/App/AppModel.swift`
- Shadowrocket 指令：`ios/App/ShadowrocketController.swift`
- Shadowrocket 通信：`ios/App/ShadowrocketWlocBridge.swift`
- App 内置模块：`ios/App/Resources/wloc.module`
- 核心模型和坐标转换：`ios/Packages/WlocCore/Sources/WlocCore/`
- 单元测试：`ios/Packages/WlocCore/Tests/WlocCoreTests/`
- XcodeGen 配置和版本号：`ios/project.yml`
- GitHub Actions：`.github/workflows/ios-build.yml`
- 真机验收脚本：`ios/scripts/real-device-e2e.py`

## 修改版本号

发布新版本前修改 `ios/project.yml`：

```yaml
CURRENT_PROJECT_VERSION: 2
MARKETING_VERSION: 0.2.0
```

- `MARKETING_VERSION` 是用户看到的版本，例如 `0.2.0`。
- `CURRENT_PROJECT_VERSION` 是递增的构建号，只能向上增加。
- 仅覆盖安装自己的设备时也建议增加构建号，方便区分安装包和验收证据。

## 方法一：GitHub Actions 自动打包（推荐）

提交 iOS 修改并推送：

```sh
git status --short
git add -- ios/App/Views/MapHomeView.swift ios/project.yml
git commit -m "feat(ios): describe the change"
git push origin codex/ios-scheme-a
```

上面的两个文件只是示例，请替换成本次实际修改的文件。只提交本次确实修改的文件；如果工作树里还有其他人的文件，不要使用笼统的 `git add .` 或 `git add ios`。

当提交包含 `ios/**` 或 `.github/workflows/ios-build.yml` 时，GitHub Actions 会自动运行 `iOS build`。也可以在 GitHub 的 `Actions > iOS build > Run workflow` 中手动启动。

流水线会执行：

1. Shadowrocket 模块脚本测试。
2. Swift Package 单元测试。
3. iPhone arm64 无签名构建。
4. iPhone Simulator 集成测试。
5. IPA 结构审计，确认含定位用途说明和内置模块，且不含 App Extension、Libbox 或残留签名。

流水线成功后，在该次运行页面底部下载构建产物：

```text
WLOC-SchemeA-unsigned
└── WLOC-SchemeA-unsigned.ipa
```

Actions 产物目前只保留 7 天，建议下载后按提交哈希保存，例如：

```text
WLOC-<commit短哈希>/WLOC-SchemeA-unsigned.ipa
```

安装前可计算 SHA-256，方便确认文件没有拿错：

```powershell
Get-FileHash .\WLOC-SchemeA-unsigned.ipa -Algorithm SHA256
```

安装了 GitHub CLI 时也可以使用：

```sh
gh run list --workflow ios-build.yml --branch codex/ios-scheme-a --limit 5
gh run watch <run-id> --exit-status
gh run download <run-id> -n WLOC-SchemeA-unsigned -D ./WLOC-<commit短哈希>
```

## 方法二：在 Mac 本地生成无签名 IPA

### 前置环境

- macOS
- Xcode 16.4
- XcodeGen
- 至少一个已安装的 iPhone Simulator Runtime

首次准备：

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
brew install xcodegen
```

运行完整构建测试：

```sh
cd <仓库目录>/ios
./scripts/test-macos.sh
```

生成无签名 IPA：

```sh
./scripts/package-unsigned-macos.sh
```

默认输出到：

```text
ios/Artifacts/WLOC-SchemeA-unsigned-<UTC时间>.ipa
```

脚本不会覆盖已有文件，并会输出 SHA-256。需要指定文件名时：

```sh
WLOC_UNSIGNED_IPA_PATH="$PWD/Artifacts/WLOC-SchemeA-unsigned.ipa" \
./scripts/package-unsigned-macos.sh
```

## 方法三：在 Mac 生成有签名 IPA

需要 Apple Team ID、可用证书和对应描述文件：

```sh
cd <仓库目录>/ios

WLOC_DEVELOPMENT_TEAM=你的10位TeamID \
WLOC_BASE_BUNDLE_IDENTIFIER=com.weiweiliang.wloc.schemea \
WLOC_EXPORT_METHOD=debugging \
./scripts/archive-macos.sh
```

`WLOC_EXPORT_METHOD` 可选值：

- `debugging`：开发签名或 Personal Team 设备测试。
- `release-testing`：付费账号的 Ad Hoc 测试分发。
- `app-store-connect`：上传 App Store Connect/TestFlight。

脚本输出 `.xcarchive` 和 `.ipa`，并检查签名、Bundle ID，以及方案 A 不应出现的 Network Extension、App Group 和 Libbox。

## Windows 使用 Sideloadly 签名安装

免费 Apple ID 的 App 通常有效 7 天。重新签名就是使用同一个 Apple ID 再覆盖安装一次。

1. 不要删除手机里的 WLOC。
2. iPhone 连接 Windows，保持解锁并信任电脑。
3. 打开 Sideloadly，把 `WLOC-SchemeA-unsigned.ipa` 拖入窗口。
4. 选择正确的 iPhone。
5. 使用上次安装 WLOC 的同一个 Apple ID。
6. 不要修改 Bundle ID；保持与上一次相同的安装选项。
7. 点击 `Start`，完成 Apple 验证码后等待 `Done` 或 `100%`。
8. 打开 WLOC，确认原来的定位权限和设置仍然存在。

如果使用不同 Apple ID、修改 Bundle ID，或先删除旧 App，iOS 可能把它当作另一个 App，原有权限和本地数据也可能丢失。

可以在 Sideloadly 中开启自动刷新；电脑和 iPhone 通过 USB 或同一网络重新连接时，Sideloadly Daemon 会尝试在签名过期前刷新。

## 修改 Shadowrocket 模块时的额外步骤

普通 SwiftUI 界面修改不需要改模块地址。只有修改下列文件时才执行本节：

- `dist/wloc.js`
- `dist/wloc-settings.js`
- `ios/App/Resources/wloc.module`

模块脚本使用固定 Git commit 的公开 Raw URL。更新步骤：

1. 修改并测试 `dist/wloc.js` 或 `dist/wloc-settings.js`。
2. 提交并推送到仍可公开读取的仓库或公共静态文件服务。
3. 取得包含新脚本的 40 位 commit SHA。
4. 更新 `ios/App/Resources/wloc.module` 中两个 `script-path`。
5. 再提交模块文件，取得包含新模块的 commit SHA。
6. 更新 `ios/App/AppModel.swift` 中 `pinnedModuleDownloadURL`。
7. 执行模块测试和完整 iOS 测试。

模块测试：

```sh
node ios/scripts/test-shadowrocket-module.mjs
```

如果主仓库以后改成私有，以上 Raw URL 不能继续指向私有仓库。应把 `wloc.module`、`wloc.js` 和 `wloc-settings.js` 放在单独的公开资源仓库或公共静态文件服务，再更新这些地址。

## 真机验收标准

IPA 打包、模拟器测试和成功安装都不能替代真实 iPhone 验收。至少检查：

1. 首次安装、定位授权、Shadowrocket 模块和 MITM 证书可用。
2. 搜索或地图选点后，App 保存的是 WGS-84 目标坐标。
3. 确定定位流程实际完成 Shadowrocket 断开/重新连接，以及系统定位服务关闭/重新开启。
4. 新的系统 `CLLocation` 回读距离目标不超过模块声明精度；当前默认门槛为 25 米。
5. 在外部 Apple 地图中检查蓝点与目标地点一致，不能只看 WLOC 自己的红色标记。
6. 至少覆盖一个中国大陆地点；正式精度回归建议覆盖广州、北京、上海。
7. “恢复真实定位”后确认模块为真实定位透传，并取得新的真实系统位置。
8. 验收结束时确认系统定位服务和 Shadowrocket 都处于用户要求的开启状态。

Windows 已配对真机的基础自动化命令：

```powershell
py -m venv .venv-wloc-device
.\.venv-wloc-device\Scripts\python.exe -m pip install -r .\ios\scripts\requirements-real-device.txt

.\.venv-wloc-device\Scripts\python.exe .\ios\scripts\real-device-e2e.py `
  --udid <iPhone-UDID> `
  --runner-bundle-id <WebDriverAgentRunner-Bundle-ID> `
  --app-bundle-id <已安装WLOC-Bundle-ID> `
  --scenario full-location-roundtrip `
  --output-dir <证据目录>
```

脚本退出码为 0 才表示该自动化场景通过。仍需保存外部地图截图并核对最终真实定位恢复状态。

## 每次发布需要保存的记录

建议为每个安装包记录：

```text
版本号：
构建号：
Git commit：
GitHub Actions run：
IPA SHA-256：
签名 Apple Team：
安装后的 Bundle ID：
iPhone 型号与 iOS 版本：
虚拟定位回读距离：
外部地图检查结果：
恢复真实定位结果：
证据目录：
```

只有最后三项真机检查完成后，才能对外说明该版本已经通过端到端验收。

## 常见问题

### 推送后没有触发 Actions

自动触发只监听 `ios/**` 和 `.github/workflows/ios-build.yml`。只修改文档时不会自动打包，可在 Actions 页面手动运行 `iOS build`。

### IPA 放进手机后不能打开

无签名 IPA 不能直接安装。使用 Sideloadly 重签名，或在 Mac 上使用 `archive-macos.sh` 生成有签名 IPA。

### WLOC 突然提示需要开发者模式或无法验证

免费签名可能已经过期。保持相同 Apple ID 和 Bundle ID，用 Sideloadly 覆盖安装。

### 模块突然不可用

确认 Shadowrocket 已连接、WLOC 模块已启用、MITM 证书已完全信任，并检查模块中的公开脚本 URL 是否仍能直接访问。

### 打包成功但定位不准

不要重新打同一个包掩盖问题。保存目标坐标、系统回读坐标、距离、外部地图截图和模块响应，修复后重新走完整测试、打包和真机验收流程。
