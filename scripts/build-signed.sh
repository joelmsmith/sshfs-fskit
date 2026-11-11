#!/bin/sh
# Development build: signed with the paid team's Apple Development certificate,
# embedding the provisioning profile that grants com.apple.developer.fskit.fsmodule
# (valid only on Macs registered in that profile -- this VM). Installs to
# /Applications. For other Macs use build-release.sh.
#
#   SIGNING_DIR   holds the profile (default ~/sshfs-signing)
#   IDENTITY      codesign identity (default: a keychain identity whose
#                 certificate the profile allows -- signing with any other
#                 cert makes AMFI reject the restricted entitlement)
set -e
cd "$(dirname "$0")/.."
CONFIG=${CONFIG:-Debug}
SIGNING_DIR=${SIGNING_DIR:-$HOME/sshfs-signing}
PROFILE=${PROFILE:-$SIGNING_DIR/SSHFS_fsmodule_dev.provisionprofile}
[ -f "$PROFILE" ] || { echo "missing provisioning profile: $PROFILE" >&2; exit 1; }
if [ -z "$IDENTITY" ]; then
    ALLOWED=$(security cms -D -i "$PROFILE" | python3 -c '
import plistlib, hashlib, sys
for der in plistlib.loads(sys.stdin.buffer.read())["DeveloperCertificates"]:
    print(hashlib.sha1(der).hexdigest().upper())')
    for h in $(security find-identity -v -p codesigning | awk '{print $2}'); do
        if echo "$ALLOWED" | grep -qx "$h"; then IDENTITY=$h; break; fi
    done
    [ -n "$IDENTITY" ] || { echo "no keychain identity matches a certificate in $PROFILE" >&2; exit 1; }
fi
echo "signing as: $IDENTITY"

xcodebuild -project SSHFS.xcodeproj -scheme SSHFS -configuration "$CONFIG" \
    -derivedDataPath build CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=NO build > build/xcodebuild.log 2>&1 \
    || { grep -E "error:" build/xcodebuild.log | sort -u >&2; echo "BUILD FAILED (see build/xcodebuild.log)" >&2; exit 1; }
echo "** BUILD SUCCEEDED **"
APP=$PWD/build/Build/Products/$CONFIG/SSHFS.app
EXT=$APP/Contents/Extensions/SSHFSExtension.appex
cp "$PROFILE" "$EXT/Contents/embedded.provisionprofile"
codesign --force --sign "$IDENTITY" --entitlements Config/Extension.entitlements --options runtime --timestamp=none "$EXT"
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$APP"
codesign --verify --strict --verbose=1 "$APP"
scripts/install.sh "$APP"
