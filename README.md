# Awake

Keeps a MacBook running with its lid closed while Claude Code, Codex or T3 Code works,
and lets it sleep normally otherwise. Requires macOS 26 or later. The release
supports Apple Silicon and Intel Macs.

## Install

Download `Awake-<version>.dmg` from the
[latest release](https://github.com/theyluvEnething/awake/releases/latest),
drag Awake to Applications and open it there. Click **Set Up Awake** and allow
its helper in System Settings > General > Login Items & Extensions. Trust its
hooks once with `/hooks` in Codex.

Setup installs a root helper and two login items: the menu app and a check every
30 seconds. It adds its hooks to `~/.codex/hooks.json` beside your own. Claude
Code's hooks are copied for you to add to `~/.claude/settings.json`, or to
`/Library/Application Support/ClaudeCode/managed-settings.json` when managed
settings allow only managed hooks. The latter requires an administrator.

Awake checks for updates after launch and every six hours. Automatic updates
download quietly and install when you quit; Settings also offers **Restart to
update**. Turn off **Automatic updates** to use only **Check for updates**.
The version and check result appear in Settings. Updates verify both the signed
feed and archive before installation. Your settings and hooks stay in place.
For a manual download, quit the menu app before replacing `/Applications/Awake.app`.
**Uninstall Awake…** in Settings > App restores lid sleep, removes the helper, login
items, Codex hooks, state and log, then moves the app to the Trash.

## Use

Claude Code and Codex hooks mark each session as working from a prompt or tool
call until its turn ends. Lid sleep returns one minute after the last turn
finishes. If the lid is already closed, Awake requests sleep. A session that
sends no hook for 15 minutes, or whose agent process has exited, no longer counts.

T3 Code's local active turns are detected automatically while its server runs.
Awake reads T3's session state without changing its settings or database. Turns
waiting for approval or user input, completed turns and provider errors no longer
count. A running turn is checked every five seconds and gets the same one-minute
grace period when it ends. T3 0.0.45's session format is supported; Settings shows
when monitoring is unavailable. Remote environments are not monitored by the Mac.

The menu-bar cup shows what closing the lid does: an outline cup sleeps, a
filled cup keeps running, and a badge means lid sleep was changed outside Awake
or its helper needs setup.

- **Awake** keeps the Mac running with its lid closed while Claude or Codex works.
  Unticked, the mode is Off.
- **Settings…** groups wake controls, Activity and app maintenance.
  **Stay awake indefinitely** keeps it running until you turn it off, restart
  or log out.
- **Keep display on** in the cup menu and Settings prevents idle screen dimming and display sleep,
  including while the lid mode is Off. It has no timer: turn it off or quit Awake
  to restore normal display sleep.

Awake releases its holds at 20% battery unless charging, until the battery
recovers above 25%. It also releases them at 40 °C battery temperature, until
below 36 °C, and at high or critical thermal state. With the lid closed on
battery it switches to Low Power and restores your energy mode afterwards.
The display option follows the same battery and heat guards. It uses a temporary
macOS assertion and does not change your display settings. Power changes are logged to
`~/Library/Logs/awake.log`.

Settings > Activity graphs battery level, battery temperature and thermal state
over time. **Open in separate window** shows a larger, resizable activity monitor
with one-hour, six-hour, one-day and seven-day ranges, values at recorded moments,
minimum/maximum values and access to the text log. Awake records once a minute and
keeps seven days locally across restarts. Gaps during sleep and unavailable sensors
remain gaps. Uninstall removes this history with the rest of Awake's state.

## Command line

Add this repository's `bin/` directory to PATH, or call
`/Applications/Awake.app/Contents/MacOS/awake` directly.

| Command | Description |
| --- | --- |
| `awake run -- <command>` | Keep the Mac running while the command runs; pass through Ctrl-C and its exit code. |
| `awake for 90m` | Keep it running for a duration, such as `90s`, `2h` or `1h30m`. |
| `awake stop` | End every `run` and `for` hold. |
| `awake set off\|auto\|on` | Choose Off, Awake or Stay awake indefinitely. |
| `awake status` | Show mode, lid sleep, holds, battery, thermal state and Low Power. |

## Distribution and permissions

Lid-closed operation on an undocked Apple Silicon Mac uses the kernel's
`SleepDisabled` setting through `pmset -a disablesleep`. This disables other
forms of system sleep too. Idle-sleep assertions alone cannot provide this
behavior.

The root helper accepts only Awake clients signed by the same development team.
It runs fixed `pmset -a disablesleep 0|1` and `pmset -b powermode 0|1|2`
commands. At startup it restores lid sleep, and does the same when the helper
is disabled or the app is removed.

Awake is distributed outside the Mac App Store with Developer ID signing and
Apple notarization. [App Review guideline 2.4.5](https://developer.apple.com/app-store/review/guidelines/#hardware-compatibility)
requires sandboxing and prohibits escalation to root privileges. The current
lid-closed feature needs this helper, so this edition cannot be submitted under
those requirements. Notarization is separate from App Review.

## Build and release

Use Xcode 27 or later with Swift 6.4 or later. The app targets macOS 26.

```sh
swift test --package-path . --scratch-path build
xcodebuild -project Awake.xcodeproj -scheme Awake -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build/Xcode \
  CODE_SIGNING_ALLOWED=NO build
```

`./release.sh` builds both universal binaries, checks their signatures and
bundled resources, notarizes and staples the app, then creates and verifies a
signed, notarized DMG. Outputs are in `dist/`, including the stapled app's update
ZIP, signed `appcast.xml`, Homebrew cask and `SHA256SUMS`. Publish all four assets
and the checksums on the same GitHub release. It replaces that output directory on each run.

The script uses the keychain's Developer ID Application identity for team
`KSF29ZC99W` and the notarytool keychain profile `notary`.
`AWAKE_TEAM_ID`, `AWAKE_SIGN_IDENTITY` and `AWAKE_NOTARY_PROFILE` override these.
To use an existing App Store Connect API key directly, set `AWAKE_NOTARY_KEY_PATH`
and `AWAKE_NOTARY_KEY_ID`, plus `AWAKE_NOTARY_ISSUER` for a team key. Keep the key outside the repository.
Set `AWAKE_SPARKLE_BIN` to the official Sparkle 2.10.0 release's `bin` directory.
The update-signing key lives in Keychain under account `io.github.theyluvenething.awake`;
`AWAKE_UPDATE_KEY_ACCOUNT` overrides the account. The script rejects a mismatched key.
`./release.sh --skip-notarize` makes a clearly named check build without a cask.

Awake was extracted from [toybox](https://github.com/theyluvEnething/toybox),
with its source history and MIT license preserved.
