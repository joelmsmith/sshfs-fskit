#!/bin/zsh
# End-to-end tests: mounts a local directory over loopback ssh with the
# installed extension (/Applications/SSHFS.app, see scripts/install.sh) and
# exercises the file system.
#
#   scripts/e2e.sh            # uses Host sshfs-loopback (see docs/DEVELOPMENT.md)
#
# Build first with scripts/build-signed.sh or build-release.sh (cache-coherency
# tests need a team-signed build; they're skipped on ad-hoc builds).
set -u
HOST=${E2E_HOST:-sshfs-loopback}
APP=${APP:-/Applications/SSHFS.app}
SSHFS="$APP/Contents/MacOS/SSHFS sshfs"
WORK=$(mktemp -d /private/tmp/sshfs-e2e.XXXXXX)
REMOTE=$WORK/remote          # "server side" (same machine)
MNT=$WORK/mnt
mkdir -p $REMOTE $MNT
pass=0 fail=0 skip=0
ok()   { print -P "%F{green}PASS%f $1"; ((pass++)) }
bad()  { print -P "%F{red}FAIL%f $1${2:+ — $2}"; ((fail++)) }
skp()  { print -P "%F{yellow}SKIP%f $1${2:+ — $2}"; ((skip++)) }
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi }
cleanup() { umount $MNT 2>/dev/null || umount -f $MNT 2>/dev/null; rm -rf $WORK; }
trap cleanup EXIT

ssh -o BatchMode=yes -o ConnectTimeout=5 $HOST true || { echo "ssh $HOST doesn't work; see docs/DEVELOPMENT.md"; exit 2; }
entitled=$(codesign -d --entitlements - "$APP/Contents/Extensions/SSHFSExtension.appex" 2>/dev/null | grep -c fskit.fsmodule)

echo "== mount"
mkdir -p $REMOTE/sub && echo hello > $REMOTE/sub/hello.txt
check "sshfs mounts" ${=SSHFS} "$HOST:$REMOTE" $MNT -o dir_poll=1
check "mount shows up" sh -c "mount | grep -q ' on $MNT (sshfs'"
check "read file" sh -c "[ \"\$(cat $MNT/sub/hello.txt)\" = hello ]"

echo "== metadata operations"
check "create + write"   sh -c "echo new > $MNT/new.txt && [ \"\$(cat $REMOTE/new.txt)\" = new ]"
check "append"           sh -c "echo more >> $MNT/new.txt && [ \"\$(wc -l < $REMOTE/new.txt | tr -d ' ')\" = 2 ]"
check "mkdir"            sh -c "mkdir $MNT/d && [ -d $REMOTE/d ]"
check "rename"           sh -c "mv $MNT/new.txt $MNT/d/moved.txt && [ -f $REMOTE/d/moved.txt ] && [ ! -e $REMOTE/new.txt ]"
check "rename over"      sh -c "echo a > $MNT/a && echo b > $MNT/b && mv $MNT/a $MNT/b && [ \"\$(cat $REMOTE/b)\" = a ]"
check "symlink"          sh -c "ln -s d/moved.txt $MNT/link && [ \"\$(readlink $REMOTE/link)\" = d/moved.txt ] && cat $MNT/link >/dev/null"
check "symlink and hard link in a listed directory" sh -c "ls $MNT/d >/dev/null && ln -s moved.txt $MNT/d/l2 && ln $MNT/d/moved.txt $MNT/d/h2 && [ \"\$(readlink $MNT/d/l2)\" = moved.txt ] && [ -f $MNT/d/h2 ] && rm $MNT/d/l2 $MNT/d/h2"
check "chmod"            sh -c "chmod 600 $MNT/b && [ \"\$(stat -f %Lp $REMOTE/b)\" = 600 ]"
check "utimes"           sh -c "touch -t 202001010000 $MNT/b && [ \"\$(stat -f %Sm -t %Y $REMOTE/b)\" = 2020 ]"
check "truncate"         sh -c ": > $MNT/b && [ \"\$(stat -f %z $REMOTE/b)\" = 0 ]"
check "rmdir non-empty fails" sh -c "! rmdir $MNT/d"
check "rm + rmdir"       sh -c "rm $MNT/d/moved.txt $MNT/link && rmdir $MNT/d && [ ! -e $REMOTE/d ]"

