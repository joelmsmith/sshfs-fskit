# Architecture

How sshfs works today, and the macOS platform facts it's built on. Keep this
file true: when a fact changes, edit it here rather than appending.

## Shape

```
sshfs CLI (App/main.swift, unsandboxed)
  ├─ registers the helper agent if needed (SMAppService)
  └─ /sbin/mount -F -t sshfs 'ssh://user@host/path?opts' mountpoint
       └─ fskitd launches the extension (sandboxed, ExtensionKit appex;
          one process per mount)
            SSHFileSystem   loadResource: parse URL, connect, SFTP handshake
            HelperClient    asks the helper for an ssh, gets its pipes
            Remote          owns the connection: reconnect, waits, health checks
            Liveness        network change / wake / manual check -> health check
            SSHVolume       every FSKit operation, cache coherency, dir poller
            ItemTable       path <-> item ID, attribute / negative / xattr caches
            Packages/SFTP   pipelined SFTP v3 client over a pair of fds

helper (App/Helper.swift: the app binary run as `SSHFS helper`, unsandboxed,
        a per-user launchd agent started on demand via its Mach service)
  └─ /usr/bin/ssh -s … sftp   one per connection, in its own session
       └─ askpass (App/Askpass.swift: the app binary again, run by ssh for
          each question; dialog, keychain, or the `askpass=` program)
```

- The extension must be sandboxed and a child ssh would inherit the sandbox
  (no Secretive/1Password agent, no writing `known_hosts`, …). So the helper
  starts ssh, exactly as Terminal would, and returns ssh's stdin, stdout and
  stderr **descriptors** over XPC (`Shared/HelperProtocol.swift`). The
  extension speaks SFTP on those pipes directly; no data passes through the
  helper, so throughput is unchanged.
- One XPC connection per ssh. When the connection goes away (transport
  closed, extension exited) the helper SIGKILLs that ssh, which also covers
  a wedged or stopped ssh the sandboxed extension couldn't signal.
- ssh runs in its own session, so it survives the helper: killing or
  upgrading the helper leaves mounts working, and the next reconnect starts
  a new helper. (Such an orphaned ssh ends when the extension closes its
  pipes; only a *stopped* orphan would linger.)
- The helper exits after 30 s with no connections and no ssh processes.
  `scripts/install.sh` stops it so the next connect runs the new binary.
- The helper only runs `/usr/bin/ssh`, and accepts only clients signed by
  its own team (ad-hoc builds can't check: any process of the user, which
  could run ssh anyway, and any sandboxed app allowed to look up the
  service name).

## Platform facts (verified on macOS 27.2)

**Loading and signing**
- FSKit modules are ExtensionKit app extensions and **must be sandboxed**:
  pkd refuses others ("plug-ins must be sandboxed"; tested 2026-11-09). Child
  processes (ssh) inherit the sandbox.
- `com.apple.developer.fskit.fsmodule` is a restricted entitlement. It is a
  self-service capability on the App ID (`FSKIT_MODULE`) for paid teams;
  personal teams can't get it. It works with **both** a development profile
  and a **Developer ID** profile (`MAC_APP_DIRECT`): notarized builds load
  with it on any Mac.
- Without it (ad-hoc builds), fskitd still loads the module with SIP on, but
  the kernel gives the extension no user client (`fsmodule_entitled 0` in the
  kernel log), so `FSVolume.setCacheState` fails (kIOReturnNotPermitted).
  Granting cache modes from `open` still works. AMFI kills ad-hoc binaries
  that *claim* the entitlement.
- `FSClient.mountSingleVolume` needs `com.apple.developer.fskit.mount`, which
  we don't have; `/sbin/mount -F` works and mounts anywhere.
- Enablement (System Settings → File System Extensions) is tied to the
  registered copy; switching which copy LaunchServices registers can disable
  the module, and `pluginkit -e use` doesn't re-enable it.

**Resources and options**
- `FSGenericURLResource` + Info.plist `FSSupportsGenericURLResources`,
  `FSSupportedSchemes = [ssh]` lets `mount -F -t sshfs ssh://…` work.
- `mount -o` options reach the module only at `activate`, after
  `loadResource` has already connected. So ssh options travel in the URL
  query; our own tunables work either way.

