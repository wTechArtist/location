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
xcodebuild \
  -project "$IOS_DIR/Wloc.xcodeproj" \
  -scheme Wloc \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$IOS_DIR/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  test
