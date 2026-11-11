# Foamy Monitor

Display arrangement, safe display trials, brightness, scaling and wireless
casting for the Omarchy bar.

![The Foamy Monitor panel arranging three sample displays](preview.png)

## Install

```sh
omarchy plugin add https://github.com/foamrider/foamy-monitor.git --enable
```

Requires Omarchy 4.5. It replaces the stock Display widget (`omarchy.monitor`), so use one display
plugin at a time and disable any older local replacement.

Requires Hyprland, `gsettings` (cursor size) and Omarchy's
`omarchy-brightness-display` and `omarchy-display-text-size`. Brightness on
external displays goes through Omarchy's DDC helper (`ddcutil`). The display
and casting helper ships prebuilt for x86_64 and aarch64
(`bin/<arch>/foamy-monitor-helper`); on other CPUs the panel says the helper
isn't available.

Optional, for wireless casting: FluxCast (`fluxcast-git`) and FFmpeg
(`ffmpeg`).

## Use

- Left-click the widget to open the panel. Scroll on it to change the
  brightness of the display that bar is on; Omarchy's on-screen display shows
  the new level.
- **Display**: select a display in the diagram (or in the list below it for
  displays that are off, mirrored or disconnected), drag it into position, and
  set display mode, resolution, refresh rate, scale, orientation and
  brightness. **Identify** shows each display's name on it.
- **Advanced**: text size, cursor size and GTK scale.
- **Wireless**: find a receiver and cast the selected display. The search runs
  while the tab is open and stops when the panel closes; the Scan icon turns
  while it runs. Receivers it found are remembered for two minutes: reopening
  the panel shows them at once and refreshes the list in the background
  (receivers that are gone drop out when the refresh finishes). An older list
  is dropped and a new search starts.
- There are no plugin settings: the language follows Omarchy → Setup →
  Language.

**Save** starts a 15-second trial. Choose **Keep settings** to write
`~/.config/hypr/monitors.lua`, or **Revert** (or Esc) to restore the previous
configuration. The trial also reverts when it times out or a display is
unplugged. Brightness, text size and cursor size apply immediately.

### Keyboard

One cursor, shared with the pointer: arrows or `j`/`k` move it, `h`/`l` switch
tabs and step the brightness, Enter activates (and opens a dropdown), `m` on a
display in the diagram moves it with the arrow keys (10 px per press; Enter or
Esc to drop), `w` opens Wireless, `r` refreshes, Ctrl+S saves.
Tab and Shift+Tab move to the next bar panel. Esc reverts a running trial,
otherwise closes the panel.

### IPC

`omarchy-shell foamy.monitor <command>` (4.5) or `qs ipc call foamy.monitor
<command>`: `open`, `close`, `toggle` (`show` and `hide` are aliases),
`scanWireless` (opens the Wireless tab and searches), `stopWireless` (stops a
running cast), `status` (JSON; `state` is an alias), and `brightness <percent>`
for the focused display (`40`, `+5` or `-5`; it answers with an error when the
display has no brightness control).

## How it works

- One copy of the display state, brightness queue and FluxCast processes
  serves every bar (Omarchy 4.5 draws one bar per monitor).
- Nothing polls while the panel is closed. The display helper runs once at
  start, when another panel or the trial worker changes its state file, and
  on Hyprland output events (display added or removed, config reloaded). It
  refreshes every 5 seconds while a panel is open and every second during a
  trial.
- Brightness is read only for an open panel, the scroll wheel or IPC, and one
  `omarchy-brightness-display` call runs at a time, so DDC reads and writes
  never overlap on a bus.
- The wireless search runs only while an open panel shows the Wireless tab,
  one search at a time for every bar.
- FluxCast stops when the plugin is disabled or removed, when the shell
  reloads, and when its helper is killed (it runs with a parent-death signal).
- A display trial runs in its own detached process, so it still reverts on
  its timeout when the shell reloads or quits mid-trial.

### monitors.lua

Saving rewrites only literal `hl.monitor({ … })` rules (it refuses
conditional or computed configuration) and adds a rule for a display that has
none. External displays are saved by EDID description (`desc:…`), so they
keep their settings on another port. Built-in panels (`eDP`, `LVDS`, `DSI`)
are saved by connector name, which is what Omarchy's clamshell handling reads
to restore their scale and position. A display whose scale you did not change
keeps `scale = omarchy_monitor_scale`, so `omarchy hyprland monitor scaling`
and the stock scale buttons still reach it; a scale you pick in this panel is
saved as a number for that display.

Saving GTK scale updates `GDK_SCALE` in the Hyprland and D-Bus/systemd user
environments. The plugin uses `systemctl --user show-environment` to preserve
the previous value and `systemctl --user unset-environment GDK_SCALE` when a
rollback must restore an unset value. These operations affect the user session;
they do not manage system services or require administrator privileges.

## Language

Language follows **Omarchy → Setup → Language** on Omarchy 4.5 (English and
Norwegian catalogs; other languages fall back to English, and right-to-left
languages mirror the panel).

