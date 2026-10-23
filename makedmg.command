#!/bin/bash
cd "$(dirname "$0")"
mkdir -p dist
APP="$HOME/Applications/LoopLook.app"
[ -d "$APP" ] || { echo "LoopLook.app introuvable dans ~/Applications (lance d'abord ./build.sh)"; exit 1; }
rm -rf dist/stage dist/LoopLook.dmg
mkdir -p dist/stage
cp -R "$APP" dist/stage/
ln -s /Applications dist/stage/Applications
xattr -cr dist/stage/LoopLook.app 2>/dev/null || true
hdiutil create -volname "LoopLook" -srcfolder dist/stage -ov -format UDZO dist/LoopLook.dmg
rm -rf dist/stage
echo "✓ dist/LoopLook.dmg créé"
