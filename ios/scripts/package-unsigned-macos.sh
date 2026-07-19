#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
IOS_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

if [ "$(uname -s)" != "Darwin" ]; then
  echo "error: 无签名 iOS 包必须在 macOS + Xcode 上构建。" >&2
  exit 1
fi

for tool in ditto file plutil shasum xcodebuild xcodegen; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: 缺少 $tool。请先安装 Xcode 与 XcodeGen。" >&2
    exit 1
  fi
done

BASE_BUNDLE_IDENTIFIER=${WLOC_BASE_BUNDLE_IDENTIFIER:-com.example.wloc}
if ! printf '%s' "$BASE_BUNDLE_IDENTIFIER" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9.-]+$'; then
  echo "error: WLOC_BASE_BUNDLE_IDENTIFIER 不是有效的 Bundle ID。" >&2
  exit 1
fi

TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
IPA_PATH=${WLOC_UNSIGNED_IPA_PATH:-"$IOS_DIR/Artifacts/WLOC-SchemeA-unsigned-$TIMESTAMP.ipa"}
case "$IPA_PATH" in
  /*) ;;
  *) IPA_PATH="$PWD/$IPA_PATH" ;;
esac
if [ -e "$IPA_PATH" ]; then
  echo "error: 输出文件已存在，不会覆盖：$IPA_PATH" >&2
  exit 1
fi
mkdir -p "$(dirname "$IPA_PATH")"

BUILD_ROOT=$(mktemp -d -t wloc-unsigned-build.XXXXXX)
PACKAGE_ROOT=$(mktemp -d -t wloc-unsigned-package.XXXXXX)
VERIFY_ROOT=$(mktemp -d -t wloc-unsigned-verify.XXXXXX)
cleanup() {
  rm -rf "$BUILD_ROOT" "$PACKAGE_ROOT" "$VERIFY_ROOT"
}
trap cleanup EXIT HUP INT TERM

(cd "$IOS_DIR" && xcodegen generate)

xcodebuild \
  -project "$IOS_DIR/Wloc.xcodeproj" \
  -scheme Wloc \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$BUILD_ROOT" \
  BASE_BUNDLE_IDENTIFIER="$BASE_BUNDLE_IDENTIFIER" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

APP_PATH="$BUILD_ROOT/Build/Products/Release-iphoneos/WLOC.app"
if [ ! -d "$APP_PATH" ]; then
  echo "error: 构建完成但未找到 $APP_PATH" >&2
  exit 1
fi

audit_app() {
  candidate=$1
  if [ ! -f "$candidate/WLOC" ]; then
    echo "error: App 缺少 WLOC 可执行文件。" >&2
    exit 1
  fi
  if ! file "$candidate/WLOC" | grep -Eq 'Mach-O 64-bit executable arm64'; then
    echo "error: WLOC 可执行文件不是 arm64 真机构建。" >&2
    file "$candidate/WLOC" >&2
    exit 1
  fi
  if [ ! -f "$candidate/wloc.module" ]; then
    echo "error: App 缺少内置 wloc.module。" >&2
    exit 1
  fi
  if find "$candidate" -type d -name '*.appex' -print -quit | grep . >/dev/null 2>&1; then
    echo "error: 方案 A 的 App 意外包含 App Extension。" >&2
    exit 1
  fi
  if find "$candidate" -iname '*libbox*' -print -quit | grep . >/dev/null 2>&1; then
    echo "error: 方案 A 的 App 意外包含 Libbox。" >&2
    exit 1
  fi
  if [ -e "$candidate/_CodeSignature" ]; then
    echo "error: 预期无签名包，但 App 含有 _CodeSignature。" >&2
    exit 1
  fi
  actual_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate/Info.plist")
  if [ "$actual_bundle_id" != "$BASE_BUNDLE_IDENTIFIER" ]; then
    echo "error: Bundle ID 不一致：$actual_bundle_id" >&2
    exit 1
  fi
  if [ "$(/usr/libexec/PlistBuddy -c 'Print :LSApplicationQueriesSchemes:0' "$candidate/Info.plist")" != "shadowrocket" ]; then
    echo "error: Info.plist 未声明 shadowrocket 查询 scheme。" >&2
    exit 1
  fi
}

audit_app "$APP_PATH"
mkdir -p "$PACKAGE_ROOT/Payload"
ditto "$APP_PATH" "$PACKAGE_ROOT/Payload/WLOC.app"
(cd "$PACKAGE_ROOT" && ditto -c -k --sequesterRsrc --keepParent Payload "$IPA_PATH")

ditto -x -k "$IPA_PATH" "$VERIFY_ROOT"
EXTRACTED_APP="$VERIFY_ROOT/Payload/WLOC.app"
if [ ! -d "$EXTRACTED_APP" ]; then
  echo "error: IPA 不是标准的 Payload/WLOC.app 布局。" >&2
  exit 1
fi
audit_app "$EXTRACTED_APP"

IPA_SHA256=$(shasum -a 256 "$IPA_PATH" | awk '{print $1}')
trap - EXIT HUP INT TERM
cleanup

echo "Unsigned IPA ready: $IPA_PATH"
echo "SHA256: $IPA_SHA256"
echo "Verified: arm64、标准 Payload 布局、内置 wloc.module、无签名、无 App Extension、无 Libbox。"
echo "注意：该 IPA 仍须针对真实 iPhone 重签名后才能安装；它不是真机验收证据。"