## Verifying the helper binaries

`bin/x86_64/foamy-monitor-helper` and `bin/aarch64/foamy-monitor-helper` are compiled from the Rust source in this repository: `native/`, the
shared crate in `kit/rust/`, the dependencies locked in `Cargo.lock` and the
toolchain pinned in `rust-toolchain.toml`, with the build tool in
`kit/native/`. The build is reproducible. `native/native.pin` records the
toolchain, a hash of every build input (`source`) and the SHA-256 of each
binary.

**CI.** The [Verify native helpers](https://github.com/foamrider/foamy-monitor/actions/workflows/verify-native.yml)
workflow rebuilds both binaries on a GitHub-hosted runner for every push,
compares them byte for byte with `bin/`, and attests the rebuilt files. To
check the committed files against that attestation (GitHub CLI):

```sh
gh attestation verify bin/x86_64/foamy-monitor-helper --repo foamrider/foamy-monitor \
  --signer-workflow foamrider/foamy-monitor/.github/workflows/verify-native.yml \
  --deny-self-hosted-runners
gh attestation verify bin/aarch64/foamy-monitor-helper --repo foamrider/foamy-monitor \
  --signer-workflow foamrider/foamy-monitor/.github/workflows/verify-native.yml \
  --deny-self-hosted-runners
```

Add `--source-digest <commit>` to require a particular commit.

**Yourself.** You need `rustup`, Python 3.11 or newer and `file`. From a
checkout of this repository at the commit you want to check:

```sh
rustup toolchain install "$(awk '$1 == "toolchain" { print $2 }' native/native.pin)" \
  --profile minimal --target x86_64-unknown-linux-musl,aarch64-unknown-linux-musl
kit/native/build-native.sh . --verify
```

It builds both binaries from scratch in `~/.cache/foamy-native/` (nothing is
written to the checkout), compares them byte for byte with `bin/`, checks
that the kit files are unmodified and that `native.pin` matches the source,
and ends with `verify OK (foamy-monitor-helper, <toolchain>, both arches reproducible)`.

### Building the helper yourself

To run binaries you built instead of the committed ones, build them in the
installed plugin with the same toolchain, then run `omarchy restart shell`:

```sh
cd ~/.config/omarchy/plugins/foamy.monitor
kit/native/build-native.sh .
```

The build is reproducible, so `git status` shows no change when your
binaries match the release, and `omarchy plugin update` still applies.

## Remove

Finish or revert any active display trial first.

```sh
omarchy plugin remove foamy.monitor
```

Removing or disabling the plugin stops a running cast. When removing an
enabled replacement, Omarchy restores `omarchy.monitor`. Saved display
layouts, brightness, font size, cursor size and GTK scale remain as last
configured; removal does not roll them back. FluxCast and FFmpeg remain
installed.

## Development

`kit/` holds shared components copied from [foamy-kit](https://github.com/foamrider/foamy-kit); edit them there, not here.

The helper is Rust (`native/`, one binary for the display transaction and
the FluxCast bridge; its contract is the comment at the top of
`native/src/main.rs`). The committed binaries are built reproducibly with
the build tool in `kit/native/` (needs rustup):

```sh
kit/native/build-native.sh . --test    # fmt, clippy, unit tests
kit/native/build-native.sh .           # bin/x86_64, bin/aarch64, native/native.pin
kit/native/build-native.sh . --verify  # clean rebuild, byte compare
```

Set `CARGO_TARGET_DIR` outside the plugin (e.g. `~/.cache/foamy-native/foamy-monitor`)
before running cargo yourself; the shell hot-reloads plugin folders.

```sh
node tests/model.test.js && node tests/i18n.test.cjs
python3 -I tests/test_display_transaction.py && python3 -I tests/test_fluxcast_bridge.py
python3 tests/runtime.py            # offscreen on the installed 4.5 shell (needs foamy-kit)
python3 tests/runtime-idle.py       # processes and CPU while every popup is closed
bash tests/kit-check.sh
```

The helper tests run this machine's `bin/<arch>/foamy-monitor-helper`;
`FOAMY_HELPER='["/abs/path/bin/aarch64/foamy-monitor-helper"]'` picks another
(aarch64 runs through qemu-user binfmt). They put only fake `hyprctl`,
`systemctl`, `dbus-update-activation-environment`, `fluxcast` and `ffmpeg`
on PATH, with temp HOME/XDG dirs; the runtime tests put fake `hyprctl`,
brightness and FluxCast commands first on PATH. Nothing reaches the live
session, the displays or a wireless receiver. The runtime tests use the foamy-kit
harness (`FOAMY_KIT`, default `~/GitHub/Personal/foamy-kit`).

## License

Licensed under [MIT](LICENSE), with [Monitor Settings Extender](LICENSE-MONITOR-SETTINGS-EXTENDER),
[Omarchy](LICENSE-OMARCHY), and [Lucide](LICENSE-LUCIDE) notices.

Provided **as is**, without warranty or guaranteed support. Use at your own risk.
