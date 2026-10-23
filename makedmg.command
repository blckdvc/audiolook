#!/bin/bash
cd "$(dirname "$0")"
mkdir -p dist
APP="$HOME/Applications/audiolook.app"
[ -d "$APP" ] || { echo "audiolook.app introuvable dans ~/Applications (lance d'abord ./build.sh)"; exit 1; }
rm -rf dist/stage dist/audiolook.dmg dist/LoopLook.dmg
mkdir -p dist/stage
cp -R "$APP" dist/stage/
ln -s /Applications dist/stage/Applications
[ -f packaging/readme-first-launch.txt ] && cp packaging/readme-first-launch.txt "dist/stage/Read me - first launch.txt"
xattr -cr dist/stage/audiolook.app 2>/dev/null || true
hdiutil create -volname "audiolook" -srcfolder dist/stage -ov -format UDZO dist/audiolook.dmg
rm -rf dist/stage
echo "✓ dist/audiolook.dmg créé"
