#!/bin/bash
# How far the build is, once a minute until it is stopped, read from ninja's
# log ("[done/total percent%]" before each step it finishes):
#   - in build/progress.txt, always;
#   - in the run's log;
#   - on GitHub, as a status next to the commit ("WebKit build"), when it
#     runs in Actions. The commits page of the linux branch shows it, the
#     run's page is a click away.
# The time left is a guess from the pace so far: compiling WebCore is slower
# than the steps before it, and linking at the end takes a while.
#
#   progress.sh <ninja log> <attempt>
#   progress.sh --final <success|failure|error> <description>
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
out=${BUILD_ROOT:-$here/../../build}/progress.txt

report() {
  local state=$1 description=$2
  printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$description" | tee -a "$out"
  [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${GITHUB_SHA:-}" ] || return 0
  local url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
  python3 -c 'import json,sys; print(json.dumps({"state": sys.argv[1], "description": sys.argv[2][:140], "context": "WebKit build", "target_url": sys.argv[3]}))' \
    "$state" "$description" "$url" |
    curl -sS -o /dev/null -X POST \
      -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" \
      "${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}/statuses/${GITHUB_SHA}" -d @- || true
}

clock() { printf '%d:%02d' $(($1 / 3600)) $(($1 % 3600 / 60)); }

if [ "${1:-}" = "--final" ]; then
  report "$2" "$3"
  exit 0
fi

log=$1 attempt=${2:-1}
mkdir -p "$(dirname "$out")"
started=$(date +%s)
report pending "Starting (try $attempt)"
while sleep 60; do
  last=$(tail -n 400 "$log" 2>/dev/null | grep -o '\[[0-9]*/[0-9]* *[0-9]*%\]' | tail -1)
  [ -n "$last" ] || { report pending "Configuring (try $attempt)"; continue; }
  read -r finished total percent < <(echo "$last" | tr -d '[]%' | tr '/' ' ')
  elapsed=$(($(date +%s) - started))
  left=""
  if [ "$finished" -gt 0 ]; then
    left=" · ~$(clock $((elapsed * (total - finished) / finished))) left"
  fi
  report pending "${percent}% · ${finished}/${total} steps · $(clock $elapsed) in${left} · try $attempt"
done
