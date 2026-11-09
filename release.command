#!/bin/bash
# Publie une GitHub Release : DMG + empreinte SHA-256.
# C'est ce que lit la mise à jour automatique d'audiolook (releases/latest → audiolook.dmg).
# Prérequis : GitHub CLI (brew install gh, puis gh auth login).
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(grep -m1 'CFBundleShortVersionString' build.sh | sed -E 's/.*<string>([^<]+)<\/string>.*/\1/')
[ -n "$VERSION" ] || { echo "Version introuvable dans build.sh"; exit 1; }
command -v gh >/dev/null || { echo "GitHub CLI absent : brew install gh, puis gh auth login"; exit 1; }
if gh release view "$VERSION" >/dev/null 2>&1; then
  echo "La release $VERSION existe déjà — incrémente la version dans build.sh (CFBundleShortVersionString + CFBundleVersion)."
  exit 1
fi

echo "→ Build $VERSION"
./build.sh
echo "→ DMG"
./makedmg.command
shasum -a 256 audiolook.dmg | awk '{print $1"  audiolook.dmg"}' > audiolook.dmg.sha256
cat audiolook.dmg.sha256

# Notes = section « ## $VERSION » du CHANGELOG
NOTES=$(awk -v v="## $VERSION " 'index($0, v) == 1 {f=1; next} /^## / && f {exit} f' CHANGELOG.md)
[ -n "$NOTES" ] || NOTES="audiolook $VERSION"

echo "→ Release GitHub $VERSION"
gh release create "$VERSION" audiolook.dmg audiolook.dmg.sha256 \
  --title "AudioLook $VERSION" --notes "$NOTES"
echo "✓ Publiée. Pense à committer audiolook.dmg si tu le gardes aussi dans le repo."
