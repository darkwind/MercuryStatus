#!/bin/zsh
# MercuryStatus.app 빌드 (Xcode 프로젝트 없이 swiftc만 사용)
set -euo pipefail
cd "${0:A:h}"

APP=build/MercuryStatus.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -parse-as-library -target arm64-apple-macos14.0 \
  -framework IOKit -framework SwiftUI -framework AppKit \
  Sources/*.swift -o "$APP/Contents/MacOS/MercuryStatus"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.duegosystem.MercuryStatus</string>
  <key>CFBundleName</key><string>MercuryStatus</string>
  <key>CFBundleDisplayName</key><string>MercuryStatus</string>
  <key>CFBundleExecutable</key><string>MercuryStatus</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>© Duegosystem</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "built: $PWD/$APP"

# ./build.sh install → /Applications에 설치하고 재실행 (재빌드 시 입력 모니터링 권한을 다시 허용해야 함)
if [[ "${1:-}" == "install" ]]; then
  pkill -x MercuryStatus || true
  rm -rf /Applications/MercuryStatus.app
  ditto "$APP" /Applications/MercuryStatus.app
  open /Applications/MercuryStatus.app
  echo "installed: /Applications/MercuryStatus.app"
fi
