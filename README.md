# Claude Code Session Manager

A native macOS app for browsing, sharing, and resuming
[Claude Code](https://claude.ai/code) sessions.

## Install

1. Download the latest `SessionManager.dmg` from
   [Releases](https://github.com/OwenCope/claude-code-session-manager/releases/latest).
2. Open the DMG and drag **Session Manager.app** into `/Applications`.
3. First launch only — macOS Gatekeeper will block the ad-hoc signature.
   In Terminal, paste:

   ```sh
   xattr -dr com.apple.quarantine "/Applications/Session Manager.app"
   ```

   Then double-click the app normally.

Future updates install with the in-app **Update** button, no quarantine
fix needed.

## Features

- Browse all Claude Code sessions across projects
- Multi-select with cmd-click / shift-click
- Resume a session in Terminal (`claude --resume <uuid>`)
- Share an importable session bundle (`.tar.gz`) via AirDrop, Messages, etc.
- Import a bundle from another Mac
- Rename, delete (move to private trash), reload
- Full chat-style transcript inspector
- Auto-update from GitHub Releases

## Build from source

Requires Swift 5.9+ on macOS 14+.

```sh
./build.sh
open dist/SessionManager.dmg
```

## Cut a release

```sh
./release.sh 1.0.1 "What's new"
```

Bumps version, rebuilds, pushes tag, uploads DMG to GitHub.
