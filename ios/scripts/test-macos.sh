#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
IOS_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

if [ "$(uname -s)" != "Darwin" ]; then
  echo "error: iOS 构建测试需要 macOS + Xcode。" >&2
  exit 1
fi

for script in bootstrap-macos.sh archive-macos.sh test-macos.sh; do
  sh -n "$SCRIPT_DIR/$script"
done
echo "Verified: iOS shell scripts pass syntax checks."

XCODEBUILD_HELP=$(xcodebuild -help 2>&1)
for export_method in debugging release-testing; do
  if ! printf '%s\n' "$XCODEBUILD_HELP" | grep -F "$export_method" >/dev/null 2>&1; then
    echo "error: 当前 Xcode 未声明支持 $export_method 导出方式。" >&2
    exit 1
  fi
done
echo "Verified: Xcode supports debugging and release-testing IPA export methods."

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
