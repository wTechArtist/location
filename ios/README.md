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
