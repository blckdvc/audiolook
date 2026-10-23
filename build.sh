#!/bin/bash
# Compile audiolook (lecteur) sans Xcode, l'installe dans ~/Applications et le lance.
set -euo pipefail
cd "$(dirname "$0")"
# Utilise les Command Line Tools (pas de licence Xcode à accepter)
if [ -d /Library/Developer/CommandLineTools ]; then export DEVELOPER_DIR=/Library/Developer/CommandLineTools; fi

SDK=$(xcrun --sdk macosx --show-sdk-path)
ARCH=$(uname -m)
TARGET="$ARCH-apple-macos13.0"
OUT="${TMPDIR:-/tmp}/audiolook-build"
APP="$OUT/audiolook.app"
rm -rf "$OUT"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ clang++ (pont Signalsmith)"
clang++ -std=c++17 -O2 -fvisibility=hidden -isysroot "$SDK" -target "$TARGET" \
  -I Src -I Vendor/signalsmith-stretch -I Vendor/linear/include \
  -c Src/StretchBridge.cpp -o "$OUT/StretchBridge.o"

echo "→ swiftc $(swiftc --version 2>&1 | head -1)"
swiftc -O -sdk "$SDK" -target "$TARGET" -module-name audiolook \
  -framework Cocoa -framework AVFoundation -framework Carbon \
  -import-objc-header Src/Bridging.h -Xcc -I"$PWD/Src" \
  Src/*.swift "$OUT/StretchBridge.o" -lc++ \
  -o "$APP/Contents/MacOS/audiolook"

cat > "$APP/Contents/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>fr</string>
  <key>CFBundleDisplayName</key><string>audiolook</string>
  <key>CFBundleExecutable</key><string>audiolook</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>com.ludo.LoopLook</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>audiolook</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>audiolook lit la sélection courante du Finder pour ouvrir le fichier audio sélectionné.</string>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>Fichier audio</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array>
      <string>public.audio</string>
      <string>com.microsoft.waveform-audio</string>
      <string>public.aiff-audio</string>
      <string>public.aifc-audio</string>
      <string>public.mp3</string>
      <string>public.mpeg-4-audio</string>
      <string>com.apple.m4a-audio</string>
      <string>com.apple.coreaudio-format</string>
      <string>org.xiph.flac</string>
    </array>
  </dict></array>
</dict></plist>
PL

cat > "$OUT/app.entitlements" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.automation.apple-events</key><true/>
</dict></plist>
PL

echo "→ Icône (iconutil)"
if [ -d Resources/AppIcon.iconset ]; then
  iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns" && echo "icône OK" || echo "⚠︎ iconutil a échoué (app sans icône)"
fi

echo "→ Signature ad hoc…"
xattr -cr "$APP" || true
codesign --force --deep --sign - --entitlements "$OUT/app.entitlements" "$APP"
codesign --verify --deep --strict "$APP" && echo "signature OK"

DEST="$HOME/Applications/audiolook.app"
mkdir -p "$HOME/Applications"
# ferme les instances éventuelles (ancien nom LoopLook inclus) et retire l'ancien bundle renommé
pkill -f "Applications/audiolook.app/Contents/MacOS/audiolook" 2>/dev/null || true
pkill -f "Applications/LoopLook.app/Contents/MacOS/LoopLook" 2>/dev/null || true
rm -rf "$HOME/Applications/LoopLook.app"
# retire l'ancienne extension QuickLook abandonnée
pluginkit -e ignore -i com.ludo.LoopLook.Preview 2>/dev/null || true
sleep 1
rm -rf "$DEST"; cp -R "$APP" "$DEST"; xattr -cr "$DEST" || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" || true
echo "✓ Installé : $DEST"
open "$DEST"
echo "→ Lancé. Icône forme d'onde dans la barre de menus. Raccourci : ⌥Espace sur un fichier audio sélectionné dans le Finder."
