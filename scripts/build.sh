#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="$(uname -m)"
case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;; esac
BUILD="$ROOT/build"
APP="$BUILD/小账本.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD/module-cache"
xcrun swiftc -swift-version 5 -O -module-cache-path "$BUILD/module-cache"   -target "$ARCH-apple-macosx13.0"   "$ROOT/outputs/小账本源码/main.swift"   "$ROOT/outputs/小账本源码/统计.swift"   "$ROOT/outputs/小账本源码/账本.swift"   -o "$APP/Contents/MacOS/LittleLedger"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf 'Built: %s\n' "$APP"
