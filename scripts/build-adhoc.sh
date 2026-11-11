#!/bin/sh
# Builds SSHFS.app ad-hoc signed (no Apple Developer account needed) and
# installs it to /Applications. Ad-hoc builds can't carry the restricted
# FSKit entitlement, so the kernel won't let the extension invalidate its
# caches: remote changes can look stale until cache_timeout or a remount.
set -e
cd "$(dirname "$0")/.."
CONFIG=${CONFIG:-Debug}
xcodebuild -project SSHFS.xcodeproj -scheme SSHFS -configuration "$CONFIG" \
    -derivedDataPath build CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=NO build > build/xcodebuild.log 2>&1 \
    || { grep -E "error:" build/xcodebuild.log | sort -u >&2; echo "BUILD FAILED (see build/xcodebuild.log)" >&2; exit 1; }
echo "** BUILD SUCCEEDED **"
APP=$PWD/build/Build/Products/$CONFIG/SSHFS.app
EXT=$APP/Contents/Extensions/SSHFSExtension.appex
codesign --force --sign - --entitlements Config/Extension-adhoc.entitlements --options runtime "$EXT"
codesign --force --sign - --options runtime "$APP"
scripts/install.sh "$APP"