**Caching**
- Close-to-open file coherency: `open` revalidates with the server and, if
  size/mtime changed, invalidates the kernel's pages and attributes before
  returning (bounded 1 s wait).
- Directory invalidation needs `(cacheMode: .none, coherency: .noCache,
  action: .invalidate)`; other combinations → kIOReturnBadArgument.
- **The volume root can't be invalidated** (kIOReturnBadArgument for every
  combination), so a negative lookup at the top of a mount sticks until a
  listing refreshes it. Apple Feedback candidate.
- An app's `fsync(2)` does not reach the module's `synchronize`; dirty pages
  arrive as ordinary writes. `synchronize` (sync/unmount) runs
  `fsync@openssh.com`.
- Write-back errors surface at `close()`/`fsync()`; SFTP v3 says only
  "failure", so on write failure we statvfs and report ENOSPC when full.
  Likewise a failed create or mkdir is followed by an lstat, to report
  EEXIST for a name that appeared on the server after the kernel (or our
  listing cache) saw it free.
- Opens are aggregated per item: creating a file is `createItem` followed
  by `open`; a second descriptor with more access is another `open` with
  the union of the modes; `close` comes once, after the last descriptor
  and mapping are gone. `mknod(2)` of a regular file is refused (EPERM)
  before it reaches the module.
- The kernel checks permissions itself, against the mode we report and
  with the local user as owner, and only when an app opens a file. A write
  through an open descriptor reaches the module later (write-back), with
  nothing saying who opened the file or how.

**Sandbox, helper and ssh** (verified 2026-11-09, dev-signed build)
- The sandboxed extension can look up a Mach service in the user's launchd
  domain given
  `com.apple.security.temporary-exception.mach-lookup.global-name`; the
  extension runs in that domain (as the user, ppid 1). No app group needed,
  and nothing in the name depends on the team ID.
- `SMAppService.agent(plistName:)` with the plist in
  `Contents/Library/LaunchAgents` works from the CLI (also via the `sshfs`
  symlink). `BundleProgram` plus `ProgramArguments` runs the app binary with
  arguments, so no separate helper executable is needed. Status is
  `.notFound` (not `.notRegistered`) before the first `register()`.
  Registration survives reinstalling the app at the same path. No approval
  prompt for dev-signed or notarized Developer ID builds on this Mac.
