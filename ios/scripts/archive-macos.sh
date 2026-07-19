#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
IOS_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

if [ "$(uname -s)" != "Darwin" ]; then
  echo "error: 签名归档必须在 macOS + Xcode 上执行。" >&2
  exit 1
fi

for tool in codesign ditto plutil xcodebuild xcodegen; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: 缺少 $tool。请先安装 Xcode 与 XcodeGen。" >&2
    exit 1
  fi
done

DEVELOPMENT_TEAM=${WLOC_DEVELOPMENT_TEAM:-}
BASE_BUNDLE_IDENTIFIER=${WLOC_BASE_BUNDLE_IDENTIFIER:-}
APP_GROUP_IDENTIFIER=${WLOC_APP_GROUP_IDENTIFIER:-}
EXPORT_METHOD=${WLOC_EXPORT_METHOD:-development}

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
case "$EXPORT_METHOD" in
  development|ad-hoc) ;;
  *)
    echo "error: WLOC_EXPORT_METHOD 仅支持 development 或 ad-hoc。" >&2
    exit 1
    ;;
esac

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

EXPORT_PATH=${WLOC_EXPORT_PATH:-"${ARCHIVE_PATH%.xcarchive}-Export"}
if [ -e "$EXPORT_PATH" ]; then
  echo "error: 导出目录已存在，请移走后重试或通过 WLOC_EXPORT_PATH 指定新目录：$EXPORT_PATH" >&2
  exit 1
fi

EXPORT_OPTIONS_FILE=$(mktemp -t wloc-export-options.XXXXXX)
VERIFY_DIRECTORY=$(mktemp -d -t wloc-ipa-verify.XXXXXX)
trap 'rm -f "$EXPORT_OPTIONS_FILE"; rm -rf "$VERIFY_DIRECTORY"' EXIT HUP INT TERM
plutil -create xml1 "$EXPORT_OPTIONS_FILE"
plutil -insert method -string "$EXPORT_METHOD" "$EXPORT_OPTIONS_FILE"
plutil -insert destination -string export "$EXPORT_OPTIONS_FILE"
plutil -insert signingStyle -string automatic "$EXPORT_OPTIONS_FILE"
plutil -insert teamID -string "$DEVELOPMENT_TEAM" "$EXPORT_OPTIONS_FILE"
plutil -insert manageAppVersionAndBuildNumber -bool NO "$EXPORT_OPTIONS_FILE"
plutil -insert stripSwiftSymbols -bool YES "$EXPORT_OPTIONS_FILE"

xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS_FILE" \
  -allowProvisioningUpdates

IPA_PATH=
for candidate in "$EXPORT_PATH"/*.ipa; do
  if [ -f "$candidate" ]; then
    IPA_PATH=$candidate
    break
  fi
done
if [ -z "$IPA_PATH" ]; then
  echo "error: 导出完成但未找到 .ipa：$EXPORT_PATH" >&2
  exit 1
fi

ditto -x -k "$IPA_PATH" "$VERIFY_DIRECTORY"
EXPORTED_APP_PATH="$VERIFY_DIRECTORY/Payload/WLOC.app"
EXPORTED_EXTENSION_PATH="$EXPORTED_APP_PATH/PlugIns/WlocPacketTunnel.appex"
if [ ! -d "$EXPORTED_APP_PATH" ] || [ ! -d "$EXPORTED_EXTENSION_PATH" ]; then
  echo "error: IPA 缺少主 App 或 Packet Tunnel Extension：$IPA_PATH" >&2
  exit 1
fi
codesign --verify --strict --verbose=2 "$EXPORTED_EXTENSION_PATH"
codesign --verify --strict --verbose=2 "$EXPORTED_APP_PATH"

EXPORTED_ENTITLEMENTS_FILE="$VERIFY_DIRECTORY/entitlements.plist"
codesign -d --entitlements :- "$EXPORTED_EXTENSION_PATH" >"$EXPORTED_ENTITLEMENTS_FILE" 2>/dev/null
EXPORTED_NETWORK_EXTENSION_ENTITLEMENT=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.networking.networkextension:0' "$EXPORTED_ENTITLEMENTS_FILE" 2>/dev/null || true)
EXPORTED_EXTENSION_APP_GROUP=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$EXPORTED_ENTITLEMENTS_FILE" 2>/dev/null || true)
if [ "$EXPORTED_NETWORK_EXTENSION_ENTITLEMENT" != "packet-tunnel-provider" ]; then
  echo "error: IPA 内 Packet Tunnel 签名缺少 packet-tunnel-provider entitlement。" >&2
  exit 1
fi
if [ "$EXPORTED_EXTENSION_APP_GROUP" != "$APP_GROUP_IDENTIFIER" ]; then
  echo "error: IPA 内 Packet Tunnel 的 App Group 与 WLOC_APP_GROUP_IDENTIFIER 不一致。" >&2
  exit 1
fi

codesign -d --entitlements :- "$EXPORTED_APP_PATH" >"$EXPORTED_ENTITLEMENTS_FILE" 2>/dev/null
EXPORTED_APP_GROUP=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$EXPORTED_ENTITLEMENTS_FILE" 2>/dev/null || true)
if [ "$EXPORTED_APP_GROUP" != "$APP_GROUP_IDENTIFIER" ]; then
  echo "error: IPA 内主 App 的 App Group 与 WLOC_APP_GROUP_IDENTIFIER 不一致。" >&2
  exit 1
fi

rm -f "$EXPORT_OPTIONS_FILE"
rm -rf "$VERIFY_DIRECTORY"
trap - EXIT HUP INT TERM

echo "Archive ready: $ARCHIVE_PATH"
echo "IPA ready: $IPA_PATH"
echo "Signed app: $APP_PATH"
echo "Verified: Archive/IPA 均含已签名 App 与 Packet Tunnel；entitlement 与 App Group 一致。"
echo "下一步请用 Xcode Devices and Simulators 或 Apple Configurator 安装 IPA 到已注册的真实 iPhone，并按 docs/ios-acceptance.md 留存证据。"
