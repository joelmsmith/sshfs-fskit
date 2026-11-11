#!/bin/sh
# Builds a distributable SSHFS.app: Release config, signed with Developer ID,
# notarized by Apple and stapled, then zipped to build/SSHFS.zip. The result
# runs on any Mac with macOS 27+ (no device registration). Also installs it
# to /Applications on this Mac.
#
#   SIGNING_DIR  holds the Developer ID profile and asc.env (default ~/sshfs-signing)
#   NOTARIZE=0   skip notarization (checks signing only: an un-notarized
#                build can't start the ssh helper, so it can't mount)
#
# Needs in the keychain: the "Developer ID Application" identity of team
# 7J29265W8G. Needs in SIGNING_DIR: SSHFS_fsmodule_devid.provisionprofile and
# asc.env (App Store Connect API key, see scripts/asc.py) for notarytool.
set -e
cd "$(dirname "$0")/.."
SIGNING_DIR=${SIGNING_DIR:-$HOME/sshfs-signing}
PROFILE=${PROFILE:-$SIGNING_DIR/SSHFS_fsmodule_devid.provisionprofile}
[ -f "$PROFILE" ] || { echo "missing provisioning profile: $PROFILE" >&2; exit 1; }
IDENTITY=${IDENTITY:-$(security find-identity -v -p codesigning | awk '/Developer ID Application: .*\(7J29265W8G\)/ {print $2; exit}')}
[ -n "$IDENTITY" ] || { echo "no Developer ID Application identity in the keychain" >&2; exit 1; }
echo "signing as: $IDENTITY"

mkdir -p build
xcodebuild -project SSHFS.xcodeproj -scheme SSHFS -configuration Release \
    -derivedDataPath build CODE_SIGNING_ALLOWED=NO build > build/xcodebuild-release.log 2>&1 \
    || { grep -E "error:" build/xcodebuild-release.log | sort -u >&2; echo "BUILD FAILED (see build/xcodebuild-release.log)" >&2; exit 1; }
echo "** BUILD SUCCEEDED **"
APP=$PWD/build/Build/Products/Release/SSHFS.app
EXT=$APP/Contents/Extensions/SSHFSExtension.appex
cp "$PROFILE" "$EXT/Contents/embedded.provisionprofile"
codesign --force --sign "$IDENTITY" --entitlements Config/Extension.entitlements --options runtime --timestamp "$EXT"
codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"
codesign --verify --strict --deep --verbose=1 "$APP"

ZIP=$PWD/build/SSHFS.zip
rm -f "$ZIP"
if [ "${NOTARIZE:-1}" = 1 ]; then
    set -a; . "$SIGNING_DIR/asc.env"; set +a
    ditto -c -k --keepParent "$APP" "$ZIP"
    # On any failure here remove the zip: it is only the upload (not
    # stapled, and with extended attributes that break plain unzip).
    xcrun notarytool submit "$ZIP" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait \
        && xcrun stapler staple "$APP" || { rm -f "$ZIP"; echo "notarization failed (if only the status check timed out: xcrun notarytool history, then run this script again)" >&2; exit 1; }
    rm -f "$ZIP"
    spctl --assess --type execute --verbose=2 "$APP"
fi
# No extended attributes in the zip: ditto stores them as ._ files, which
# unzip(1) extracts as real files inside the bundle -- the signature breaks
# and macOS calls the app "damaged". Nothing in the signature needs them.
ditto -c -k --keepParent --norsrc --noextattr --noqtn "$APP" "$ZIP"
# Prove it survives plain unzip.
CHECK=$(mktemp -d)
unzip -q "$ZIP" -d "$CHECK"
codesign --verify --strict --deep "$CHECK/SSHFS.app" || { echo "the zip doesn't survive unzip" >&2; exit 1; }
[ "${NOTARIZE:-1}" != 1 ] || spctl --assess --type execute "$CHECK/SSHFS.app" || { echo "the unzipped app fails Gatekeeper" >&2; exit 1; }
rm -rf "$CHECK"
scripts/install.sh "$APP"
echo "$ZIP"
