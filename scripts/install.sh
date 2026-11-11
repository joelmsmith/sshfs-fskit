#!/bin/sh
# Installs a built SSHFS.app to /Applications and registers it as the only
# copy. Always run the extension from this one path: when LaunchServices
# knows several copies it picks one arbitrarily, and switching the registered
# copy can turn the module off in System Settings (only the toggle there turns
# it back on).
#
#   scripts/install.sh path/to/SSHFS.app
#
# Running mounts keep using the old extension process: remount after installing.
set -e
SRC=$1
[ -d "$SRC" ] || { echo "usage: $0 path/to/SSHFS.app" >&2; exit 64; }
DEST=/Applications/SSHFS.app
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
cd "$(dirname "$0")/.."
for other in build/Build/Products/*/SSHFS.app; do
    [ -d "$other" ] && "$LSREG" -u "$other" 2>/dev/null || true
done
rm -rf "$DEST"
ditto "$SRC" "$DEST"
"$LSREG" -f -R -trusted "$DEST"
# Re-register the helper agent if it was registered (see ensureHelper in
# App/main.swift: a registration is tied to the kind of signature). This also
# replaces a running (old) helper; ssh processes it started keep running.
if "$DEST/Contents/MacOS/SSHFS" status 2>/dev/null | grep -q '^ssh helper: *enabled'; then
    "$DEST/Contents/MacOS/SSHFS" register ||
        echo "NOTE: the ssh helper doesn't start yet (usual right after switching between dev and release builds); the next sshfs mount re-registers it, or run: SSHFS register" >&2
fi
echo "installed $DEST"
if "$DEST/Contents/MacOS/SSHFS" list 2>/dev/null | grep -q '^disabled com.joelmsmith.sshfs'; then
    echo "NOTE: the module is disabled; enable SSHFS in System Settings > General > Login Items & Extensions > File System Extensions" >&2
fi
