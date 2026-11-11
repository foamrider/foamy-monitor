//! `foamy-monitor-helper`: the display transaction and the FluxCast bridge
//! of Foamy Monitor (formerly `display_transaction.py` with
//! `display_config.py`, and `fluxcast_bridge.py`).
//!
//! # Contract
//!
//! `foamy-monitor-helper <action> [options]`; an unknown action or option
//! prints a usage error on standard error and exits 2 (nothing on standard
//! output).
//!
//! ## Display actions
//!
//! `status`, `patch`, `discard`, `apply`, `keep`, `revert`, `gtk-scale`
//! (each accepts `--token T`, which only the worker uses). `patch`, `keep`,
//! `revert` and `gtk-scale` read one JSON line from standard input (at most
//! 1 MiB): `{"id","changes":{…}}`, `{"token"}`, `{"token"}`, `{"value"}`.
//! Every action prints one JSON line: `{"ok":true,"state":{…},"live":[…],
//! "gtkScale":{"base","value","error"},"statePath":"…/state.json"}`, exit 0,
//! or `{"ok":false,"error":"<message>"}`, exit 1 (the old messages, word for
//! word: "A display test is already running", "No unsaved changes",
//! "Displays overlap. Adjust their arrangement", …).
//!
//! - State: `$XDG_RUNTIME_DIR/foamy-monitor-<first 16 hex of
//!   sha256($HYPRLAND_INSTANCE_SIGNATURE or "default")>/` (fallback
//!   `/tmp/foamy-<uid>`), mode 0700: `state.json` (0600, atomic rename;
//!   `phase` idle|applying|testing|saving|reverting, `base`, `draft`,
//!   `error`, `revision` +1 per write, `gtkScale`, and during a trial
//!   `token`, `decision`, `deadline` (epoch seconds), `snapshot`,
//!   `configBefore`, `configAfter`, `monitorChanges`,
//!   `gtkEnvironmentBefore`, `workerPid`; the first four of those trial
//!   fields are not shown in replies), `monitors.lua.backup` (0600, written
//!   before Keep saves), and the `flock` files `state.lock` (every action
//!   and worker step) and `trial.lock` (the worker).
//! - Displays: `hyprctl monitors all -j` (each tool run has a 5 s deadline,
//!   output capped at 8 MiB; a nonzero exit is an error with its stripped
//!   stderr, else stdout, else "<tool> failed (<code>)"). Entries get
//!   `id`/`selector` `desc:<description>` when the description is unique,
//!   else the connector; a mode snapped to the closest advertised rate;
//!   `mirrorOf` by connector; disabled outputs' x/y clamped to 0. Polls keep
//!   draft edits; a disconnected display with edits stays with
//!   `connected:false`.
//! - `patch` edits width, height, refreshRate, scale, transform (0..=7), x,
//!   y (whole numbers, |v| < 100000), disabled (bool), mirrorOf (string,
//!   < 256 characters). `gtk-scale` stages 1..=4 (an int).
//! - `monitors.lua` is `$XDG_CONFIG_HOME/hypr/monitors.lua` (default
//!   `~/.config`), read as text (symlinks followed, `\r\n`/`\r` read as
//!   `\n`, at most 16 MiB) and parsed literally: **user Lua is never
//!   evaluated**. Only standalone literal `hl.monitor({ … })` rules are
//!   rewritten (output, mode, position, scale, transform, disabled, mirror;
//!   other fields and comments kept) or appended; conditional or computed
//!   configuration, duplicate rules or fields and ambiguous descriptions
//!   are refused. External displays are saved by `desc:`, built-in panels
//!   (eDP, LVDS, DSI) by connector; a display whose scale did not change
//!   keeps `scale = omarchy_monitor_scale` when Omarchy's knob drives the
//!   catch-all rule. The GTK scale is one standalone `hl.env("GDK_SCALE",
//!   "<n>")` or `tostring(<local>)` of a single-use `local <name> = <n>`.
//! - `apply` refuses a symlinked monitors.lua and `hyprctl configerrors`
//!   output, stores the trial (phase applying, a uuid4-hex token) and
//!   starts the worker: this binary as `worker --token <token>` in a **new
//!   session**, standard streams on /dev/null and every inherited
//!   descriptor closed, so it outlives the caller (no parent-death signal).
//! - The worker (`trial.lock` held; nothing on standard output, exit 0; an
//!   error before the trial starts prints the JSON error, exit 1) applies
//!   the draft with one `hyprctl eval "hl.monitor({…}); …"` (sources, then
//!   mirrors, then disabled outputs), waits up to 4 s for `hyprctl
//!   monitors` to show it, applies a GTK scale with `hyprctl eval
//!   'hl.env("GDK_SCALE", "<n>")'` and `dbus-update-activation-environment
//!   --systemd GDK_SCALE=<n>`, then tests for 15 s (phase testing): every
//!   150 ms it reads the decision and the outputs; a disconnect, Revert,
//!   SIGTERM/SIGINT or the deadline reverts. Keep writes the backup and
//!   monitors.lua (atomic, its mode kept), runs `hyprctl reload` (`reload
//!   config-only` for a GTK-only change) and `hyprctl configerrors`, and
//!   checks the outputs again. Reverting restores monitors.lua if Keep had
//!   written it (and it is unchanged since), the snapshot through `hyprctl
//!   eval` (the built-in panel or first output when none would be enabled),
//!   the GTK scale and `GDK_SCALE` in the user environment (`systemctl
//!   --user unset-environment GDK_SCALE` when it was unset; the previous
//!   value came from `systemctl --user show-environment`).
//! - A worker that died without reverting (SIGKILL, a crash): every action
//!   first checks an active trial's `workerPid`. When /proc no longer shows
//!   that pid running `worker --token <token>` and `trial.lock` is free,
//!   the action runs the revert itself (monitors.lua only while it holds
//!   `configAfter`), goes idle with the error "The display test stopped
//!   unexpectedly. The previous settings were restored." and carries on.
//!
//! ## FluxCast bridge
//!
//! `check`; `scan [--timeout 1-30]` (default 8); `cast --peer MAC
//! --monitor NAME [--output-res 1920x1080] [--fps 1-120 (30)] [--bitrate
//! 4M] [--timeout 1-30 (8)]`. The bridge first traps SIGTERM/SIGINT and sets
//! `PR_SET_PDEATHSIG(SIGTERM)` (exit 0 at once if its parent is already
//! gone). FluxCast is `$FLUXCAST_BIN` (default `fluxcast`, found on `PATH`
//! like `shutil.which`); casting also needs `ffmpeg`.
//!
//! - `check` → `{"ok","missingPackages":["fluxcast-git"|"ffmpeg"…],
//!   "peers":[],"error":"Please install …"|""}`, exit 0.
//! - `scan` runs `fluxcast --wfd-scan --wfd-timeout N` and prints one line:
//!   `{"ok":true,"error":"","peers":[{"index","address" (upper case),
//!   "name","source","wfdCapable"}]}`, exit 0; `{"ok":false,"error":"Scan
//!   cancelled","peers":[]}`, exit 130, after a stop signal; the last
//!   "ERROR:" line (or "Wireless display scan failed") with FluxCast's exit
//!   status; the `check` reply for a missing package (exit 69).
//! - `cast` runs `fluxcast --protocol wfd --wfd-peer MAC --monitor NAME
//!   --output-res R --fps F --bitrate B --wfd-timeout T` and prints JSON
//!   lines `{"type":"phase","phase":"starting|scanning|connecting|waiting|
//!   casting|stopping|idle|error","detail"}` and finally
//!   `{"type":"exit","expected","code"}` (code: FluxCast's exit status, or
//!   minus the signal). Exit 0 after a stop signal or a clean end, else
//!   FluxCast's status; 2 for an invalid address; 69 for a missing package.
//! - FluxCast runs in its own session with standard output and error
//!   merged into one pipe (a scan keeps 4 MiB, a cast line 64 KiB),
//!   `PYTHONUNBUFFERED=1`, and `PR_SET_PDEATHSIG(SIGINT)`, its own cleanup
//!   path, for when Quickshell SIGKILLs the bridge. The first stop signal
//!   sends SIGINT to FluxCast; each later one SIGTERM to its process group.
//!
//! Helpers never exit 126 or 127 (the shell reads those as "no helper for
//! this CPU"): 127 for a missing package became 69, and a FluxCast status of
//! 126 or 127 is reported as 1. A panic exits 101.

