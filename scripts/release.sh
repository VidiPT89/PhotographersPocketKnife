#!/usr/bin/env bash
# Compila, empacota, assina a atualização (Sparkle/EdDSA), atualiza o appcast e publica a release no GitHub.
# Uso: scripts/release.sh 0.2.0 "Notas da versão"
set -euo pipefail

VERSION="${1:?Uso: scripts/release.sh <versão> [notas]}"
NOTES="${2:-PhotographersPocketKnife $VERSION}"
cd "$(dirname "$0")/.."

if [[ -n "$(git status --porcelain)" ]]; then
    echo "Há alterações por commitar. Faz commit antes da release." >&2
    exit 1
fi

BUILD_NUMBER=$(( $(git rev-list --count HEAD) + 1 ))
sed -i '' -E "s/MARKETING_VERSION: \"[^\"]+\"/MARKETING_VERSION: \"$VERSION\"/" project.yml
sed -i '' -E "s/CURRENT_PROJECT_VERSION: \"[^\"]+\"/CURRENT_PROJECT_VERSION: \"$BUILD_NUMBER\"/" project.yml

xcodegen generate -q
xcodebuild test -scheme PhotographersPocketKnife -destination 'platform=macOS' -derivedDataPath build -quiet
xcodebuild build -scheme PhotographersPocketKnife -configuration Release -destination 'platform=macOS' -derivedDataPath build -quiet

APP="build/Build/Products/Release/PhotographersPocketKnife.app"
ZIP="build/PhotographersPocketKnife-$VERSION-macOS.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

SIGN_UPDATE=$(find build/SourcePackages/artifacts -name sign_update -type f | head -1)
SIGNATURE=$("$SIGN_UPDATE" "$ZIP")
DOWNLOAD_URL="https://github.com/VidiPT89/PhotographersPocketKnife/releases/download/v$VERSION/$(basename "$ZIP")"
PUB_DATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")

ITEM="    <item>
      <title>$VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url=\"$DOWNLOAD_URL\" $SIGNATURE type=\"application/octet-stream\"/>
    </item>"
ITEM="$ITEM" python3 - <<'PY'
import os
path = "appcast.xml"
content = open(path, encoding="utf-8").read()
marker = "<!-- ITEMS -->"
content = content.replace(marker, marker + "\n" + os.environ["ITEM"], 1)
open(path, "w", encoding="utf-8").write(content)
PY

git add project.yml appcast.xml
git commit -q -m "Release $VERSION"
git tag "v$VERSION"
git push -q origin main --tags
gh release create "v$VERSION" "$ZIP" --title "PhotographersPocketKnife $VERSION" --notes "$NOTES"
echo "Release $VERSION publicada."
