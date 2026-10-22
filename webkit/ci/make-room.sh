#!/bin/bash
# A GitHub runner comes with toolchains BasicShell doesn't use; WebKit's build
# needs the disk they take.
set -uo pipefail
df -h / | tail -1
sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc /usr/local/.ghcup \
  /opt/hostedtoolcache/CodeQL /usr/local/share/powershell /usr/share/swift
sudo docker image prune --all --force > /dev/null 2>&1 || true
df -h / | tail -1
