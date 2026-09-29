#!/bin/bash
# Official Sparkle binary distribution, pinned to a reviewed version and SHA-256.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=2.10.0
SHA=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
DIR=build/SparkleTools
ARCHIVE="$DIR/Sparkle-$VERSION.tar.xz"
mkdir -p "$DIR"
if [[ ! -f "$ARCHIVE" ]]; then
  curl --fail --location --retry 3 --connect-timeout 20 --max-time 300 \
    "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz" -o "$ARCHIVE.partial"
  mv "$ARCHIVE.partial" "$ARCHIVE"
fi
printf '%s  %s\n' "$SHA" "$ARCHIVE" | shasum -a 256 -c -
tar -xf "$ARCHIVE" -C "$DIR" Sparkle.framework bin LICENSE
echo "Prepared Sparkle $VERSION."
