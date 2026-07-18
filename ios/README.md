# WLOC iOS

独立 iOS 客户端：MapKit 选点、配置导入、内置 Packet Tunnel、普通代理和本地 WLOC 修改。

当前目录采用 XcodeGen 描述工程，避免手工维护不可审查的 `project.pbxproj`。生成和签名必须在 macOS + Xcode 上完成。

## 目录

- `App/`：SwiftUI 主应用。
- `PacketTunnel/`：Network Extension。
- `Packages/WlocCore/`：可独立测试的坐标、配置和 protobuf 核心。
- `Vendor/`：Libbox 构建产物，不提交二进制。
- `scripts/`：macOS 构建和真机验收脚本。

## macOS 准备

```bash
cd ios
./scripts/bootstrap-macos.sh
open Wloc.xcodeproj
```

先安装 Go 与 XcodeGen。脚本会检出 `scripts/libbox-version.txt` 固定的 sing-box 标签，从源码构建 `Libbox.xcframework`，并生成 Xcode 工程。随后在 `project.yml` 或本地 Xcode 配置中填写开发团队、唯一 Bundle ID 与 App Group。

可用 `./scripts/test-macos.sh` 运行 Swift Package 测试、关闭签名的设备架构构建和 iOS Simulator 集成测试；`.github/workflows/ios-build.yml` 会在 macOS runner 上执行同一脚本。真机归档与验收仍须按 `docs/ios-acceptance.md` 完成，CI/模拟器结果不能替代真机证据。

## 重要状态

共享核心可在没有代理框架时单独测试；完整 App 工程需要先运行 bootstrap。Packet Tunnel 在缺少代理核心时会明确失败，不会伪装为可用 VPN。完整真机验收仍以 `docs/ios-acceptance.md` 为准。
