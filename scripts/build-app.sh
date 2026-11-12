#!/bin/bash
# Build Tabula.app (release), embed native client libraries, sign ad-hoc, and optionally install.
#   scripts/build-app.sh            → build/Tabula.app
#   scripts/build-app.sh --install  → also copy to /Applications
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(git describe --tags --always 2>/dev/null || echo dev)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

echo "▸ Compiling (release)…"
swift build -c release --arch arm64 2>&1 | grep -E "error|warning: unre|Compiling Tabula|Build complete" || true
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Tabula"
[ -x "$BIN" ] || { echo "build failed"; exit 1; }

APP="build/Tabula.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Tabula"
[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift Resources/AppIcon.icns
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# MariaDB auth plugins (caching_sha2_password etc. are loaded at runtime)
PLUGIN_SRC="/opt/homebrew/opt/mariadb-connector-c/lib/mariadb/plugin"
mkdir -p "$APP/Contents/Resources/mariadb-plugins"
PLUGINS=()
for p in caching_sha2_password sha256_password client_ed25519 dialog mysql_clear_password parsec; do
  if [ -f "$PLUGIN_SRC/$p.so" ]; then
    cp "$PLUGIN_SRC/$p.so" "$APP/Contents/Resources/mariadb-plugins/"
    chmod 755 "$APP/Contents/Resources/mariadb-plugins/$p.so"
    PLUGINS+=("$APP/Contents/Resources/mariadb-plugins/$p.so")
  fi
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Tabula</string>
  <key>CFBundleDisplayName</key><string>Tabula</string>
  <key>CFBundleIdentifier</key><string>app.tabula.Tabula</string>
  <key>CFBundleExecutable</key><string>Tabula</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>CFBundleGetInfoString</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key><true/>
    <key>NSAllowsArbitraryLoads</key><true/>
  </dict>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>SQLite Database</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeExtensions</key>
      <array><string>sqlite</string><string>sqlite3</string><string>db</string><string>db3</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

echo "▸ Embedding native libraries…"
python3 scripts/bundle-dylibs.py "$APP" "${PLUGINS[@]}" 2>&1 | grep -v "invalidate the code signature"

echo "▸ Signing (ad-hoc)…"
for f in "$APP"/Contents/Frameworks/*.dylib "$APP"/Contents/Resources/mariadb-plugins/*.so; do
  codesign --force --sign - --timestamp=none "$f" >/dev/null 2>&1
done
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP" && echo "  signature ok"

# Sanity: nothing should still point at Homebrew
if otool -L "$APP"/Contents/MacOS/Tabula "$APP"/Contents/Frameworks/*.dylib "$APP"/Contents/Resources/mariadb-plugins/*.so | grep -q "/opt/homebrew"; then
  echo "  ! warning: Homebrew paths remain"; otool -L "$APP"/Contents/MacOS/Tabula "$APP"/Contents/Frameworks/*.dylib | grep /opt/homebrew
fi
echo "✓ Built $APP ($(du -sh "$APP" | cut -f1))"

if [[ "${1:-}" == "--install" ]]; then
  osascript -e 'quit app "Tabula"' >/dev/null 2>&1 || true
  sleep 1
  rm -rf /Applications/Tabula.app
  cp -R "$APP" /Applications/Tabula.app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Tabula.app >/dev/null 2>&1 || true
  echo "✓ Installed to /Applications/Tabula.app"
fi
