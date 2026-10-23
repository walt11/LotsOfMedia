#!/bin/sh
# Downloads VideoLAN's prebuilt VLCKit (LGPL-2.1) into Vendor/: MobileVLCKit for the iPhone app
# and TVVLCKit for the Apple TV app. Too large for git, so they aren't committed; run this once
# after cloning. Versions and checksums match the official CocoaPods specs (3.7.3).
set -eu
VERSION=3.7.3

cd "$(dirname "$0")/.."
mkdir -p Vendor

# fetch <framework name> <url> <sha256>
fetch() {
  NAME=$1; URL=$2; SHA256=$3
  DEST="Vendor/$NAME.xcframework"
  MARK="Vendor/.$NAME-version"
  if [ -f "$MARK" ] && [ "$(cat "$MARK")" = "$VERSION" ] && [ -d "$DEST" ]; then
    echo "$NAME $VERSION already in Vendor/"; return 0
  fi
  TMP=$(mktemp -d)
  echo "Downloading $NAME ${VERSION}…"
  curl -fL --retry 3 -o "$TMP/vlckit.tar.xz" "$URL"
  echo "$SHA256  $TMP/vlckit.tar.xz" | shasum -a 256 -c -
  mkdir -p "$TMP/x" && tar -xJf "$TMP/vlckit.tar.xz" -C "$TMP/x"
  SRC=$(find "$TMP/x" -maxdepth 3 -name "$NAME.xcframework" -type d | head -1)
  [ -n "$SRC" ] || { echo "$NAME.xcframework not found in archive" >&2; rm -rf "$TMP"; exit 1; }
  rm -rf "$DEST" && mv "$SRC" "$DEST"
  LICENSE=$(find "$TMP/x" -maxdepth 3 -name 'COPYING*' | head -1)
  [ -n "$LICENSE" ] && cp "$LICENSE" Vendor/VLCKit-COPYING.txt
  echo "$VERSION" > "$MARK"
  rm -rf "$TMP"
  echo "$NAME $VERSION installed in $DEST"
}

# Earlier versions of this script marked MobileVLCKit with Vendor/.vlckit-version.
[ -f Vendor/.vlckit-version ] && [ ! -f Vendor/.MobileVLCKit-version ] && cp Vendor/.vlckit-version Vendor/.MobileVLCKit-version

fetch MobileVLCKit \
  "https://download.videolan.org/pub/cocoapods/prod/MobileVLCKit-3.7.3-319ed2c0-79128878.tar.xz" \
  "0d04059906962ddc9a7bd1ebaa12e1f9ae85eb2466116a97a2f46886dd27a0a9"
fetch TVVLCKit \
  "https://download.videolan.org/cocoapods/prod/TVVLCKit-3.7.3-319ed2c0-79128878.tar.xz" \
  "b5f90c226ed54d9dc1c03901c60dc7749b74a53caace2c3047e4c0b7a063e46c"