- **A registration is tied to the kind of signature** (launchd's launch
  constraint records a validation category: 3 = development, 6 = Developer
  ID). If the installed binary is of another kind, every spawn fails with
  `EX_CONFIG` ("Could not find and/or execute program"), launchd retries
  every 10 s and XPC clients just wait. Worse, for a while after switching
  kinds (observed: up to a minute or two, mostly dev → notarized; cause not
  pinned down, retries and waiting 80 s alone didn't help in one run) a
  fresh registration still records the *previous* build's category. Hence
  `ensureHelper` (App/main.swift) pings the helper and re-registers until
  it answers, on every mount, and the extension gives up on the helper
  after 10 s. `install.sh` may report that the helper doesn't start yet;
  the next mount has healed it every time. Same-kind upgrades (release
  over release, what users do) aren't affected.
- An **un-notarized** Developer ID build can't run the helper at all
  (registered as category 3, launched as 6). `NOTARIZE=0` builds are only
  good for checking that signing works.
- `FileHandle`s passed in an NSXPC reply arrive as working descriptors, and
  the sandbox allows I/O on them (pipes). The receiver must `dup` them: the
  handles close theirs on dealloc.
- A launchd agent's environment: `PATH=/usr/bin:/bin:/usr/sbin:/sbin`,
  the real `HOME`, and `SSH_AUTH_SOCK` of launchd's own ssh-agent. Not the
  user's shell environment, so the `sshfs` command passes its
  `$SSH_AUTH_SOCK` along (`agent=` in the URL) and the helper sets it for
  ssh. `IdentityAgent` in `~/.ssh/config` is honored as usual.
- Children spawned from a dispatch thread inherit a blocked signal mask
  (ssh then ignores SIGTERM): the helper resets mask and dispositions
  (`POSIX_SPAWN_SETSIGMASK | SETSIGDEF`).
- launchd doesn't kill children that left the agent's process group
  (`POSIX_SPAWN_SETSID`) when the agent dies or is restarted.
- ssh has no terminal; with `SSH_ASKPASS_REQUIRE=force` it runs
  `$SSH_ASKPASS` for every question: the prompt is the only argument, the
  answer is read from stdout, a non-zero exit means no answer. For the
  host-key question `SSH_ASKPASS_PROMPT` is **unset** and ssh wants the
  word `yes` (verified, OpenSSH 10.5); `confirm`/`none` only come with
  agent confirmations and notices.
- ssh repeats a prompt after a wrong answer and then moves on to its other
  methods: one bad passphrase can mean nine prompts (3 passphrase, 3
  keyboard-interactive, 3 password), and a cancelled one still gets the
  remaining six. Each prompt is a new askpass process.
- The askpass program's stderr comes out of ssh's stderr.
- `ConnectTimeout` doesn't run while ssh waits for an answer, and
  `mount`/FSKit wait for `loadResource` at least 6 minutes (observed). The
  server's `LoginGraceTime` (120 s by default) is the real limit for
  passwords; ssh only notices that after the answer arrives.
- `CFUserNotification` shows a system alert (secure text field, checkbox)
  from a process that isn't an app; it comes to the front by itself.
- A keychain item made by `security(1)` isn't readable by the app without
  a system prompt, even with `-T`; items the app creates are. In the file
  keychain `SecKeychainSetUserInteractionAllowed(false)` makes such a read
  fail instead of prompting.
- ssh's `-o` parser splits values on spaces: a path with a space needs
  quotes inside the value (`-o 'IdentityAgent="/a b/sock"'`). Several ssh
  options take comma-separated lists (`Ciphers`, `MACs`, …), so our `-o`
  splitting keeps a comma-separated piece without `=` with the ssh option
  before it (`Shared/MountOptions.swift`).

**Privacy prompts**
- Local Network: the first time the helper's ssh connects to a host on the
  local network, macOS asks "Allow SSHFS to find devices on local
  networks?". Until it is allowed the connect fails with **"No route to
  host"**, which is what `mount` reports (the `sshfs` error message says
  so). Loopback isn't affected. For ~20 s after installing a new build the
  same error appears while the rules for the new app are rebuilt.
- Network volumes: the first access by a terminal app asks for consent
  (and blocks until answered). A launchd job without a responsible app is
  refused without a prompt (TCC `SystemPolicyNetworkVolumes`); processes
  under sshd are allowed.

## Design decisions

- **Identity:** SFTP v3 has no inode numbers. Item IDs are per path, per
  mount; hard links appear as separate files; IDs change across remounts.
  Ownership is shown as the local user; the server enforces permissions.
- **Xattrs:** session-only (in memory, moved on rename, lost on unmount).
  Creating `.DS_Store` and `._*` is refused (EACCES), so Finder doesn't
  litter servers.
- **Caches:** attributes and listings for `cache_timeout` (default 20 s);
  negative lookups from listings (Finder's AppleDouble probes made `ls -l`
  of 5000 files take 47 s without it). Directories the kernel used in the
  last 2 min are re-stat'ed every `dir_poll` (5 s, max 64 dirs, parallel);
  a change invalidates that directory. SFTP mtimes have 1 s resolution, so
  two changes within a second can be missed until the next change.
- **Write handles:** an app's right to write is settled at its open, so
  that is when the SFTP handle is settled too. `createItem` keeps the handle
  the file was created with (it can write whatever the mode: git creates
  its objects 0444 and then writes them), and an `open` for writing opens
  one, alongside its lstat, if the item has none. The handle lives until
  the item's close, so a later chmod doesn't matter, and a server that
  won't let us write fails the app's `open(2)` instead of losing cached
  data at close. `ftruncate` goes through the same handle (`fsetstat`).
  Reads open their handle at the first read.
