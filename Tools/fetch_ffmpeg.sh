#!/bin/bash
# FFmpeg for AirPlay of files the Apple TV can't open itself (MKV, AVI…): the phone repackages them.
# Prebuilt iOS frameworks from github.com/kingslay/FFmpegKit, pinned to one commit, put in Vendor/.
set -euo pipefail
REV=83bfdebc5fad3addacca476e8225162c443b8f0b
LIBS="Libavformat Libavcodec Libavutil Libswresample libzvbi"
cd "$(dirname "$0")/.."
mkdir -p Vendor
missing=0
for L in $LIBS; do [ -d "Vendor/$L.xcframework" ] || missing=1; done
[ $missing = 0 ] && { echo "FFmpeg frameworks already in Vendor/"; exit 0; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git -C "$tmp" init -q
git -C "$tmp" remote add origin https://github.com/kingslay/FFmpegKit.git
git -C "$tmp" sparse-checkout init --no-cone
for L in $LIBS; do echo "/Sources/$L.xcframework/"; done > "$tmp/.git/info/sparse-checkout"
git -C "$tmp" fetch -q --depth 1 --filter=blob:none origin "$REV"
git -C "$tmp" checkout -q FETCH_HEAD
for L in $LIBS; do
  rm -rf "Vendor/$L.xcframework"
  cp -R "$tmp/Sources/$L.xcframework" Vendor/
done
du -sh Vendor/*.xcframework
