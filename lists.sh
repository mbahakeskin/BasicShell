#!/bin/bash
# Fetches the filter lists the ad blocker is built from into Lists/. The app
# itself never downloads anything; run this, then ./build.sh, to update.
#
# EasyList and EasyPrivacy are by The EasyList authors (https://easylist.to),
# dual licensed GPLv3 / CC BY-SA 3.0. They are not kept in the repository.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p Lists
for name in easylist easyprivacy; do
  curl -sSfL --max-time 60 -o "Lists/$name.txt.part" "https://easylist.to/easylist/$name.txt"
  mv "Lists/$name.txt.part" "Lists/$name.txt"
  echo "Lists/$name.txt: $(grep -m1 '^! Version' "Lists/$name.txt" | cut -d' ' -f3)"
done
