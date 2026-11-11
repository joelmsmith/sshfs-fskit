#!/bin/sh
# Runs the SFTP client tests directly against sftp-server, then over loopback ssh
# if the `sshfs-loopback` host alias works (see README / ~/.ssh/config).
set -e
cd "$(dirname "$0")/../Packages/SFTP"
echo "== sftp-server over pipes"
swift test
if ssh -o BatchMode=yes -o ConnectTimeout=3 sshfs-loopback true 2>/dev/null; then
    echo "== over ssh (sshfs-loopback)"
    SFTP_TEST_SSH_HOST=sshfs-loopback swift test
else
    echo "== skipping ssh run: 'ssh sshfs-loopback' does not work"
fi
