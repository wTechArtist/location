#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
IOS_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
VERSION=$(tr -d '[:space:]' < "$SCRIPT_DIR/libbox-version.txt")
SOURCE_DIR="$IOS_DIR/.build/sing-box-$VERSION"
FRAMEWORK_SOURCE="$SOURCE_DIR/Libbox.xcframework"
FRAMEWORK_TARGET="$IOS_DIR/Vendor/Libbox.xcframework"
OVERLAY_SOURCE="$IOS_DIR/GoOverlay/wloc_proxy.go"
OVERLAY_TARGET="$SOURCE_DIR/experimental/libbox/wloc_proxy.go"
OVERLAY_TEST_SOURCE="$IOS_DIR/GoOverlay/wloc_proxy_test.go"
OVERLAY_TEST_TARGET="$SOURCE_DIR/experimental/libbox/wloc_proxy_test.go"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "error: Libbox 的 Apple XCFramework 必须在 macOS + Xcode 上构建。" >&2
  exit 1
fi

for tool in xcodebuild git go make xcodegen; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: 缺少 $tool。请先安装 Xcode、Go 与 XcodeGen。" >&2
    exit 1
  fi
done

mkdir -p "$IOS_DIR/.build" "$IOS_DIR/Vendor"
if [ ! -d "$SOURCE_DIR/.git" ]; then
  git clone --depth 1 --branch "$VERSION" https://github.com/SagerNet/sing-box.git "$SOURCE_DIR"
else
  CURRENT_VERSION=$(git -C "$SOURCE_DIR" describe --tags --exact-match 2>/dev/null || true)
  if [ "$CURRENT_VERSION" != "$VERSION" ]; then
    echo "error: $SOURCE_DIR 不是预期的 $VERSION；请移走该目录后重试。" >&2
    exit 1
  fi
  DIRTY=$(git -C "$SOURCE_DIR" status --porcelain | grep -v '^?? experimental/libbox/wloc_proxy.go$' | grep -v '^?? experimental/libbox/wloc_proxy_test.go$' || true)
  if [ -n "$DIRTY" ]; then
    echo "error: sing-box 构建目录含未提交改动，拒绝覆盖。" >&2
    exit 1
  fi
fi

cp "$OVERLAY_SOURCE" "$OVERLAY_TARGET"
cp "$OVERLAY_TEST_SOURCE" "$OVERLAY_TEST_TARGET"

echo "Building sing-box $VERSION Libbox.xcframework..."
(cd "$SOURCE_DIR" && go test ./experimental/libbox && make lib_apple)

if [ ! -d "$FRAMEWORK_SOURCE" ]; then
  echo "error: 构建完成但未找到 $FRAMEWORK_SOURCE" >&2
  exit 1
fi

rm -rf "$FRAMEWORK_TARGET"
cp -R "$FRAMEWORK_SOURCE" "$FRAMEWORK_TARGET"

(cd "$IOS_DIR" && xcodegen generate)
echo "Ready: $FRAMEWORK_TARGET"
echo "Generated: $IOS_DIR/Wloc.xcodeproj"
