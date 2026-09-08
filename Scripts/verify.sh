#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

FIRE_VERIFY_MODE="${1:-full}"
if [[ "$FIRE_VERIFY_MODE" != "full" && "$FIRE_VERIFY_MODE" != "--core-only" ]]; then
  echo "Usage: ./Scripts/verify.sh [--core-only]"
  exit 1
fi

if [[ "$FIRE_VERIFY_MODE" == "full" ]]; then
  ./Scripts/generate-project.sh
fi

FIRE_VERIFY_ROOT="${FIRE_VERIFY_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/fire-freedom-verify.XXXXXX")}"
FIRE_SWIFTPM_CACHE="${FIRE_VERIFY_ROOT}/swiftpm-cache"
FIRE_SWIFTPM_CONFIG="${FIRE_VERIFY_ROOT}/swiftpm-config"
FIRE_SWIFTPM_SECURITY="${FIRE_VERIFY_ROOT}/swiftpm-security"
FIRE_SWIFT_SCRATCH="${FIRE_VERIFY_ROOT}/swift-build"
FIRE_XCODE_PACKAGES="${FIRE_VERIFY_ROOT}/xcode-packages"

mkdir -p \
  "${FIRE_SWIFTPM_CACHE}" \
  "${FIRE_SWIFTPM_CONFIG}" \
  "${FIRE_SWIFTPM_SECURITY}" \
  "${FIRE_SWIFT_SCRATCH}" \
  "${FIRE_XCODE_PACKAGES}"

export CLANG_MODULE_CACHE_PATH="${FIRE_VERIFY_ROOT}/clang-module-cache"
export SWIFT_MODULECACHE_PATH="${FIRE_VERIFY_ROOT}/swift-module-cache"

if [[ -n "${FIRE_KAPI_FIXTURE:-}" ]]; then
  if [[ ! -f "${FIRE_KAPI_FIXTURE}" ]]; then
    echo "FIRE_KAPI_FIXTURE 指向的文件不存在：${FIRE_KAPI_FIXTURE}"
    exit 1
  fi
else
  echo "未设置 FIRE_KAPI_FIXTURE，已跳过真实账单集成测试。"
fi

/usr/bin/xcrun swift build \
  --disable-sandbox \
  --cache-path "${FIRE_SWIFTPM_CACHE}" \
  --config-path "${FIRE_SWIFTPM_CONFIG}" \
  --security-path "${FIRE_SWIFTPM_SECURITY}" \
  --scratch-path "${FIRE_SWIFT_SCRATCH}"
/usr/bin/xcrun swift test \
  --disable-sandbox \
  --cache-path "${FIRE_SWIFTPM_CACHE}" \
  --config-path "${FIRE_SWIFTPM_CONFIG}" \
  --security-path "${FIRE_SWIFTPM_SECURITY}" \
  --scratch-path "${FIRE_SWIFT_SCRATCH}"

if [[ "$FIRE_VERIFY_MODE" == "full" ]]; then
  /usr/bin/xcodebuild \
    -project FIREFreedom.xcodeproj \
    -scheme FIRE \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "${FIRE_VERIFY_ROOT}/derived-ios" \
    -clonedSourcePackagesDirPath "${FIRE_XCODE_PACKAGES}" \
    CODE_SIGNING_ALLOWED=NO \
    build

  FIRE_IOS_SIMULATOR_ID="$(
    { /usr/bin/xcrun simctl list devices available 2>/dev/null || true; } \
      | /usr/bin/awk '
          /iPhone/ && match($0, /\([0-9A-F-]+\)/) {
            print substr($0, RSTART + 1, RLENGTH - 2)
            exit
          }
        '
  )"
  if [[ -n "${FIRE_IOS_SIMULATOR_ID}" ]]; then
    /usr/bin/xcodebuild \
      -project FIREFreedom.xcodeproj \
      -scheme FIRE \
      -destination "platform=iOS Simulator,id=${FIRE_IOS_SIMULATOR_ID}" \
      -derivedDataPath "${FIRE_VERIFY_ROOT}/derived-ios-tests" \
      -clonedSourcePackagesDirPath "${FIRE_XCODE_PACKAGES}" \
      -only-testing:FIREiOSTests \
      CODE_SIGNING_ALLOWED=NO \
      test
  else
    echo "未检测到可用 iPhone Simulator。请在 Xcode 中安装 iOS Simulator 后重试，或使用 --core-only。"
    exit 1
  fi

  /usr/bin/xcodebuild \
    -project FIREFreedom.xcodeproj \
    -scheme FIREBridge \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "${FIRE_VERIFY_ROOT}/derived-macos" \
    -clonedSourcePackagesDirPath "${FIRE_XCODE_PACKAGES}" \
    CODE_SIGNING_ALLOWED=NO \
    build
else
  echo "按 --core-only 完成 Swift 包检查；未执行 iOS/macOS App 构建。"
fi