echo "== data"
head -c 12345678 /dev/urandom > $WORK/rand.bin
check "large write (12 MB)" sh -c "cp $WORK/rand.bin $MNT/big.bin && cmp -s $WORK/rand.bin $REMOTE/big.bin"
check "large read"          sh -c "cmp -s $WORK/rand.bin $MNT/big.bin"
check "pwrite in place"     sh -c "printf XYZ | dd of=$MNT/big.bin bs=1 seek=1000 conv=notrunc 2>/dev/null && [ \"\$(dd if=$REMOTE/big.bin bs=1 skip=1000 count=3 2>/dev/null)\" = XYZ ]"
check "small writes (4 KiB)" sh -c "dd if=/dev/zero of=$MNT/small.bin bs=4k count=2000 2>/dev/null && [ \"\$(stat -f %z $REMOTE/small.bin)\" = 8192000 ]"
rm -f $MNT/big.bin $MNT/small.bin

echo "== writing through an open descriptor, whatever the file's mode"
# What an app may do with a file is settled when it opens it. $WORK/ro.py
# creates FILE read-only (like git's objects) or opens it, and writes.
print -r -- 'import os, subprocess, sys, time
how, path = sys.argv[1], sys.argv[2]
if how == "open":
    fd = os.open(path, os.O_WRONLY | os.O_TRUNC)
else:
    fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o444)
os.write(fd, b"one ")
if how == "chmod": os.fchmod(fd, 0o444)
if how == "reconnect":
    os.fsync(fd)
    subprocess.run(["pkill", "-f", "ssh -x -a -o ClearAllForwardings.*%s sftp" % sys.argv[3]])
    time.sleep(0.5)
os.write(fd, b"two")
os.fsync(fd)
os.close(fd)' > $WORK/ro.py
is444() { [ "$(cat $1)" = "one two" ] && [ "$(stat -f %Lp $1)" = 444 ] }
check "write to a file created read-only" sh -c "python3 $WORK/ro.py create $MNT/ro1"
check "  ...data and mode on the server"   is444 $REMOTE/ro1
check "chmod read-only, then write"        sh -c "python3 $WORK/ro.py chmod $MNT/ro2"
check "  ...data and mode on the server"   is444 $REMOTE/ro2
check "the same after a reconnect"         sh -c "python3 $WORK/ro.py reconnect $MNT/ro3 $HOST"
check "  ...data and mode on the server"   is444 $REMOTE/ro3
check "ftruncate through it"               sh -c "python3 -c 'import os,sys; fd = os.open(sys.argv[1], os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o444); os.write(fd, b\"0123456789\"); os.ftruncate(fd, 4); os.close(fd)' $MNT/ro4 && [ \"\$(cat $REMOTE/ro4)\" = 0123 ]"
# A file the mode says we may write but the server won't let us: the
# open must fail, not a later close (after the data went into the cache).
echo keep > $REMOTE/locked; chflags uchg $REMOTE/locked
check "refused by the server: open fails"  sh -c "python3 $WORK/ro.py open $MNT/locked 2>&1 | grep -q 'PermissionError.*locked'"
check "  ...file untouched"                sh -c "[ \"\$(cat $REMOTE/locked)\" = keep ]"
chflags nouchg $REMOTE/locked
if git init -q $WORK/repo 2>/dev/null; then
    (cd $WORK/repo && for i in 1 2 3; do echo $i > f$i; done && git add . && git -c user.name=e2e -c user.email=e2e@example.com commit -qm one)
    check "git clone onto the mount"       git clone -q --no-local $WORK/repo $MNT/clone
    check "  ...complete on the server"    sh -c "git -C $REMOTE/clone fsck --strict && [ -z \"\$(git -C $REMOTE/clone status --porcelain)\" ] && [ \"\$(cat $REMOTE/clone/f3)\" = 3 ]"
else
    skp "git clone" "no git"
fi
rm -rf $MNT/ro1 $MNT/ro2 $MNT/ro3 $MNT/ro4 $MNT/locked $MNT/clone

