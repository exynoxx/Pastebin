#!/bin/sh
# Compile the Nim backend inside the toolchain container (no local nim needed).
# Usage: ./build.sh            # native build to ./pastebin
set -e
cd "$(dirname "$0")"
docker run --rm \
  -v "$PWD":/app:z -w /app \
  -v pastebin-nimble:/root/.nimble \
  nimlang/nim:2.2.4-alpine \
  sh -c '
    apk add --no-cache sqlite-dev sqlite-static openssl-dev pcre >/dev/null 2>&1
    nim c -o:pastebin src/main.nim
  '
