#!/bin/bash
cd "$(dirname "$0")"
APP="$HOME/Applications/audiolook.app"
[ -d "$APP" ] || { echo "audiolook.app introuvable dans ~/Applications (lance d'abord ./build.sh)"; exit 1; }
STAGE=".dmgstage"
rm -rf "$STAGE" audiolook.dmg LoopLook.dmg
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE"/
ln -s /Applications "$STAGE"/Applications
[ -f packaging/readme-first-launch.txt ] && cp packaging/readme-first-launch.txt "$STAGE/Read me - first launch.txt"
xattr -cr "$STAGE/audiolook.app" 2>/dev/null || true
hdiutil create -volname "audiolook" -srcfolder "$STAGE" -ov -format UDZO audiolook.dmg
rm -rf "$STAGE"
echo "✓ audiolook.dmg créé (racine du repo)"
