# sshfs for macOS (FSKit)

An open sshfs replacement: an FSKit file system extension speaking SFTP over
the system `ssh`. No kernel extension, no macFUSE.

## Start here

- `docs/ARCHITECTURE.md`: how it works and the verified macOS facts.
- `docs/DEVELOPMENT.md`: build, sign, test, test hosts, gotchas. Read it
  before building: there are several ways to break the installed extension.

## Working rules

- Run `scripts/e2e.sh` after any change to the extension or app; it must
  stay green. SFTP package changes: `scripts/test.sh`.
- Remount after installing a build: a running mount keeps the old
  extension process.
- Keep ARCHITECTURE.md and DEVELOPMENT.md true: when your work changes a
  fact, edit the stale text rather than appending a contradiction.
- Signing material (profiles, keys, API credentials) never goes in git.
- Only a person can switch the extension on in System Settings or answer
  macOS privacy prompts. Ask, with exact steps.

## Layout

- `App/`: host app + `sshfs` CLI (`main.swift`), the ssh helper agent
  (`Helper.swift`) and askpass (`Askpass.swift`), all one binary.
- `Shared/`: compiled into both app and extension (helper XPC protocol,
  `-o` option parsing).
- `Extension/`: the FSKit module (see ARCHITECTURE.md for the parts).
- `Packages/SFTP/`: standalone pipelined SFTP v3 client with tests.
- `Config/`: Info.plists, entitlements (team-signed and ad-hoc), helper
  launchd plist.
- `scripts/`: build-{signed,release,adhoc}.sh, install.sh, e2e.sh, test.sh,
  asc.py (App Store Connect API).
- `.github/workflows/release.yml`: builds, notarizes and drafts a release
  for a pushed `v*` tag (DEVELOPMENT.md, "Releases").
- `SSHFS.xcodeproj`: hand-written; folders are synchronized groups.
