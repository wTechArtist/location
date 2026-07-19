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
EXPORT_METHOD=${WLOC_EXPORT_METHOD:-debugging}

if ! printf '%s' "$DEVELOPMENT_TEAM" | grep -Eq '^[A-Za-z0-9]{10}$'; then
  echo "error: 请通过 WLOC_DEVELOPMENT_TEAM 提供 10 位 Apple Developer Team ID。" >&2
  exit 1
fi
if ! printf '%s' "$BASE_BUNDLE_IDENTIFIER" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9.-]+$'; then
  echo "error: 请通过 WLOC_BASE_BUNDLE_IDENTIFIER 提供唯一 Bundle ID，例如 com.example.wloc。" >&2
  exit 1
fi
case "$EXPORT_METHOD" in
  development) EXPORT_METHOD=debugging ;;
  ad-hoc) EXPORT_METHOD=release-testing ;;
  app-store) EXPORT_METHOD=app-store-connect ;;
  debugging|release-testing|app-store-connect) ;;
  *)
    echo "error: WLOC_EXPORT_METHOD 仅支持 debugging、release-testing 或 app-store-connect。" >&2
    exit 1
    ;;
esac

(cd "$IOS_DIR" && xcodegen generate)

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
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  archive

APP_PATH="$ARCHIVE_PATH/Products/Applications/WLOC.app"
if [ ! -d "$APP_PATH" ]; then
  echo "error: 归档完成但未找到 $APP_PATH" >&2
  exit 1
fi
if find "$APP_PATH" -type d -name '*.appex' -print -quit | grep . >/dev/null 2>&1; then
  echo "error: 方案 A 的 App 不应包含任何 Network Extension。" >&2
  exit 1
fi
if find "$APP_PATH" -iname '*libbox*' -print -quit | grep . >/dev/null 2>&1; then
  echo "error: 方案 A 的 App 不应包含 Libbox。" >&2
  exit 1
fi
codesign --verify --strict --verbose=2 "$APP_PATH"

ENTITLEMENTS_FILE=$(mktemp -t wloc-entitlements.XXXXXX)
trap 'rm -f "$ENTITLEMENTS_FILE"' EXIT HUP INT TERM
codesign -d --entitlements :- "$APP_PATH" >"$ENTITLEMENTS_FILE" 2>/dev/null
if /usr/libexec/PlistBuddy -c 'Print :com.apple.developer.networking.networkextension' "$ENTITLEMENTS_FILE" >/dev/null 2>&1; then
  echo "error: 方案 A 签名意外包含 Network Extension entitlement。" >&2
  exit 1
fi
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups' "$ENTITLEMENTS_FILE" >/dev/null 2>&1; then
  echo "error: 方案 A 签名意外包含 App Group entitlement。" >&2
  exit 1
fi
rm -f "$ENTITLEMENTS_FILE"
trap - EXIT HUP INT TERM

EXPORT_PATH=${WLOC_EXPORT_PATH:-"${ARCHIVE_PATH%.xcarchive}-Export"}
if [ -e "$EXPORT_PATH" ]; then
  echo "error: 导出目录已存在：$EXPORT_PATH" >&2
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
if [ ! -d "$EXPORTED_APP_PATH" ]; then
  echo "error: IPA 缺少 WLOC.app：$IPA_PATH" >&2
  exit 1
fi
if find "$EXPORTED_APP_PATH" -type d -name '*.appex' -print -quit | grep . >/dev/null 2>&1; then
  echo "error: IPA 意外包含 App Extension。" >&2
  exit 1
fi
codesign --verify --strict --verbose=2 "$EXPORTED_APP_PATH"

rm -f "$EXPORT_OPTIONS_FILE"
rm -rf "$VERIFY_DIRECTORY"
trap - EXIT HUP INT TERM

echo "Archive ready: $ARCHIVE_PATH"
echo "IPA ready: $IPA_PATH"
echo "Verified: 方案 A 仅含主 App，不含 Network Extension、App Group 或 Libbox。"
echo "注意：Personal Team 的设备注册、安装与有效期限制仍由 Apple 控制；生成 IPA 不等于已完成真实 iPhone 验收。"
