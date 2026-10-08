# MacShack engineering notes

MacShack runs macOS games on iPhone and iPad: native arm64 builds are prepared and signed on the device, Intel builds
run under AArchX, and Valve's macOS Steam client runs inside the app (Big Picture).

- **NEVER pass `--remove-existing-content` to `xcrun devicectl device copy to` (or any devicectl command).** It wipes
  the app's entire data container on the device (every game, save, prepared build, log and setting), not just the file
  being copied. To replace a file on the device, copy it, then read it back to check; if it did not change, stop and ask.
  Any command that deletes on the user's device needs their yes first.
- Keep personal ids (team, bundle id, device ids, home-folder paths) out of tracked files: your signing goes in
  `Signing.local.xcconfig` (git-ignored), which overrides `Signing.xcconfig`.
- Read next: [README.md](README.md) (what it is, how to build), [CONTRIBUTING.md](CONTRIBUTING.md) (every check and
  the rules for changes), [docs/compat-playbook.md](docs/compat-playbook.md) (debugging a game),
  [docs/compat-status.md](docs/compat-status.md) (what runs).
