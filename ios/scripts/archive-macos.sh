#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
IOS_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

if [ "$(uname -s)" != "Darwin" ]; then
  echo "error: 签名归档必须在 macOS + Xcode 上执行。" >&2
  exit 1
fi

for tool in codesign xcodebuild xcodegen; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: 缺少 $tool。请先安装 Xcode 与 XcodeGen。" >&2
    exit 1
  fi
done

DEVELOPMENT_TEAM=${WLOC_DEVELOPMENT_TEAM:-}
BASE_BUNDLE_IDENTIFIER=${WLOC_BASE_BUNDLE_IDENTIFIER:-}
APP_GROUP_IDENTIFIER=${WLOC_APP_GROUP_IDENTIFIER:-}

if ! printf '%s' "$DEVELOPMENT_TEAM" | grep -Eq '^[A-Za-z0-9]{10}$'; then
  echo "error: 请通过 WLOC_DEVELOPMENT_TEAM 提供 10 位 Apple Developer Team ID。" >&2
  exit 1
fi
if ! printf '%s' "$BASE_BUNDLE_IDENTIFIER" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9.-]+$'; then
  echo "error: 请通过 WLOC_BASE_BUNDLE_IDENTIFIER 提供唯一 Bundle ID，例如 com.example.wloc。" >&2
  exit 1
fi
if ! printf '%s' "$APP_GROUP_IDENTIFIER" | grep -Eq '^group\.[A-Za-z0-9][A-Za-z0-9.-]+$'; then
  echo "error: 请通过 WLOC_APP_GROUP_IDENTIFIER 提供 App Group，例如 group.com.example.wloc。" >&2
  exit 1
fi

if [ ! -d "$IOS_DIR/Vendor/Libbox.xcframework" ]; then
  "$SCRIPT_DIR/bootstrap-macos.sh"
else
  (cd "$IOS_DIR" && xcodegen generate)
fi

ARCHIVE_PATH=${WLOC_ARCHIVE_PATH:-"$IOS_DIR/Archives/Wloc-$(date -u +%Y%m%dT%H%M%SZ).xcarchive"}
mkdir -p "$(dirname "$ARCHIVE_PATH")"

xcodebuild \
  -project "$IOS_DIR/Wloc.xcodeproj" \
  -scheme Wloc \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  BASE_BUNDLE_IDENTIFIER="$BASE_BUNDLE_IDENTIFIER" \
  APP_GROUP_IDENTIFIER="$APP_GROUP_IDENTIFIER" \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  archive

APP_PATH="$ARCHIVE_PATH/Products/Applications/WLOC.app"
if [ ! -d "$APP_PATH" ]; then
  echo "error: 归档完成但未找到 $APP_PATH" >&2
  exit 1
fi

EXTENSION_PATH="$APP_PATH/PlugIns/WlocPacketTunnel.appex"
if [ ! -d "$EXTENSION_PATH" ]; then
  echo "error: 归档未包含 Packet Tunnel Extension：$EXTENSION_PATH" >&2
  exit 1
fi

codesign --verify --strict --verbose=2 "$EXTENSION_PATH"
codesign --verify --strict --verbose=2 "$APP_PATH"

ENTITLEMENTS_FILE=$(mktemp -t wloc-entitlements.XXXXXX)
trap 'rm -f "$ENTITLEMENTS_FILE"' EXIT HUP INT TERM
codesign -d --entitlements :- "$EXTENSION_PATH" >"$ENTITLEMENTS_FILE" 2>/dev/null
NETWORK_EXTENSION_ENTITLEMENT=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.networking.networkextension:0' "$ENTITLEMENTS_FILE" 2>/dev/null || true)
EXTENSION_APP_GROUP=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$ENTITLEMENTS_FILE" 2>/dev/null || true)
if [ "$NETWORK_EXTENSION_ENTITLEMENT" != "packet-tunnel-provider" ]; then
  echo "error: Packet Tunnel 签名缺少 packet-tunnel-provider entitlement。" >&2
  exit 1
fi
if [ "$EXTENSION_APP_GROUP" != "$APP_GROUP_IDENTIFIER" ]; then
  echo "error: Packet Tunnel 签名中的 App Group 与 WLOC_APP_GROUP_IDENTIFIER 不一致。" >&2
  exit 1
fi

codesign -d --entitlements :- "$APP_PATH" >"$ENTITLEMENTS_FILE" 2>/dev/null
APP_APP_GROUP=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$ENTITLEMENTS_FILE" 2>/dev/null || true)
if [ "$APP_APP_GROUP" != "$APP_GROUP_IDENTIFIER" ]; then
  echo "error: 主 App 签名中的 App Group 与 WLOC_APP_GROUP_IDENTIFIER 不一致。" >&2
  exit 1
fi
rm -f "$ENTITLEMENTS_FILE"
trap - EXIT HUP INT TERM

echo "Archive ready: $ARCHIVE_PATH"
echo "Signed app: $APP_PATH"
echo "Verified: App/Extension 签名、Packet Tunnel entitlement 与 App Group 一致。"
echo "下一步请用 Xcode Devices and Simulators 安装到真实 iPhone，并按 docs/ios-acceptance.md 留存证据。"
