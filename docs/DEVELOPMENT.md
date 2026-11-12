# Development

How to build, test and sign without tripping over macOS.

## Requirements

- macOS 27 on Apple Silicon, Xcode with the macOS 27 SDK.
- For full-featured builds: a paid Apple Developer team with the FSKit
  module capability (see Signing). Without one, `build-adhoc.sh` still
  produces a working build with one limitation.

## Build and install

```sh
scripts/build-signed.sh     # dev build: development profile (registered Macs only), full features
scripts/build-release.sh    # Developer ID, notarized + stapled -> build/SSHFS.zip (any Mac)
scripts/build-adhoc.sh      # no Apple account: works, but no kernel cache invalidation
```

- Every script installs to **`/Applications/SSHFS.app`** via
  `scripts/install.sh` and unregisters the copies under `build/`. Keep it
  that way: with several registered copies macOS picks one arbitrarily, and
  switching copies can disable the module. If `SSHFS list` says
  `disabled`, switch it on in System Settings → General → Login Items &
  Extensions → File System Extensions (`SSHFS` with no arguments opens
  that pane). Only a person can do this.
- **Remount after every install**: a running mount keeps the old extension
  process (each mount has its own).
- For ~20 s after an install, mounting a LAN host can fail with "No route
  to host" while macOS rebuilds its Local Network rules for the new app.
  Wait and retry before suspecting anything else.
- The helper agent (`SSHFS status`, `SSHFS register|unregister`,
  `launchctl print gui/$(id -u)/com.joelmsmith.sshfs.helper`) is registered
  by the first `sshfs` mount. `install.sh` re-registers it (needed when the
  signature kind changes, and it replaces a running old helper); running
  mounts keep their ssh. If mounts fail after ~10 s with "Socket is not
  connected", the helper isn't starting: `SSHFS status`, `SSHFS register`.
- Put the command on your PATH:
  `ln -sf /Applications/SSHFS.app/Contents/MacOS/SSHFS ~/bin/sshfs`.
- The ad-hoc build with the helper is untested: whether `SMAppService`
  accepts an ad-hoc signed app is an open question. Reports welcome.

### Releases

Releases are built on GitHub, never uploaded from a local machine:

1. Set `MARKETING_VERSION` in `SSHFS.xcodeproj/project.pbxproj` (both
   configurations), commit, and push a matching tag: `git tag v0.2 &&
   git push origin v0.2`.
2. `.github/workflows/release.yml` runs on the `xcode-27` runner: it checks
   the tag against the version, runs `build-release.sh` (`INSTALL=0`),
   attests the zip's build provenance and creates a **draft** release with
   the zip, its SHA-256 and how to verify it
   (`gh attestation verify SSHFS.zip --repo OWNER/REPO`).
3. Download the draft's zip, install it, run `scripts/e2e.sh` against it,
   then publish the draft.

The workflow needs these secrets in the repository's `release` environment
(Settings → Environments; restrict it to `v*` tags and require a reviewer):

