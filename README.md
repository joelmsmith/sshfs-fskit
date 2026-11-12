# sshfs for macOS

Mount a remote directory over SSH, like sshfs on Linux. Built on Apple's
FSKit: no kernel extension, no macFUSE, no closed-source parts. It uses your
system `ssh`, so your `~/.ssh/config`, keys, agent and `known_hosts` apply.

**Status: early (0.1).** Used daily by its author. Requires **macOS 27**.

## Install

1. Download `SSHFS.zip` from the [latest release](../../releases/latest)
   (signed and notarized), unzip it, move `SSHFS.app` to /Applications and
   open it once. It opens System Settings: switch on **SSHFS** under
   General → Login Items & Extensions → File System Extensions.
2. Put the command on your PATH:
   `ln -sf /Applications/SSHFS.app/Contents/MacOS/SSHFS ~/bin/sshfs`
   (or any directory on your `PATH`).

The first mount registers a small background helper (shown as SSHFS in
Login Items). The first mount of a host on your local network makes macOS
ask whether SSHFS may find devices on local networks: allow it, or mounts
fail with "No route to host".

## Use

```sh
sshfs user@host:Music ~/mnt/music              # relative to your remote home
sshfs user@host:/srv/data ~/mnt/data -p 2222
sshfs user@host: ~/mnt/home -o IdentityFile=~/.ssh/id_work,cache_timeout=5
umount ~/mnt/music
```

Mounting where sshfs is already mounted replaces that mount, if nothing is
using it: the way to recover one whose server went away ("Socket is not
connected").

Options (`-o`, comma-separated):

| Option | Meaning |
|---|---|
| `cache_timeout=N` | seconds to cache attributes and listings (default 20) |
| `dir_poll=N` | seconds between checks for remote changes in recently used directories (default 5, 0 = off) |
| `agent=PATH` | ssh-agent socket (default: your `$SSH_AUTH_SOCK`; `none` to disable) |
| `askpass=PROGRAM` | ask this program for passwords instead of showing a dialog (called like ssh's `SSH_ASKPASS` programs) |
| `Key=Value` | any ssh option, e.g. `IdentityFile=~/.ssh/id_work` or `Ciphers=aes256-gcm@openssh.com,chacha20-poly1305@openssh.com` |
| `rdonly`, `nobrowse`, … | passed to mount(8) |

The mount point is created if missing.

- **Logging in:** passwords, key passphrases and unknown host keys are
  asked for in a system dialog, which can remember a secret in your login
  keychain. `-o BatchMode=yes` never asks.
- **Any ssh setup:** ssh runs in the helper outside the file system's
  sandbox, so it behaves as in Terminal: any ssh-agent (Secretive,
  1Password, …), `ProxyJump`, your whole `~/.ssh/config`.
- **Reconnecting:** after network changes, sleep or a dropped connection,
  the mount reconnects by itself. If reconnecting needs a password and you
  decline, it stops until you run `SSHFS check` (which also forces a
  connection check on all mounts).
- **Coherency:** like NFS, close-to-open. Opening a file checks it with the
  server, and recently used directories are polled for changes.
- `SSHFS status` shows whether everything is set up.

## Limits

- Extended attributes last only until unmount. `.DS_Store` and
  AppleDouble (`._*`) files are never written to the server: copying a
  folder or checking out a repository that contains such files reports an
  error for each of them.
- File names on the server that aren't valid UTF-8 (old Latin-1 archives)
  show up in listings with a replacement character and can't be opened.
- Changes made on the server show up after a few seconds: new and deleted
  names within `dir_poll` (5 s) in directories you're using, new contents
  at the next open of a file, and in a file you keep open (`tail -f`)
  within `cache_timeout` (20 s).
- Two machines appending to the same file at the same time (a shared log)
  can overwrite each other's lines.
- A file that was deleted while still open (a temporary file) is lost if
  the connection drops before it's closed.
- SFTP has no inode numbers: hard links show as separate files, and file
  IDs change across remounts.
- An app's `fsync(2)` sends its data to the server but doesn't make the
  server commit it to disk; `sync` and unmount do.
- A missing name at the very top of a mount can stay missing until the
  directory is listed again (macOS won't let the root's cache be
  invalidated).
- File locks (`flock`, `fcntl`) work between programs on this Mac only;
  the server and other clients don't see them.

Logs: `log stream --info --predicate 'subsystem == "com.joelmsmith.sshfs"'`

## How it works

An FSKit module (the sandboxed extension) speaks SFTP v3, pipelined, over
the pipes of an `ssh` that a per-user helper starts for it. Details and the
macOS facts behind the design: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Build from source

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md). In short:
`scripts/build-adhoc.sh` builds without an Apple Developer account (remote
changes may look stale until the cache times out, and the ad-hoc build
with the helper is untested); `scripts/build-signed.sh` and
`scripts/build-release.sh` need a paid team with the FSKit module
capability.

## License

MIT; see [LICENSE](LICENSE).