use std::ffi::OsString;
use std::process::ExitCode;

use foamy_helper::json::{self, Failure};
use serde_json::{Value, json};

mod display;
mod fluxcast;
mod lua;
mod py;

const USAGE: &str = "usage: foamy-monitor-helper {status,patch,discard,apply,keep,revert,worker,gtk-scale} [--token TOKEN]\n       \
    foamy-monitor-helper {check,scan,cast} …";

fn usage(command: &str, message: &str) -> ExitCode {
    eprintln!("{USAGE}\nfoamy-monitor-helper {command}: error: {message}");
    ExitCode::from(2)
}

/// argparse-style long options: `--name value`, `--name=value` and unique
/// prefixes; a value may not look like an option (negative numbers may).
fn options(args: &[OsString], names: &[&str]) -> Result<Vec<(String, String)>, String> {
    let mut found = Vec::new();
    let mut i = 0;
    while i < args.len() {
        let arg = args[i].to_str().ok_or("arguments must be UTF-8")?;
        i += 1;
        let Some(option) = arg.strip_prefix("--").filter(|_| arg.len() > 2) else {
            return Err(format!("unrecognized arguments: {arg}"));
        };
        let (name, inline) = match option.split_once('=') {
            Some((name, value)) => (name, Some(value.to_owned())),
            None => (option, None),
        };
        let matches: Vec<&&str> = names.iter().filter(|n| n.starts_with(name)).collect();
        let name = match matches.as_slice() {
            [only] => **only,
            _ if names.contains(&name) => name,
            [] => return Err(format!("unrecognized arguments: {arg}")),
            _ => return Err(format!("ambiguous option: --{name}")),
        };
        let value = match inline {
            Some(value) => value,
            None => {
                let next = args.get(i).and_then(|v| v.to_str());
                let negative = |v: &str| {
                    v.strip_prefix('-').is_some_and(|n| {
                        !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit() || b == b'.')
                    })
                };
                match next {
                    Some(v) if !v.starts_with('-') || negative(v) => {
                        i += 1;
                        v.to_owned()
                    }
                    _ => return Err(format!("argument --{name}: expected one argument")),
                }
            }
        };
        found.push((name.to_owned(), value));
    }
    Ok(found)
}

