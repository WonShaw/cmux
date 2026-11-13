# comux: modification notice

comux is a modified version of [cmux](https://github.com/manaflow-ai/cmux),
based on the upstream tag `v0.64.25`. It is not the official cmux and is not
affiliated with or endorsed by Manaflow, Inc.

- Modified by: WonShaw (https://github.com/WonShaw/cmux)
- Modifications began: 2026-11-13
- Branch: `offline/0.64.25`

## License

comux is distributed under the same license as cmux, the GNU General Public
License v3.0 or later (GPL-3.0-or-later). See [`LICENSE`](../LICENSE) for the
full text and [`THIRD_PARTY_LICENSES.md`](../THIRD_PARTY_LICENSES.md) for the
notices of bundled third-party material. Copyright in the original work remains
with Manaflow, Inc. and the other cmux contributors.

The complete corresponding source for a comux build is this repository at the
commit the build was made from.

## What was changed

Why: upstream cmux contacts the network on its own (update checks, telemetry,
peer-to-peer connectivity, GitHub API calls made with the user's token). That
is not malicious, but it is unwanted in environments where unexpected outbound
traffic raises alerts. comux is meant to be a plain terminal that makes no
outbound network requests of its own. Programs that the user runs inside the
terminal are not restricted.

Removed:

- Automatic update checks and downloads (Sparkle)
- Crash reporting and analytics (Sentry, PostHog), remote feature flags, and
  in-app feedback submission
- iPhone pairing, peer-to-peer transport (iroh), presence, and push
- cmux Cloud, the WireGuard tunnel extension, and cmux-tui
- Account sign-in and billing
- GitHub pull request polling and all use of `gh` or GitHub tokens
- `cmux ssh`, remote workspaces, and the remote daemon
- The built-in browser panel
- The diff viewer and review comments
- The computer-use MCP helper
- The iOS app, the website, and backend services

Changed:

- Git commands run by the app are restricted to operations that cannot
  contact a remote
- The remaining HTTP and WebSocket clients accept loopback addresses only
- Camera, microphone, contacts, calendar, reminders, photos, location,
  Bluetooth, speech, and motion permission declarations were removed
- The release app is named `comux` with bundle identifier `com.comux.app`
- Builds target Apple silicon (arm64) only

## Building

See [`build.sh`](build.sh).
