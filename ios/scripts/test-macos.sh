#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
IOS_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

if [ "$(uname -s)" != "Darwin" ]; then
  echo "error: iOS 构建测试需要 macOS + Xcode。" >&2
  exit 1
fi

for script in archive-macos.sh test-macos.sh; do
  sh -n "$SCRIPT_DIR/$script"
done
echo "Verified: iOS shell scripts pass syntax checks."

(cd "$IOS_DIR/Packages/WlocCore" && swift test)
(cd "$IOS_DIR" && xcodegen generate)

xcodebuild \
  -project "$IOS_DIR/Wloc.xcodeproj" \
  -scheme Wloc \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$IOS_DIR/DerivedData-Device" \
  CODE_SIGNING_ALLOWED=NO \
  build

DEVICE_APP="$IOS_DIR/DerivedData-Device/Build/Products/Debug-iphoneos/WLOC.app"
if [ ! -f "$DEVICE_APP/wloc.module" ]; then
  echo "error: 真机架构产物缺少内置 wloc.module。" >&2
  exit 1
fi
if find "$DEVICE_APP" -type d -name '*.appex' -print -quit | grep . >/dev/null 2>&1; then
  echo "error: 方案 A 的真机架构产物意外包含 App Extension。" >&2
  exit 1
fi
if find "$DEVICE_APP" -iname '*libbox*' -print -quit | grep . >/dev/null 2>&1; then
  echo "error: 方案 A 的真机架构产物意外包含 Libbox。" >&2
  exit 1
fi
echo "Verified: device app embeds wloc.module and contains no App Extension or Libbox."

SIMULATOR_LIST=$(xcrun simctl list devices available)
printf '%s\n' "$SIMULATOR_LIST"
SIMULATOR_UDID=$(
  printf '%s\n' "$SIMULATOR_LIST" |
    awk '
      /^-- iOS / { in_ios = 1; next }
      /^-- / { in_ios = 0; next }
      in_ios && /^[[:space:]]+iPhone/ && /\((Shutdown|Booted)\)/ {
        if (match($0, /\([0-9A-Fa-f-]+\)/)) {
          udid = substr($0, RSTART + 1, RLENGTH - 2)
          if (length(udid) == 36) {
            print udid
            exit
          }
        }
      }
    '
)
if [ -z "$SIMULATOR_UDID" ]; then
  echo "error: 没有识别到可用的 iPhone Simulator，无法执行集成测试。" >&2
  exit 1
fi

echo "Using iPhone Simulator: $SIMULATOR_UDID"

xcodebuild \
  -project "$IOS_DIR/Wloc.xcodeproj" \
  -scheme Wloc \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  -derivedDataPath "$IOS_DIR/DerivedData-Simulator" \
  CODE_SIGNING_ALLOWED=NO \
  test
