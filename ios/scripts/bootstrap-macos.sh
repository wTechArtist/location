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
LIBBOX_BUILD_PATCH="$IOS_DIR/GoOverlay/disable_naive_outbound.patch"

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
  if git -C "$SOURCE_DIR" apply --reverse --check "$LIBBOX_BUILD_PATCH" >/dev/null 2>&1; then
    git -C "$SOURCE_DIR" apply --reverse "$LIBBOX_BUILD_PATCH"
  fi
  DIRTY=$(git -C "$SOURCE_DIR" status --porcelain | grep -v '^?? experimental/libbox/wloc_proxy.go$' | grep -v '^?? experimental/libbox/wloc_proxy_test.go$' || true)
  if [ -n "$DIRTY" ]; then
    echo "error: sing-box 构建目录含未提交改动，拒绝覆盖。" >&2
    exit 1
  fi
fi

cp "$OVERLAY_SOURCE" "$OVERLAY_TARGET"
cp "$OVERLAY_TEST_SOURCE" "$OVERLAY_TEST_TARGET"

restore_libbox_build_driver() {
  if git -C "$SOURCE_DIR" apply --reverse --check "$LIBBOX_BUILD_PATCH" >/dev/null 2>&1; then
    git -C "$SOURCE_DIR" apply --reverse "$LIBBOX_BUILD_PATCH"
  fi
}
trap restore_libbox_build_driver EXIT HUP INT TERM

# WLOC does not import Naive nodes. Leaving sing-box's Naive build tag enabled
# pulls cronet UIApplication background-task calls into the Packet Tunnel binary.
if ! git -C "$SOURCE_DIR" apply --check "$LIBBOX_BUILD_PATCH"; then
  echo "error: sing-box $VERSION 的 Libbox 构建入口与 WLOC 安全补丁不兼容。" >&2
  exit 1
fi
git -C "$SOURCE_DIR" apply "$LIBBOX_BUILD_PATCH"

echo "Building sing-box $VERSION Libbox.xcframework..."
(cd "$SOURCE_DIR" && make lib_install && go test ./experimental/libbox && make lib_apple)

if [ ! -d "$FRAMEWORK_SOURCE" ]; then
  echo "error: 构建完成但未找到 $FRAMEWORK_SOURCE" >&2
  exit 1
fi

audit_libbox_extension_safety() {
  found_binary=false
  while IFS= read -r binary; do
    if [ -z "$binary" ]; then
      continue
    fi
    found_binary=true
    symbol_output=$(mktemp -t wloc-libbox-symbols.XXXXXX)
    if ! xcrun nm -u "$binary" >"$symbol_output" 2>&1; then
      echo "error: 无法审计 Libbox 二进制符号：$binary" >&2
      cat "$symbol_output" >&2
      rm -f "$symbol_output"
      return 1
    fi
    if grep -E '(_OBJC_CLASS_\$_UIApplication|_UIBackgroundTaskInvalid)' "$symbol_output" >&2; then
      echo "error: Libbox 包含 Packet Tunnel 扩展不可用的 UIApplication 后台任务符号：$binary" >&2
      rm -f "$symbol_output"
      return 1
    fi
    rm -f "$symbol_output"
  done <<EOF
$(find "$FRAMEWORK_SOURCE" -type f -name Libbox -print)
EOF

  if [ "$found_binary" != true ]; then
    echo "error: 无法在 $FRAMEWORK_SOURCE 中找到 Libbox 二进制文件。" >&2
    return 1
  fi
}

audit_libbox_extension_safety
echo "Verified: Libbox has no UIApplication background-task dependency."

rm -rf "$FRAMEWORK_TARGET"
cp -R "$FRAMEWORK_SOURCE" "$FRAMEWORK_TARGET"

(cd "$IOS_DIR" && xcodegen generate)
echo "Ready: $FRAMEWORK_TARGET"
echo "Generated: $IOS_DIR/Wloc.xcodeproj"
