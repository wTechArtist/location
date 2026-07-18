#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
IOS_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

if [ "$(uname -s)" != "Darwin" ]; then
  echo "error: iOS 构建测试需要 macOS + Xcode。" >&2
  exit 1
fi

if [ ! -d "$IOS_DIR/Vendor/Libbox.xcframework" ]; then
  "$SCRIPT_DIR/bootstrap-macos.sh"
fi

(cd "$IOS_DIR/Packages/WlocCore" && swift test)
(cd "$IOS_DIR" && xcodegen generate)

# Compile the arm64/device paths used by an archive before running simulator
# tests. Signing stays disabled because this check needs no developer account.
xcodebuild \
  -project "$IOS_DIR/Wloc.xcodeproj" \
  -scheme Wloc \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$IOS_DIR/DerivedData-Device" \
  CODE_SIGNING_ALLOWED=NO \
  build

SIMULATOR_UDID=$(
  xcrun simctl list devices available |
    sed -nE 's/^[[:space:]]+.*\(([0-9A-Fa-f-]{36})\) \((Shutdown|Booted)\)$/\1/p' |
    head -n 1
)
if [ -z "$SIMULATOR_UDID" ]; then
  echo "error: 没有可用的 iOS Simulator，无法执行集成测试。" >&2
  exit 1
fi

xcodebuild \
  -project "$IOS_DIR/Wloc.xcodeproj" \
  -scheme Wloc \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  -derivedDataPath "$IOS_DIR/DerivedData-Simulator" \
  CODE_SIGNING_ALLOWED=NO \
  test