echo "== macOS metadata"
check "xattr set/get"        sh -c "xattr -w com.example.t v $MNT/b && [ \"\$(xattr -p com.example.t $MNT/b)\" = v ]"
check "rename onto itself keeps xattrs" sh -c "python3 -c 'import os,sys; os.rename(sys.argv[1], sys.argv[1])' $MNT/b && [ \"\$(xattr -p com.example.t $MNT/b)\" = v ]"
check "no AppleDouble files" sh -c "! ls -a $REMOTE | grep -q '^\._'"
check ".DS_Store refused"    sh -c "! touch $MNT/.DS_Store && [ ! -e $REMOTE/.DS_Store ]"
check "._ names refused"     sh -c "! touch $MNT/._x"

echo "== remote changes"
if [ "$entitled" = 1 ]; then
    echo v1 > $REMOTE/sub/f.txt; cat $MNT/sub/f.txt >/dev/null
    echo "version two" > $REMOTE/sub/f.txt
    check "file rewrite visible on next open" sh -c "[ \"\$(cat $MNT/sub/f.txt)\" = 'version two' ]"
    echo 3 > $REMOTE/sub/f.txt
    check "file shrink: no stale tail"        sh -c "[ \"\$(cat $MNT/sub/f.txt)\" = 3 ]"
    ls $MNT/sub/ghost.txt >/dev/null 2>&1; sleep 1.2; echo boo > $REMOTE/sub/ghost.txt; sleep 3
    check "remote create visible (negative cache purged)" sh -c "[ \"\$(cat $MNT/sub/ghost.txt)\" = boo ]"
    sleep 1.2; rm $REMOTE/sub/ghost.txt; sleep 3
    check "remote delete visible"             sh -c "! ls $MNT/sub/ghost.txt"
else
    skp "remote-change tests" "ad-hoc build has no kernel cache invalidation"
fi

