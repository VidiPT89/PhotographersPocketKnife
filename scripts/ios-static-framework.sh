#!/bin/sh
# Prepare the pinned static curl dependency before running XcodeGen.
set -eu
cd "$(dirname "$0")/.."
if [ -f Vendor/curl.xcframework/Info.plist ]; then
    exit 0
fi
archive="$(mktemp -t ppk-curl)"
trap 'rm -f "$archive"' EXIT
curl --fail --location --proto '=https' --tlsv1.2 \
    https://github.com/greatfire/curl-apple/releases/download/8.18.0/curl.xcframework.zip -o "$archive"
expected=b9e75f69db8aac4d7c37c7e508f8b949a63c4e2a92a1a7e5125ba99ff6ddb007
actual="$(shasum -a 256 "$archive" | cut -d ' ' -f 1)"
if [ "$actual" != "$expected" ]; then
    echo 'curl archive checksum mismatch' >&2
    exit 1
fi
mkdir -p Vendor
unzip -q "$archive" -d Vendor
