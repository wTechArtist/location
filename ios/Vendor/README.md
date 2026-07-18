# Vendor

`Libbox.xcframework` 由固定版本的 sing-box 源码在 macOS 上构建，二进制不提交仓库。

上游：<https://github.com/SagerNet/sing-box>

目标版本记录在 `scripts/libbox-version.txt`。sing-box 使用 GPL-3.0-or-later，本项目分发时必须遵守其许可证，并保留完整对应源代码和构建说明。

构建脚本还会把 `GoOverlay/wloc_proxy.go` 加入固定版本源码。该覆盖层只增加设备本地、严格白名单限定于 `gs-loc.apple.com` 和 `gs-loc-cn.apple.com` 的 TLS 拦截端点；普通代理协议、DNS 和路由仍由上游 sing-box 实现。