# A lock file or directory another machine took after we listed the
# directory: the kernel thinks the name is free, the create must say EEXIST.
excl() { python3 -c 'import os, sys, errno
try: os.mkdir(sys.argv[2]) if sys.argv[1] == "dir" else os.close(os.open(sys.argv[2], os.O_CREAT | os.O_EXCL | os.O_WRONLY))
except OSError as e: sys.exit(0 if e.errno == errno.EEXIST else 1)
sys.exit(1)' $1 $2 }
ls $MNT/sub >/dev/null; touch $REMOTE/sub/lock; mkdir $REMOTE/sub/lockdir
check "O_EXCL create of a name made on the server: EEXIST" excl file $MNT/sub/lock
check "mkdir of a name made on the server: EEXIST"         excl dir $MNT/sub/lockdir

echo "== reconnect"
pkill -f "ssh -x -a -o ClearAllForwardings.*$HOST sftp"; sleep 0.5
echo after > $REMOTE/sub/after.txt
check "works after killing ssh" sh -c "[ \"\$(cat $MNT/sub/after.txt)\" = after ]"
pid=$(pgrep -f "ssh -x -a -o ClearAllForwardings.*$HOST sftp" | head -1)
kill -STOP $pid 2>/dev/null; echo frozen > $REMOTE/sub/frozen.txt
start=$(date +%s)
check "heals a silently dead connection" sh -c "[ \"\$(cat $MNT/sub/frozen.txt)\" = frozen ]"
echo "     (took $(( $(date +%s) - start )) s)"

echo "== unmount"
check "umount" umount $MNT

echo "== ssh setups (ssh runs in the helper, outside the sandbox)"
# An agent whose socket lives where a sandboxed process couldn't reach it,
# like Secretive's or 1Password's (in ~/Library/...).
AGENTDIR="$HOME/Library/Application Support/sshfs-e2e"
mkdir -p $AGENTDIR; rm -f $AGENTDIR/agent.sock
if [ -f ~/.ssh/id_ed25519_sshfs_agenttest ] && eval "$(ssh-agent -a $AGENTDIR/agent.sock -s)" >/dev/null; then
    agentpid=$SSH_AGENT_PID
    print -r -- '#!/bin/sh
echo agent-test-passphrase' > $WORK/askpass; chmod +x $WORK/askpass
    SSH_ASKPASS=$WORK/askpass SSH_ASKPASS_REQUIRE=force ssh-add ~/.ssh/id_ed25519_sshfs_agenttest 2>/dev/null </dev/null
    check "agent from \$SSH_AUTH_SOCK (outside any sandbox exception)" ${=SSHFS} "sshfs-agenttest:$REMOTE" $MNT
    check "  ...and it reads" sh -c "[ \"\$(cat $MNT/sub/hello.txt)\" = hello ]"
    umount $MNT 2>/dev/null
    check "agent from IdentityAgent, as in ~/.ssh/config" ${=SSHFS} "sshfs-agenttest:$REMOTE" $MNT -o agent=none -o "IdentityAgent=\"$AGENTDIR/agent.sock\""  # quoted for ssh: the path has a space
    umount $MNT 2>/dev/null
    check "no agent: mount fails" sh -c "! $SSHFS 'sshfs-agenttest:$REMOTE' $MNT -o agent=none"
    kill $agentpid; unset SSH_AUTH_SOCK SSH_AGENT_PID
    rm -rf $AGENTDIR
else
    skp "agent tests" "no ~/.ssh/id_ed25519_sshfs_agenttest (see docs/DEVELOPMENT.md)"
fi
echo "== prompts (answered by a script through -o askpass=)"
# ssh asks through the app's askpass mode; -o askpass= replaces the dialog
# with a program. $WORK/ask logs each question and answers from files.
KEY=~/.ssh/id_ed25519_sshfs_agenttest
if [ -f $KEY ]; then
    print -r -- "#!/bin/sh
printf '%s\n' \"\$1\" | head -1 >> $WORK/ask.log
[ -e $WORK/ask.deny ] && exit 1
case \"\$1\" in *yes/no*) echo yes;; *) cat $WORK/ask.answer;; esac" > $WORK/ask; chmod +x $WORK/ask
    asked() { wc -l < $WORK/ask.log 2>/dev/null | tr -d ' ' }
    # The passphrase key, no agent; BatchMode=no overrides the test host's config.
    ASKOPTS=(-o BatchMode=no -o agent=none -o IdentityAgent=none -o IdentityFile=$KEY -o askpass=$WORK/ask)
    KCACCOUNT="sshfs-agenttest Enter passphrase for key '${KEY:A}'"
    kcforget() { security delete-generic-password -s SSHFS -a "$KCACCOUNT" >/dev/null 2>&1 }
    sshpid() { pgrep -f "ssh -x -a -o ClearAllForwardings.*sshfs-agenttest sftp" | head -1 }
    kcforget; echo agent-test-passphrase > $WORK/ask.answer

    check "unknown host key + passphrase: mounts" ${=SSHFS} "sshfs-agenttest:$REMOTE" $MNT $ASKOPTS -o UserKnownHostsFile=$WORK/known_hosts
    check "  ...asked both questions"       sh -c "[ $(asked) = 2 ] && grep -q authenticity $WORK/ask.log && grep -q passphrase $WORK/ask.log"
    check "  ...host key saved by ssh"      grep -q localhost $WORK/known_hosts
    umount $MNT 2>/dev/null

    : > $WORK/ask.log; touch $WORK/ask.deny
    err=$(${=SSHFS} "sshfs-agenttest:$REMOTE" $MNT $ASKOPTS 2>&1)
    check "cancelled prompt: mount fails, says so" sh -c "! mount | grep -q ' on $MNT ' && echo '$err' | grep -qi 'cancel'"
    check "  ...and asks only once"         sh -c "[ $(asked) = 1 ]"
    rm $WORK/ask.deny; echo wrong > $WORK/ask.answer
    err=$(${=SSHFS} "sshfs-agenttest:$REMOTE" $MNT $ASKOPTS -o NumberOfPasswordPrompts=1 -o PreferredAuthentications=publickey 2>&1)
    check "wrong passphrase: authentication error" sh -c "! mount | grep -q ' on $MNT ' && echo '$err' | grep -q 'Authentication error'"

    echo agent-test-passphrase > $WORK/ask.answer; : > $WORK/ask.log
    check "mount with a passphrase prompt" ${=SSHFS} "sshfs-agenttest:$REMOTE" $MNT $ASKOPTS
    kill $(sshpid); sleep 0.5; echo r1 > $REMOTE/sub/r1.txt
    check "reconnect asks again, once"      sh -c "[ \"\$(cat $MNT/sub/r1.txt)\" = r1 ] && [ \$(wc -l < $WORK/ask.log) = 2 ]"
    touch $WORK/ask.deny; kill $(sshpid); sleep 0.5; echo r2 > $REMOTE/sub/r2.txt
    check "reconnect refused: fails instead of hanging" sh -c "! cat $MNT/sub/r2.txt"
    sleep 12; cat $MNT/sub/r2.txt >/dev/null 2>&1
    check "  ...and doesn't ask in a loop"  sh -c "[ $(asked) = 3 ]"
    rm $WORK/ask.deny; ${=APP}/Contents/MacOS/SSHFS check; sleep 2
    check "SSHFS check: asks again and heals" sh -c "[ \"\$(cat $MNT/sub/r2.txt)\" = r2 ] && [ \$(wc -l < $WORK/ask.log) = 4 ]"
    umount $MNT 2>/dev/null

    # A remembered secret answers silently. Stored the way the dialog's
    # checkbox does it, by the app itself: an item made by security(1) would
    # make macOS ask before the app may read it.
    kcremember() {
        SSHFS_ASKPASS_MODE=interactive SSHFS_ASKPASS_TARGET=sshfs-agenttest SSHFS_ASKPASS_PROGRAM=$WORK/ask \
            SSHFS_ASKPASS_REMEMBER=1 zsh -c "'$APP/Contents/MacOS/SSHFS' \"Enter passphrase for key '${KEY:A}': \"" >/dev/null 2>&1
    }
    kcremember
    if security find-generic-password -s SSHFS -a "$KCACCOUNT" >/dev/null 2>&1; then
        : > $WORK/ask.log; touch $WORK/ask.deny
        check "passphrase from the keychain: no question" ${=SSHFS} "sshfs-agenttest:$REMOTE" $MNT $ASKOPTS
        kill $(sshpid); sleep 0.5; echo r3 > $REMOTE/sub/r3.txt
        check "  ...nor on reconnect"       sh -c "[ \"\$(cat $MNT/sub/r3.txt)\" = r3 ] && [ ! -s $WORK/ask.log ]"
        umount $MNT 2>/dev/null
        rm $WORK/ask.deny; echo stale > $WORK/ask.answer; kcremember
        echo agent-test-passphrase > $WORK/ask.answer; : > $WORK/ask.log
        check "stale keychain secret: asks instead" sh -c "$SSHFS 'sshfs-agenttest:$REMOTE' $MNT $ASKOPTS && [ \$(wc -l < $WORK/ask.log) = 1 ]"
        check "  ...and forgets it"         sh -c "! security find-generic-password -s SSHFS -a \"$KCACCOUNT\""
        umount $MNT 2>/dev/null
    else
        skp "keychain tests" "can't write to the login keychain"
    fi
    kcforget
else
    skp "prompt tests" "no ~/.ssh/id_ed25519_sshfs_agenttest (see docs/DEVELOPMENT.md)"
fi

CIPHERS=aes256-gcm@openssh.com,chacha20-poly1305@openssh.com
check "ProxyJump; list-valued ssh option" ${=SSHFS} "$HOST:$REMOTE" $MNT -o ProxyJump=$HOST,Ciphers=$CIPHERS,nobrowse
check "  ...and it reads" sh -c "[ \"\$(cat $MNT/sub/hello.txt)\" = hello ]"
check "  ...ssh got the whole list" pgrep -f "Ciphers=$CIPHERS -o .* $HOST sftp"
check "  ...kernel option after it still applies" sh -c "mount | grep ' on $MNT ' | grep -q nobrowse"
umount $MNT 2>/dev/null
sleep 1
check "no ssh left behind" sh -c "! pgrep -f 'ssh -x -a -o ClearAllForwardings.*(sshfs-agenttest|$HOST) sftp'"

echo
echo "passed $pass, failed $fail, skipped $skip"
[ $fail = 0 ]
