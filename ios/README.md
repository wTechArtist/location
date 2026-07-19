# WLOC iOS（方案 A）

本分支是依赖 Shadowrocket 的个人签名版本。WLOC 提供地图选点、收藏、坐标写入/清除、Shadowrocket 启停指令、配置文件转交和定位回读核验；Shadowrocket 继续负责 VPN、MITM 与 WLOC 响应脚本。

## 为什么使用方案 A

- 主 App 不包含 Packet Tunnel、Network Extension、App Group 或 Libbox。
- 可以尝试使用 Xcode Personal Team 给自己的设备开发签名，不再被 Network Extension entitlement 阻塞。
- App 无法读取 Shadowrocket 的真实 VPN 开关，也无法替用户切换 iOS 的系统定位总开关。界面会明确区分“已发出指令”和“已取得核验证据”。

## 首次设置

1. 安装 Shadowrocket。
2. 在 WLOC 的“Shadowrocket 设置”中点“一键安装 WLOC 模块”，在 Shadowrocket 中确认导入并启用；一键链接失败时再使用内置文件分享兜底。
3. 按 Shadowrocket 与 iOS 的提示安装 MITM CA，并到证书信任设置中开启完全信任。
4. 回到 WLOC 点击“检测并完成设置”。只有真实返回 WLOC Settings JSON，App 才会自动记录模块与证书可用。

## 定位流程

1. 在地图点击或搜索目标位置，点击“确定定位”。
2. WLOC 通过 `https://gs-loc.apple.com/wloc-settings/save` 写入坐标并立即查询确认。
3. WLOC 发出 `shadowrocket://disconnect`，用户按界面提示手动关闭系统定位总开关。
4. WLOC 发出 `shadowrocket://connect`，用户手动重新开启系统定位总开关。
5. WLOC 再次查询模块并请求新的系统定位。坐标距离不满足阈值时不会报告成功。

“恢复真实定位”使用同一流程，但先清除 Shadowrocket 中的 `wloc_settings` 持久化坐标。

## 导入 Shadowrocket 配置

“Shadowrocket 设置 > 导入配置”可从“文件”选择 `.conf` 或其他配置，然后通过系统分享面板交给 Shadowrocket 打开。WLOC 不解析、保存或声称已经导入代理凭据；最终结果以 Shadowrocket 的确认界面为准。

## macOS 构建与测试

需要 Xcode 16.4 和 XcodeGen：

```sh
cd ios
xcodegen generate
./scripts/test-macos.sh
```

脚本会执行 Swift Package 测试、无签名真机架构编译和 iPhone Simulator 测试。

生成经过结构审计、供本地重签名使用的无签名 IPA：

```sh
./scripts/package-unsigned-macos.sh
```

无签名包固定使用 `com.weiweiliang.wloc.schemea`，避免同一手机安装出两个同名 App、导致定位权限和本地状态分裂。确需另一个标识时才显式设置 `WLOC_BASE_BUNDLE_IDENTIFIER`。脚本会验证 arm64、标准 `Payload/WLOC.app` 布局、内置 `wloc.module`，并确认不含签名、App Extension 或 Libbox。无签名 IPA 不能直接安装，也不能替代[方案 A 真机验收清单](../docs/ios-acceptance-scheme-a.md)。

签名归档：

```sh
WLOC_DEVELOPMENT_TEAM=你的10位TeamID \
WLOC_BASE_BUNDLE_IDENTIFIER=你的唯一BundleID \
./scripts/archive-macos.sh
```

Personal Team 的设备注册、安装方式和签名有效期仍受 Apple 限制。归档或模拟器测试通过不代表真实 iPhone 端到端验收完成。

## Windows 真机自动化验收

`scripts/real-device-e2e.py` 可在 Windows 上通过已配对的 USB iPhone 和预装的 WebDriverAgent，自动执行模块检测、地图选点/搜索/当前位置/收藏、虚拟定位、系统定位服务关/开、结果回读、恢复真实定位及失败清理。测试驱动系统“设置”模拟用户操作；这不表示正式 App 获得了越权切换系统定位总开关的能力。

前置条件：iPhone 已开启开发者模式并信任电脑；WLOC 与 WebDriverAgent Runner 已使用同一可用开发签名安装。创建隔离环境并安装固定版本依赖：

```powershell
py -m venv .venv-wloc-device
.\.venv-wloc-device\Scripts\python.exe -m pip install -r .\scripts\requirements-real-device.txt
```

执行完整定位往返验收：

```powershell
.\.venv-wloc-device\Scripts\python.exe .\scripts\real-device-e2e.py `
  --udid <iPhone-UDID> `
  --runner-bundle-id <WebDriverAgentRunner-Bundle-ID> `
  --app-bundle-id <已安装WLOC-Bundle-ID> `
  --scenario full-location-roundtrip `
  --output-dir <证据目录>
```

脚本退出码为 0 才算本轮通过，并在证据目录写入 `result.json`、每个关键阶段的 PNG 截图和 XML 可访问性树。WebDriverAgent 在场景开始前握手失败时默认安全重试一次，可用 `--startup-attempts` 调整；场景执行失败也会写入包含错误类型和原因的 `result.json`。若中途失败，脚本会尽力把系统定位服务恢复为开启状态；仍应人工核对最终状态。

地图功能单独验收可将场景改为 `--scenario map-features`。该场景会删除自己创建的临时收藏，不会修改 Shadowrocket 配置。`--scenario config-picker-cancel` 用于验证系统文件选择器的打开与取消，也不会选择或导入任何配置。

`--scenario final-connection-state` 会从 WLOC 发出 Shadowrocket 连接指令，读取 Shadowrocket 前台开关状态，再回到 WLOC 验证模块响应；它不会把“URL 已被 iOS 接受”当作隧道已连接。若连接 URL 在当前 Shadowrocket 版本上只打开 App，场景会失败。`--scenario shadowrocket-ui-recovery` 仅供验收清理使用：测试驱动模拟用户点一次 Shadowrocket 开关并验证模块恢复，不能据此宣称正式 App 能跨 App 控制 VPN。
