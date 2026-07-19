# iOS 方案 A 真机验收清单

本清单适用于依赖 Shadowrocket 的方案 A。模拟器、单元测试、无签名 IPA 和“已发送 URL 指令”都不能替代真实 iPhone 的端到端证据。

## 测试基线

- [x] 记录 iPhone 型号、iOS 版本与构建号。
- [x] 记录 WLOC 版本、Git commit、Bundle ID 与签名方式。
- [x] 记录 Shadowrocket 版本，以及 Wi-Fi/蜂窝网络类型；不得记录代理凭据。
- [x] WLOC 已签名并安装到真实 iPhone，首次启动无崩溃。

## 首次设置

- [ ] 从 WLOC 分享并在 Shadowrocket 中导入、启用内置 `wloc.module`。
- [x] 按 Shadowrocket/iOS 提示安装 MITM CA，并在系统设置中开启完全信任。
- [x] “设置完成”的界面状态不能单独算成功；检测必须真实取得 `/wloc-settings/query` JSON。
- [ ] 拒绝导入或未信任证书时，WLOC 明确显示未就绪，不得误报成功。

## 地图与配置导入

- [ ] 地图点击/长按、搜索、当前位置、收藏与历史记录可用。
- [ ] 文件选择器可选择配置文件，并通过系统分享面板交给 Shadowrocket。
- [ ] WLOC 仅显示“已交给 Shadowrocket”，最终导入成功必须以 Shadowrocket 的确认界面为准。
- [ ] 取消文件选择、取消分享或 Shadowrocket 拒绝配置时，WLOC 不得显示导入成功。

## 设置虚拟定位

- [x] 选择目标坐标后，`/wloc-settings/save` 返回成功，随后 `/wloc-settings/query` 回读同一目标。
- [x] `shadowrocket://disconnect` 与 `shadowrocket://connect` 只记录为“指令已发出”，不得当作 VPN 状态证据。
- [x] 用户按界面提示手动关闭、重新开启系统定位服务；WLOC 无法代替用户切换系统总开关。
- [x] 重新请求系统定位后，回读坐标与目标距离在界面阈值内，才显示“定位已验证”。
- [ ] Apple 定位响应未被模块处理、定位权限被拒绝、回读超时或距离超阈值时，只能显示未生效/无法验证。
- [ ] 分别在 Wi-Fi 与蜂窝网络上验证一次，并确认常用 App 取得目标位置。

## 恢复真实定位

- [x] 恢复操作先清除 Shadowrocket 模块中的持久化目标，`/wloc-settings/query` 确认已清除。
- [x] 断开/连接 Shadowrocket 指令与系统定位手动关/开流程完整执行。
- [x] WLOC 重新取得真实定位；不得以“指令已发出”代替恢复结果。
- [ ] 最终状态为系统定位服务开启、Shadowrocket 正常连接，原有代理配置仍能使用。

## 稳定性与相互影响

- [ ] 连续设置/恢复 20 次无崩溃、无状态串线，最后一次坐标与界面一致。
- [ ] Wi-Fi 与蜂窝双向切换、锁屏 30 分钟、重启手机后仍能明确显示真实状态。
- [ ] 测试前后对比 Shadowrocket 当前配置、节点、规则与按需连接设置，WLOC 不得静默覆盖它们。
- [ ] 配置损坏、模块停用、证书失效、Shadowrocket 未安装或 URL 指令被拒绝时，普通网络不应被静默阻断。

## 完成证据

每轮至少保留：设备与系统信息、签名安装记录、WLOC/Shadowrocket 完整录屏、设置与恢复前后的定位截图、模块 query 回读、网络类型、失败项及复现步骤。只有全部必需项在真实 iPhone 上通过，才能声明方案 A 可用。

### 2026-07-19 真机自动化端到端结果

- 源码基线：Git commit `5358068`，并包含本次 `Info.plist` 定位用途说明修复；WLOC `1.0 (1)`，Sideloadly Personal Team 开发签名后的 Bundle ID 为 `com.weiweiliang.wloc.schemea.M3Y96YTM9S`。
- 安装包：`WLOC-SchemeA-location-fix-20260719.ipa`，SHA-256 `2CACAA03C0E653C05CD2852B78D0B9F70516FD7C1F2F049F34F429E725CF0983`。这是供本机重签名的无签名输入包；真机上安装的是 Sideloadly 重签名结果。
- 设备：`iPhone17,2`（设备名 `iPhone6537`），iOS `26.2.1`，USB 连接；测试网络为 Wi-Fi。Shadowrocket `2.2.65 (2615)`。
- 自动化：`pymobiledevice3 9.36.0` + WebDriverAgent Runner `15.1.6`，场景 `full-location-roundtrip` 于香港时间 `16:58:08–17:01:30` 完整退出码 0，并成功写出 `result.json`。
- 模块证据：真机检测显示“模块可用 · 真实定位透传”和“设置已完成”；该状态来自真实 `/wloc-settings/query` 响应，不是手动确认开关。
- 设置定位：地图目标 `46.912681, 103.183594`；自动化完成定位服务关闭/开启后，模块坐标一致，系统回读距离目标 `0 米`（阈值 `150 米`）。
- 恢复定位：模块持久化坐标已清除；再次完成定位服务关闭/开启后，新真实位置与原虚拟位置相距 `2,793,306 米`，最终界面恢复“模块可用 · 真实定位透传”。
- 最终状态：系统定位服务处于开启；恢复后的真实定位蓝点重新出现。恢复后仍能取得 Shadowrocket 模块响应，证明本轮模块/MITM 通路已重新工作；iOS 不允许 WLOC 读取另一个 App 的 VPN 开关，因此不把该响应伪称为直接 VPN 状态读取。
- 原始证据：`C:\Users\weg\AppData\Local\WlocAutomation\evidence\full-location-roundtrip-20260719-final`，包含 `result.json` 及 15 组关键阶段 PNG 截图与 XML 可访问性树。
- 地图补充验收：场景 `map-features` 退出码 0；真机完成坐标文本解析、收藏写入/回选/清理、MapKit 搜索“广州塔”并选中，以及“当前位置”回到 `23.175781, 113.417583`。证据位于 `C:\Users\weg\AppData\Local\WlocAutomation\evidence\map-features-20260719-d`，包含 `result.json` 及 7 组 PNG/XML。由于产品尚无独立“历史记录”界面，合并表述为“地图、搜索、当前位置、收藏与历史记录”的复选框仍保持未勾选。
- 配置取消验收：场景 `config-picker-cancel` 退出码 0；真实 iOS“文件”选择器成功打开并取消，返回 WLOC 后待分享配置状态未改变，也未误报读取失败或导入成功。证据位于 `C:\Users\weg\AppData\Local\WlocAutomation\evidence\config-picker-cancel-20260719-a`，包含 `result.json` 及 2 组 PNG/XML。真实配置选择、分享及 Shadowrocket 确认尚未执行，因此相关复选框保持未勾选。

当前结论：核心定位往返链路已在真实 iPhone 上自动化通过，包括模块检测、地图选点、虚拟定位核验、恢复真实定位以及两轮系统定位服务关/开。配置文件真实导入、蜂窝网络/常用 App 验证、失败场景和 20 次稳定性循环仍未执行，对应复选框保持未勾选，因此暂不声明“全部验收完成”。