| Secret | Content |
|---|---|
| `DEVID_P12_BASE64` | Developer ID Application identity (key, certificate, Apple's G2 intermediate) as a base64 .p12 |
| `DEVID_P12_PASSWORD` | its password |
| `DEVID_PROFILE_BASE64` | the Developer ID provisioning profile for the extension, base64 |
| `ASC_KEY_ID`, `ASC_ISSUER_ID` | an App Store Connect API key for notarization (Developer role is enough) |
| `ASC_KEY_P8_BASE64` | that key's .p8 file, base64 |

Locally, `build-release.sh` does the same and installs the result; such
builds are for testing.

- `build-release.sh` signs with Developer ID, notarizes, staples and zips.
  The zip carries no extended attributes, so it survives plain `unzip`
  (with them, `unzip` leaves `._*` files in the bundle and macOS reports
  the app as "damaged" / `Killed: 9`); the script checks.
- Notarization takes minutes to half an hour; the script waits. Run it so
  that its exit status is seen (not `build-release.sh | tail`): after a
  failed notarization nothing usable is in `build/`.
- If Apple's servers are slow: `notarytool --wait` can fail on a status
  check although the upload was accepted (the script stops and removes its
  upload zip: run it again), and the first launch of a new build on
  another Mac can hang in `_dyld_start` for minutes while Gatekeeper's
  online check times out. Wait.
- `NOTARIZE=0` skips notarization, but such a build can't start the helper
  (so it can't mount): only useful to check signing.

## Signing

`com.apple.developer.fskit.fsmodule` is a restricted entitlement: enable
the FSKit Module capability on the extension's App ID (paid teams only;
self-service). The scripts read from `SIGNING_DIR` (default
`~/sshfs-signing`, outside git):

| File | Use |
|---|---|
| `SSHFS_fsmodule_dev.provisionprofile` | development profile for the extension (your registered Macs) |
| `SSHFS_fsmodule_devid.provisionprofile` | Developer ID profile for the extension (any Mac) |
| `asc.env` | `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH`: App Store Connect API key for notarization and `scripts/asc.py` |

- The Developer ID Application identity must be in the login keychain.
- The team ID and the bundle IDs (`com.joelmsmith.sshfs…`) are currently
  written into `Config/`, the scripts and the sources; to build under
  another team, change them everywhere (centralizing them is planned).
- Signing a restricted entitlement with a certificate the profile doesn't
  list makes AMFI kill the extension ("Restricted entitlements not
  validated"); `build-signed.sh` picks the right identity from the profile.
- The App Store Connect API can't create Developer ID certificates (Account
  Holder only, in the browser).
- `scripts/asc.py GET /v1/profiles` etc. is a minimal API client for
  profile and capability work.

## Tests

- **`scripts/e2e.sh`**: 76 checks against the installed app over loopback
  ssh: file operations, data integrity, writes to read-only files through
  an open descriptor (and `git clone`), descriptors whose name was
  unlinked or replaced, xattrs, refused metadata files,
  remote-change freshness (team-signed builds only), reconnect, ssh
  setups that need the helper (an agent socket under `~/Library`,
  `IdentityAgent`, `ProxyJump`, list-valued ssh options), and prompts
  (host key, passphrase, cancel, reconnect policy, keychain) answered by a
  script through `-o askpass=`. ~90 s. It never shows a dialog; the real
  dialogs can only be checked by a person. Run after every change; it must
  stay green.
- `scripts/test.sh`: SFTP package tests over pipes (`/usr/libexec/sftp-server`)
  and over loopback ssh.
- `Packages/SFTP`: `swift run sftp-bench host dir` measures SFTP latency.

### Test hosts

Enable Remote Login (System Settings → General → Sharing), then create two
keys and three host aliases in `~/.ssh/config`:

```sh
ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519_sshfs_loopback
ssh-keygen -t ed25519 -N agent-test-passphrase -f ~/.ssh/id_ed25519_sshfs_agenttest
cat ~/.ssh/id_ed25519_sshfs_loopback.pub ~/.ssh/id_ed25519_sshfs_agenttest.pub >> ~/.ssh/authorized_keys
```

```
# Loopback host for sshfs integration tests
Host sshfs-loopback
    HostName localhost
    HostKeyAlias localhost
    IdentityFile ~/.ssh/id_ed25519_sshfs_loopback
    IdentitiesOnly yes
    BatchMode yes

# Loopback host that is "down" while ~/.ssh/sshfs-flaky-down exists (reconnect tests)
Host sshfs-flaky
    HostName localhost
    HostKeyAlias localhost
    IdentityFile ~/.ssh/id_ed25519_sshfs_loopback
    IdentitiesOnly yes
    BatchMode yes
    ProxyCommand sh -c 'test -e $HOME/.ssh/sshfs-flaky-down && exit 1; exec nc %h %p'

# Loopback host reachable only with the passphrase key (agent and prompt tests)
Host sshfs-agenttest
    HostName localhost
    HostKeyAlias localhost
    IdentityFile ~/.ssh/id_ed25519_sshfs_agenttest.pub
    IdentitiesOnly yes
    BatchMode yes
```

e2e loads the passphrase key into a throwaway agent itself; the agent and
prompt checks are skipped without it. Accept the host key once
(`ssh sshfs-loopback true`).

### Debugging

- Kill the live connection:
  `pkill -f "ssh -x -a -o ClearAllForwardings.*<host> sftp"`.
- Logs (extension: category `fsmodule`, helper: category `helper`):
  `/usr/bin/log show --last 5m --info --predicate 'subsystem == "com.joelmsmith.sshfs"'`.
  Every file logs `closed PATH: N reads, …; N writes, …` at close (info
  level): shows what the kernel's cache absorbed.
- Kernel entitlement check: `log show --last 5m --predicate 'eventMessage CONTAINS "fsmodule_entitled"'`
- Sandbox denials: `log show --last 5m --predicate 'eventMessage CONTAINS "SSHFSExtension" AND eventMessage CONTAINS "deny"'`
- Why an extension wasn't loaded: `log show --predicate 'process == "pkd"'`.

## Gotchas

- The first time a terminal app touches a network volume macOS asks for
  consent, and until it's answered `open()` on the mount just hangs with
  the extension idle. Looks like a deadlock; isn't.
- Never seed test keychain items with `security add-generic-password`: the
  app's read then blocks on a system prompt. e2e stores them through the
  app (`SSHFS_ASKPASS_REMEMBER`, see App/Askpass.swift).
- Don't name a zsh variable `PROMPT`.
- Don't pipe a script that mounts into `head`: it dies of SIGPIPE before
  its cleanup and leaves mounts (and e2e's "no ssh left behind" fails).
- Sandboxed shells (e.g. coding agents') may fail to mount or unmount under
  their scratch directories in odd ways. Use `/private/tmp/...` as e2e does.
- In zsh, `log` is a builtin: use `/usr/bin/log`.
- Kernel caching hides bugs: a second `cat` is served from the page cache.
  Read files the kernel hasn't seen, or change them remotely first.
- SFTP mtimes have 1 s resolution: tests that change a directory twice in a
  second can look like misses (sleep 1.2 s between changes).
- Test directory freshness in a subdirectory: the volume root can't be
  invalidated.
- Inside the extension `~` is its container: use absolute paths in tests.
- A mount whose dirty data the server refuses won't unmount: `umount -f`.
- `umount` of a mount that lost its server needs the absolute path: with a
  relative one it says "not currently mounted" (it can't resolve the path
  through a mount that fails every call).
- SourceKit diagnostics in editors ("No such module 'SFTP'") are noise;
  trust `xcodebuild`.
- The project file is hand-written (`objectVersion` 77, synchronized folder
  groups): new files in `App/`, `Extension/`, `Shared/`, `Config/` are
  picked up automatically; `Shared/` belongs to both targets. A new target
  means editing `project.pbxproj` by hand.
- The app icon is `App/AppIcon.icon`, an Icon Composer file (`icon.json`
  plus SVG layers in `Assets/`); edit it in Icon Composer (inside Xcode.app)
  or by hand. `actool` renders the glass effect at build time.
- Don't close Finder windows with AppleScript (`close every window` closes
  all of the user's windows).
