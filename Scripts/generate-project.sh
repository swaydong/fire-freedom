#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "未检测到完整 Xcode。请先从 App Store 安装 Xcode，再运行："
  echo "  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer"
  exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "未检测到 XcodeGen。请先运行：brew install xcodegen"
  exit 1
fi

xcodegen generate --spec project.yml
echo "已生成 FIREFreedom.xcodeproj"
