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
- The Markdown viewer and the agent session web panel (Markdown files open as
  plain text)
- The sudo approval helper (`cmux sudo`) and its Touch ID setup script
- `cmux codex-teams` and `cmux omo`, which started agent servers on a
  loopback TCP port without authentication
- The AppleScript interface

Changed:

- Git commands run by the app are restricted to operations that cannot
  contact a remote
- The remaining HTTP and WebSocket clients accept loopback addresses only
- Camera, microphone, contacts, calendar, reminders, photos, location,
  Bluetooth, speech, and motion permission declarations and entitlements were
  removed
- The release app is named `comux` with bundle identifier `com.comux.app`
- Builds target Apple silicon (arm64) only

## Security hardening

comux runs things automatically in whatever directory a terminal is in, and
it reacts to what programs print. These changes stop an untrusted directory,
file, or program output from making comux run code or leak data:

- Every `git` command comux runs forces `core.fsmonitor=false`,
  `core.hooksPath=/dev/null`, `safe.bareRepository=explicit`, and resets
  `safe.directory`, and disables filter drivers defined by the repository, so
  a crafted `.git/config` cannot execute anything. `git` is always
  `/usr/bin/git`, never looked up through `PATH`.
- Shell integration drops any status report that contains a control
  character, so a directory name or `.git/HEAD` with a line break cannot
  inject commands into the control socket. Ghostty's zsh integration prints
  the working directory raw (GHSA-2r63-vmw6-3m3c).
- The control socket only accepts commands that report status or manage
  layout from processes in a terminal. Typing into or reading other
  terminals, starting commands, answering agent permission prompts, and
  persisting automations are refused, so a prompt-injected agent cannot use
  comux to escape its own sandbox. The socket file is always private to the
  owner.
- OSC 52 clipboard reads are denied. Pasting text with line breaks into a
  program that does not use bracketed paste asks first. Text dropped onto a
  terminal has its line breaks turned into spaces.
- Links and files are only opened with their default application when they
  are web or mail links, or plain documents. Scripts, executables, app
  bundles, `.terminal`, `.webloc` and similar files are shown in Finder
  instead; other URL schemes ask first. Opening a script with comux asks
  before running it.
- A project's `cmux.json` can no longer register agent resume commands.
- The Codex wrapper no longer passes `--dangerously-bypass-hook-trust`.
- The command palette only loads its native library from the app bundle.
  UI-test launch manifests are ignored in release builds.
- The event log and workstream journal are private to the owner.

## Building

See [`build.sh`](build.sh).