fn option(found: &[(String, String)], name: &str) -> Option<String> {
    found
        .iter()
        .rev()
        .find(|(n, _)| n == name)
        .map(|(_, v)| v.clone())
}

fn bounded(
    found: &[(String, String)],
    name: &str,
    default: i64,
    range: std::ops::RangeInclusive<i64>,
) -> Result<i64, String> {
    let Some(text) = option(found, name) else {
        return Ok(default);
    };
    let value = py::int(&Value::String(text.clone())).map_err(|_| {
        format!(
            "argument --{name}: invalid int value: {}",
            py::repr_str(&text)
        )
    })?;
    if !range.contains(&value) {
        return Err(format!(
            "argument --{name}: invalid choice: {value} (choose from {}-{})",
            range.start(),
            range.end()
        ));
    }
    Ok(value)
}

fn display_main(action: &str, rest: &[OsString]) -> ExitCode {
    let found = match options(rest, &["token"]) {
        Ok(found) => found,
        Err(message) => return usage(action, &message),
    };
    if action == "worker" {
        let token = option(&found, "token").unwrap_or_default();
        return match display::run_worker(&token) {
            Ok(()) => ExitCode::SUCCESS,
            Err(error) => {
                let _ = json::print_line(&json!({"ok": false, "error": error}));
                ExitCode::from(1)
            }
        };
    }
    json::run(
        || display::run_action(action).map_err(Failure::new),
        |failure: &Failure| json!({"ok": false, "error": failure.message}),
    )
}

enum Bridge {
    Check,
    Scan(fluxcast::ScanArgs),
    Cast(fluxcast::CastArgs),
}

fn bridge_args(command: &str, rest: &[OsString]) -> Result<Bridge, String> {
    let names: &[&str] = match command {
        "check" => &[],
        "scan" => &["timeout"],
        _ => &["peer", "monitor", "output-res", "fps", "bitrate", "timeout"],
    };
    let found = options(rest, names)?;
    match command {
        "check" => Ok(Bridge::Check),
        "scan" => Ok(Bridge::Scan(fluxcast::ScanArgs {
            timeout: bounded(&found, "timeout", 8, 1..=30)?,
        })),
        _ => {
            let missing: Vec<String> = ["peer", "monitor"]
                .iter()
                .filter(|n| option(&found, n).is_none())
                .map(|n| format!("--{n}"))
                .collect();
            if !missing.is_empty() {
                return Err(format!(
                    "the following arguments are required: {}",
                    missing.join(", ")
                ));
            }
            Ok(Bridge::Cast(fluxcast::CastArgs {
                peer: option(&found, "peer").unwrap_or_default(),
                monitor: option(&found, "monitor").unwrap_or_default(),
                output_res: option(&found, "output-res").unwrap_or_else(|| "1920x1080".into()),
                fps: bounded(&found, "fps", 30, 1..=120)?,
                bitrate: option(&found, "bitrate").unwrap_or_else(|| "4M".into()),
                timeout: bounded(&found, "timeout", 8, 1..=30)?,
            }))
        }
    }
}

fn fluxcast_main(command: &str, rest: &[OsString]) -> ExitCode {
    let Some(stops) = fluxcast::prepare() else {
        return ExitCode::SUCCESS;
    };
    let code = match bridge_args(command, rest) {
        Err(message) => return usage(command, &message),
        Ok(Bridge::Check) => fluxcast::check(),
        Ok(Bridge::Scan(args)) => fluxcast::scan(&args, stops),
        Ok(Bridge::Cast(args)) => fluxcast::cast(&args, stops),
    };
    ExitCode::from(code)
}

fn main() -> ExitCode {
    foamy_helper::process::exit_on_panic(101);
    let args: Vec<OsString> = std::env::args_os().skip(1).collect();
    let Some(action) = args.first().and_then(|a| a.to_str()).map(str::to_owned) else {
        return usage("", "the following arguments are required: action");
    };
    if display::ACTIONS.contains(&action.as_str()) {
        display_main(&action, &args[1..])
    } else if ["check", "scan", "cast"].contains(&action.as_str()) {
        fluxcast_main(&action, &args[1..])
    } else {
        usage(
            &action,
            &format!("invalid choice: {}", py::repr_str(&action)),
        )
    }
}
