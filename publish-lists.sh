#!/bin/bash
# Builds the ad blocker's lists from the latest EasyList and EasyPrivacy, signs
# them, and uploads them to the "blocklists" release of this repository on
# GitHub, where the app fetches them the first time it runs (Shield.swift).
#
# Needs the GitHub CLI signed in (gh auth login) and the signing key at
# ~/.config/basicshell/blocklists.key; the first run makes one and prints its
# public half, which goes into Shield.publicKey.
set -euo pipefail
cd "$(dirname "$0")"
KEY="${BASICSHELL_LISTS_KEY:-$HOME/.config/basicshell/blocklists.key}"
TAG="blocklists"
OUT=".build/blocklists"

mkdir -p .build/tools
for tool in BlockLists SignLists; do
  if [ ! -x ".build/tools/$tool" ] || [ "Tools/$tool.swift" -nt ".build/tools/$tool" ]; then
    swiftc -O "Tools/$tool.swift" -o ".build/tools/$tool"
  fi
done

if [ ! -f "$KEY" ]; then
  echo "New signing key at $KEY. Put this public key in Shield.publicKey:"
  .build/tools/SignLists keygen "$KEY"
fi

./lists.sh
rm -rf "$OUT" && mkdir -p "$OUT"
.build/tools/BlockLists Lists/easylist.txt "$OUT/ads.json.lzfse"
.build/tools/BlockLists Lists/easyprivacy.txt "$OUT/privacy.json.lzfse"
VERSION="$(date -u +%Y%m%d%H%M)"
.build/tools/SignLists manifest "$OUT" "$VERSION" "$KEY"

if ! gh release view "$TAG" > /dev/null 2>&1; then
  gh release create "$TAG" --title "Block lists" --latest=false \
    --notes "EasyList and EasyPrivacy (https://easylist.to, GPLv3 / CC BY-SA 3.0), converted to WebKit content rule lists and signed. BasicShell downloads these; they are not meant to be downloaded by hand."
fi
gh release upload "$TAG" "$OUT"/*.json.lzfse "$OUT/lists.json" "$OUT/lists.json.sig" --clobber
echo "Published block lists $VERSION"