- **Names going away:** an open descriptor keeps its file when it is
  unlinked or another file is renamed over it; on the server only an open
  handle does. So `removeItem` and `renameItem` first give a file the
  kernel has open its handle, then mark the item detached: from then on
  everything about it goes through the handle (`fstat`, `fsetstat`),
  nothing is cached under its old path (which may name a new file), and
  after a reconnect it is gone (ESTALE). The other direction, a file
  replaced on the server: when its size or mtime is seen to change, the
  read handle is dropped, so reads follow the name to the new file.
- **Names:** paths are Swift strings, and names from the server are
  decoded as UTF-8 with replacement characters
  (`DirectoryEntry.filename`), so a name with other bytes is listed but
  can't be found again: lookup sends the replacement character. Fixing it
  means a reversible mapping for invalid bytes through every place that
  builds a path. Not tested by e2e: the loopback server's APFS refuses
  such names (seen against a Linux server).
- **Append:** the kernel turns `O_APPEND` into writes at the end it knows
  of, and FSKit doesn't say a write was an append. Two machines appending
  to one file overwrite each other unless each reopens it between writes
  (an open revalidates the size). Same as sshfs.
  After a reconnect the handles are gone and are reopened by path at the
  next read or write. If that is refused for a file the kernel has open for
  writing and the mode lacks owner-write, the volume adds owner-write,
  opens and restores the mode (`openForWriting`): the one thing here that
  isn't exact, visible on the server for a moment, and it works exactly
  when the file is ours. A connection lost in the middle is finished on
  the next one.
- **Authentication prompts:** the helper points ssh's `SSH_ASKPASS` at the
  app binary; `SSHFS_ASKPASS_MODE` in the environment (from the extension)
  switches it to askpass mode and says whether it may ask (`interactive`:
  the first connect, and one attempt per outage) or not (`silent`).
  A secret is looked up in the login keychain first (service `SSHFS`,
  account = target + prompt), then asked for; it is stored only if the
  user ticks the box, and dropped when ssh repeats the prompt (it was
  wrong). Per-ssh state in `$TMPDIR/com.joelmsmith.sshfs.askpass/` makes
  Cancel final for that ssh. Askpass reports to the extension with
  `sshfs-askpass: asked | cancelled | prompt needed` lines on stderr.
  The dialog is taken down if ssh exits. `-o BatchMode=yes` gives the old
  never-ask behavior; `-o askpass=PROGRAM` asks a program instead.
- **Reconnect:** attempts are silent. If one fails with "prompt needed",
  the next is interactive, once per outage; if the user was asked and it
  still failed (or a second question comes up), reconnecting **stops**
  and calls fail at once with EAUTH/ECANCELED until `SSHFS check` (or a
  remount). No dialogs in a loop, no hammering a server with failed
  logins; other authentication failures back off to 60 s.
  One reconnect loop with backoff (250 ms doubling, cap 10 s).
  Handles carry a connection generation and are reopened at their next
  use (see Write handles). Idempotent calls
  (stat, readdir, read, pwrite, setattr) retry once; create/remove/rename
  don't. Calls wait up to 20 s for a connection, then fail fast (ENOTCONN)
  while reconnecting continues.
- **Liveness:** a request unanswered for 5 s, a network path change
  (NWPathMonitor), a detected sleep (ContinuousClock vs SuspendingClock gap)
  or `SSHFS check` (Darwin notification `com.joelmsmith.sshfs.check`)
  triggers a 3 s probe; no answer → reconnect (`SSHFS check` also restarts
  a reconnect that stopped to wait for the user). A frozen connection heals in
  ~9 s unprompted. Not yet tested on real sleep/wake or interface changes.

## Performance baseline (VM → Linux host, ~4–9 ms RTT, 2026-11-08)

| Measurement | Value |
|---|---|
| SFTP lstat, sequential / 500 in parallel | 4.7 / 0.03 ms per op |
| 106 MB read, cold (raw `ssh cat`: 0.96 s) | 0.92 s (~115 MB/s) |
| 106 MB read, kernel cache disabled | 10.8 s |
| 64 MB write, 4 KiB / 1 MiB blocks (write-back) | 79 / 100 MB/s |
| Cold `ls -l`, 5000 files | 1.0 s |
| Mount | ~0.4 s |

The kernel issues uncached lookups serially, so latency, not bandwidth, is
the main cost on slow links.
