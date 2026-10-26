# XBPS Update Notifier for Noctalia

A plugin for the [Noctalia](https://github.com/noctalia-dev/noctalia) shell (v5) that
tells you when your **Void Linux** system can be updated. It checks XBPS for pending
updates in the background, shows how many there are in the bar, lists them in a panel,
sends a notification when new updates show up, and starts the upgrade in a terminal
with one click.

![XBPS Update Notifier](xbps-notify/thumbnail.webp)

_The picture is an illustration, not a screenshot._

## Features

- **Background checks without root**: `xbps-install -Mun` is a dry run of a full system
  upgrade; the repository index is fetched into memory and nothing is written to disk.
- **Bar widget**: a package icon with the number of pending updates. Its tooltip lists
  the packages (old → new version), the download size and the time of the last check.
- **Notifications**: new updates are announced right away. While you have not installed
  them, newer ones are announced at most every 6 hours (Void publishes updates many
  times a day), and a Noctalia restart (e.g. a new login) reminds you once. You can set
  a minimum number of updates for a notification or turn notifications off.
- **Update panel**: versions, descriptions and sizes of the pending updates, plus the
  new dependencies and removals of the same transaction, and how many packages are held
  back (`hold`).
- **One-click upgrade**: **Update system** opens a terminal running
  `sudo xbps-install -Su` (or `doas` / `pkexec`). The window stays open until you press
  Enter, and the plugin checks again as soon as the upgrade ends.
- **Knows XBPS quirks**: while `xbps` itself is outdated, XBPS refuses every other
  update; the plugin tells you so and updates `xbps` first.
- **Notices manual upgrades**: when the package database
  (`/var/db/xbps/pkgdb-*.plist`) changes, it checks again, so the count drops even if
  you upgraded from your own terminal.
- A control-center tile, IPC commands, and an English and Russian interface (with
  proper Russian plural forms).

## Requirements

- Void Linux (`xbps-install` and `xbps-query`, from the `xbps` package).
- Noctalia 5.0.0-beta.9 or newer (the plugin uses plugin API level 26).
- For the upgrade: `sudo`, `doas` or `pkexec`, and a terminal emulator (`$TERMINAL`, or
  the first one found: foot, alacritty, kitty, ...).

## Installation

### Option 1: add this repository as a plugin source

```sh
noctalia msg plugins source add xbps-notify git https://github.com/gluow3377/noctalia-xbps-notify
noctalia msg plugins enable gluow3377/xbps-notify
```

Later versions are installed with `noctalia msg plugins update xbps-notify`.

### Option 2: copy it by hand

```sh
git clone https://github.com/gluow3377/noctalia-xbps-notify
mkdir -p ~/.local/share/noctalia/plugins
cp -r noctalia-xbps-notify/xbps-notify ~/.local/share/noctalia/plugins/xbps-notify
noctalia msg plugins enable gluow3377/xbps-notify
```

Then add the widget under **Settings → Bar → Add Widget → XBPS Update Notifier**. The
first check runs within half a minute after Noctalia starts.

## Usage

| Action | Where | Effect |
| --- | --- | --- |
| Left click | bar widget | Open or close the update panel |
| Right click | bar widget | Check now and report the result in a notification |
| Middle click | bar widget | Widget settings |
| Refresh button | panel | Check now |
| **Update system** | panel | Open a terminal running the upgrade |

Toggle the panel from a keybind:

```sh
noctalia msg panel-toggle gluow3377/xbps-notify:panel
```

For example, in Niri: `Mod+U { spawn "noctalia" "msg" "panel-toggle" "gluow3377/xbps-notify:panel"; }`,
in Hyprland: `bind = $mainMod, U, exec, noctalia msg panel-toggle gluow3377/xbps-notify:panel`.

The control-center tile is added under **Settings → Control Center → Home Shortcuts**.

IPC commands:

```sh
noctalia msg plugin gluow3377/xbps-notify:service all check    # check now and report the result
noctalia msg plugin gluow3377/xbps-notify:service all update   # open a terminal running the upgrade
```

## Settings

**Settings → Plugins → XBPS Update Notifier** (the gear on the plugin's row):

| Setting | Default | What it does |
| --- | --- | --- |
| Check interval (minutes) | 60 | How often to check. Set to 0 to check only at startup, on request and after packages change. |
| Fetch a fresh repository index | on | The `-M` flag: download the repository index into memory on every check (a few MiB per repository). When off, only the local cache is read, which is as fresh as the last `xbps-install -S` run as root. |
| Notify about new updates | on | Notify when updates appear that were not announced before (at most every 6 hours while announced ones are still pending). |
| Minimum updates for a notification | 1 | Stay quiet while fewer updates are pending. |
| Ignored packages | none | Left out of the count and the notifications; `*` wildcards work, e.g. `linux*`. They are still upgraded; use `xbps-pkgdb -m hold <pkg>` to keep a package back. |
| Run the upgrade with | Auto | `sudo`, `doas` or `pkexec`; Auto picks the first one found. |
| Custom upgrade command | empty | (advanced) Replaces the built-in command; runs with `sh` in a terminal. |

The widget has its own settings: **Icon** and **Hide when up to date** (the widget still
shows up when a check fails).

## How it works

```
service (service.luau)
 ├─ on a timer, and after /var/db/xbps/pkgdb-*.plist changes:
 │    xbps-install -Mun  →  the upgrade plan (update / install / remove / hold)
 │    xbps-query -l      →  installed versions and descriptions
 ├─ publishes the result on noctalia.state  →  bar widget, panel, tile
 ├─ notifies about new updates
 └─ on "Update system": terminal → sudo xbps-install -Su → IPC "check after-update"
```

- When **no** repository can be reached, `xbps-install` still exits successfully with an
  empty plan. The plugin treats that as a failed check, never as "up to date".
- When a check fails, the last known list stays on screen with an explanation, and the
  check is retried after 5 minutes, then 10, 20, 40, but never less often than the
  regular interval. When XBPS prints a plan but reports a problem too (one mirror
  unreachable, not enough disk space), the list is shown with a warning.
- A check that has not come back after 2.5 minutes is abandoned, and checking carries on.
- The plugin writes no files and needs no root to check. It only starts `xbps-install`
  and `xbps-query`, plus a terminal with your upgrade command.

## Repository layout

- `xbps-notify/` – the plugin: `plugin.toml`, the Luau scripts, translations, the README
  shown in the Noctalia plugin store, the thumbnail, and a copy of the license (Noctalia
  installs only this directory).
- `catalog.toml` – the plugin source catalog Noctalia reads (needed for option 1 above).

## Versioning

The version follows `MAJOR.MINOR.PATCH`, the only format Noctalia accepts, and is set in
both `xbps-notify/plugin.toml` and `catalog.toml`. Noctalia offers an update when the
version in the catalog differs from the installed one, so every change bumps it in both
files: PATCH for fixes, MINOR for new features, MAJOR for changes that break existing
settings or behavior.

## License

Released under the [MIT License](LICENSE).
