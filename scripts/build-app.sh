#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$PROJECT_DIR/dist"
APP_BUNDLE="$DIST_DIR/SafeGPU.app"
INSTALL_DIR="$HOME/Applications"
DO_INSTALL=0
SWIFT_EXTRA_FLAGS=()

for arg in "$@"; do
  case "$arg" in
    --install)
      DO_INSTALL=1
      ;;
    --install-dir=*)
      INSTALL_DIR="${arg#--install-dir=}"
      DO_INSTALL=1
      ;;
    --disable-sandbox)
      SWIFT_EXTRA_FLAGS+=(--disable-sandbox)
      ;;
  esac
done

echo "==> Building SafeGPU (release)..."
cd "$PROJECT_DIR"
swift build -c release ${SWIFT_EXTRA_FLAGS[@]+"${SWIFT_EXTRA_FLAGS[@]}"}

BIN_PATH="$PROJECT_DIR/.build/release/SafeGPU"
ICONGEN_PATH="$PROJECT_DIR/.build/release/SafeGPUIconGen"

if [ ! -x "$BIN_PATH" ]; then
  echo "Error: Release binary not found at $BIN_PATH" >&2
  exit 1
fi

echo "==> Assembling $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/SafeGPU"
chmod +x "$APP_BUNDLE/Contents/MacOS/SafeGPU"

echo "==> Generating SafeGPU AppIcon.icns..."
"$ICONGEN_PATH" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$APP_BUNDLE/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>SafeGPU</string>
    <key>CFBundleExecutable</key>
    <string>SafeGPU</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.safegpu.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>SafeGPU</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

echo "==> Ad-hoc code signing SafeGPU.app..."
codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true

echo "==> Built: $APP_BUNDLE"

if [ "$DO_INSTALL" -eq 1 ]; then
  echo "==> Installing to $INSTALL_DIR/SafeGPU.app..."
  mkdir -p "$INSTALL_DIR"
  rm -rf "$INSTALL_DIR/SafeGPU.app"
  cp -R "$APP_BUNDLE" "$INSTALL_DIR/SafeGPU.app"
  touch "$INSTALL_DIR/SafeGPU.app"
  LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -f "$INSTALL_DIR/SafeGPU.app" >/dev/null 2>&1 || true
  fi
  echo "==> Installed: $INSTALL_DIR/SafeGPU.app"
fi
