//! Shared display drafts and the detached, bounded Hyprland display trial
//! (formerly `display_transaction.py`). See the contract in `main.rs`.

use std::ffi::OsString;
use std::fs::File;
use std::io::{self, Read as _};
use std::os::unix::fs::{MetadataExt as _, OpenOptionsExt as _};
use std::os::unix::process::CommandExt as _;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use foamy_helper::child::Bounded;
use foamy_helper::fs::{ensure_private_dir, read_file_limited, write_atomic};
use foamy_helper::lock::FileLock;
use serde_json::{Map, Value, json};
use sha2::{Digest as _, Sha256};

use crate::lua;
use crate::py;

type Monitor = Map<String, Value>;
type State = Map<String, Value>;

pub const ACTIONS: [&str; 8] = [
    "status",
    "patch",
    "discard",
    "apply",
    "keep",
    "revert",
    "worker",
    "gtk-scale",
];
const EDITABLE: [&str; 9] = [
    "width",
    "height",
    "refreshRate",
    "scale",
    "transform",
    "x",
    "y",
    "disabled",
    "mirrorOf",
];
const ACTIVE: [&str; 4] = ["applying", "testing", "saving", "reverting"];
/// Per run of a system tool, as before.
const TOOL_TIMEOUT: Duration = Duration::from_secs(5);
/// Bounds the old helper did not have: tool output, files read, a request.
const TOOL_OUTPUT: usize = 8 << 20;
const FILE_LIMIT: u64 = 16 << 20;
const REQUEST_LIMIT: usize = 1 << 20;
const TRIAL: Duration = Duration::from_secs(15);
const POLL: Duration = Duration::from_millis(150);

fn env_path(name: &str) -> Option<PathBuf> {
    std::env::var_os(name)
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
}

/// `$XDG_CONFIG_HOME/hypr/monitors.lua` (default `~/.config`).
fn config_path() -> PathBuf {
    let base = env_path("XDG_CONFIG_HOME")
        .or_else(|| std::env::home_dir().map(|home| home.join(".config")))
        .unwrap_or_else(|| PathBuf::from(".config"));
    base.join("hypr/monitors.lua")
}

/// A text file as Python's `Path.read_text()` returned it (symlinks
/// followed, UTF-8, newlines translated), at most 16 MiB; never blocks on a
/// FIFO.
fn read_text(path: &Path) -> Result<String, String> {
    let file = File::options()
        .read(true)
        .custom_flags(libc::O_NONBLOCK | libc::O_NOCTTY)
        .open(path)
        .map_err(|e| py::os_error(&e, path))?;
    let mut bytes = Vec::new();
    file.take(FILE_LIMIT + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| py::os_error(&e, path))?;
    if bytes.len() as u64 > FILE_LIMIT {
        return Err(format!("{} is larger than 16 MiB", path.display()));
    }
    let text = std::str::from_utf8(&bytes).map_err(|e| py::decode_error(&bytes, &e))?;
    Ok(py::universal_newlines(text))
}

fn command_repr(args: &[&str]) -> String {
    let items: Vec<String> = args.iter().map(|a| py::repr_str(a)).collect();
    format!("({})", items.join(", "))
}

/// display_transaction.run(): a tool's stripped standard output; a nonzero
/// exit is an error with its stripped stderr (or stdout).
fn run(args: &[&str]) -> Result<String, String> {
    let output = Bounded::new(args[0])
        .args(&args[1..])
        .timeout(TOOL_TIMEOUT)
        .max_output(TOOL_OUTPUT)
        .run()
        .map_err(|e| py::os_error(&e, Path::new(args[0])))?;
    if output.timed_out {
        return Err(format!(
            "Command '{}' timed out after {} seconds",
            command_repr(args),
            TOOL_TIMEOUT.as_secs()
        ));
    }
    if output.overflowed {
        return Err(format!("{} printed more than 8 MiB", args[0]));
    }
    let text = |bytes: &[u8]| py::universal_newlines(&String::from_utf8_lossy(bytes));
    let stdout = text(&output.stdout);
    if !output.status.success() {
        let stderr = text(&output.stderr);
        let chosen = if stderr.is_empty() { &stdout } else { &stderr };
        let message = py::strip(chosen);
        if !message.is_empty() {
            return Err(message.to_owned());
        }
        let code = output.status.code().unwrap_or_else(|| {
            use std::os::unix::process::ExitStatusExt as _;
            -output.status.signal().unwrap_or(0)
        });
        return Err(format!("{} failed ({code})", args[0]));
    }
    Ok(py::strip(&stdout).to_owned())
}

fn field<'a>(monitor: &'a Monitor, key: &str) -> Result<&'a Value, String> {
    monitor
        .get(key)
        .ok_or_else(|| format!("A display entry lacks {}", py::repr_str(key)))
}

fn get<'a>(map: &'a Map<String, Value>, key: &str) -> &'a Value {
    map.get(key).unwrap_or(&Value::Null)
}

fn id_key(monitor: &Monitor) -> String {
    match get(monitor, "id") {
        Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

fn monitors(value: &Value, what: &str) -> Result<Vec<Monitor>, String> {
    let list = value
        .as_array()
        .ok_or_else(|| format!("{what} is not a list of displays"))?;
    list.iter()
        .map(|m| {
            m.as_object()
                .cloned()
                .ok_or_else(|| format!("{what} holds an invalid display"))
        })
        .collect()
}

fn to_value(list: &[Monitor]) -> Value {
    Value::Array(list.iter().cloned().map(Value::Object).collect())
}

/// `^(\d+)x(\d+)@([\d.]+)Hz$` → (width, height, rate text).
fn parse_mode(text: &str) -> Option<(&str, &str, &str)> {
    let (size, rate) = text.strip_suffix("Hz")?.split_once('@')?;
    let (width, height) = size.split_once('x')?;
    let digits = |s: &str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit());
    let rate_ok = !rate.is_empty() && rate.bytes().all(|b| b.is_ascii_digit() || b == b'.');
    (digits(width) && digits(height) && rate_ok).then_some((width, height, rate))
}

fn parse_int(text: &str) -> Result<i64, String> {
    py::int(&Value::String(text.to_owned()))
}

fn parse_float(text: &str) -> Result<f64, String> {
    py::float(&Value::String(text.to_owned()))
}

fn number_value(x: f64) -> Value {
    serde_json::Number::from_f64(x).map_or(Value::Null, Value::Number)
}

/// The connected outputs (`hyprctl monitors all -j`) as display entries:
/// a stable `id`/`selector` (`desc:<description>` when unique, else the
/// connector), the mode snapped to an advertised one, a mirror source by
/// connector name, and disabled outputs' positions clamped to 0.
pub fn live_monitors() -> Result<Vec<Monitor>, String> {
    let text = run(&["hyprctl", "monitors", "all", "-j"])?;
    let rows: Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
    let rows = match rows {
        Value::Array(rows) if !rows.is_empty() => rows,
        _ => return Err("No connected displays".into()),
    };
    let rows: Vec<Monitor> = rows
        .into_iter()
        .map(|row| match row {
            Value::Object(row) => Ok(row),
            _ => Err("hyprctl returned an invalid display".to_owned()),
        })
        .collect::<Result<_, _>>()?;
    let description = |row: &Monitor| row.get("description").map_or(String::new(), py::to_str);
    let descriptions: Vec<String> = rows.iter().map(description).collect();
    let mut output_names: Vec<(String, Value)> = Vec::new();
    for row in &rows {
        output_names.push((py::to_str(field(row, "id")?), field(row, "name")?.clone()));
    }
    let mut result = Vec::new();
    for row in &rows {
        let description = description(row);
        let unique = !description.is_empty()
            && descriptions.iter().filter(|d| **d == description).count() == 1;
        let selector = if unique {
            Value::String(format!("desc:{description}"))
        } else {
            field(row, "name")?.clone()
        };
        let mut modes: Vec<(i64, i64, f64)> = Vec::new();
        if let Some(Value::Array(list)) = row.get("availableModes") {
            for text in list.iter().filter_map(Value::as_str) {
                if let Some((w, h, r)) = parse_mode(text) {
                    let mode = (parse_int(w)?, parse_int(h)?, parse_float(r)?);
                    if !modes.contains(&mode) {
                        modes.push(mode);
                    }
                }
            }
        }
        let (mut width, mut height) = (
            py::int(field(row, "width")?)?,
            py::int(field(row, "height")?)?,
        );
        let mut rate = py::float(field(row, "refreshRate")?)?;
        if width == 0 || height == 0 {
            (width, height, rate) = modes.first().copied().unwrap_or((0, 0, 60.0));
        }
        let mut closest: Option<f64> = None;
        for mode in modes.iter().filter(|m| (m.0, m.1) == (width, height)) {
            if closest.is_none_or(|best| (mode.2 - rate).abs() < (best - rate).abs()) {
                closest = Some(mode.2);
            }
        }
        rate = closest.unwrap_or(rate);
        let mut monitor = Monitor::new();
        for key in [
            "name",
            "make",
            "model",
            "serial",
            "scale",
            "transform",
            "disabled",
            "focused",
            "availableModes",
        ] {
            monitor.insert(key.into(), field(row, key)?.clone());
        }
        // Hyprland reports mirrorOf as a monitor ID, while hl.monitor takes a selector.
        let mirror = match row.get("mirrorOf") {
            None | Some(Value::Null) => String::new(),
            Some(Value::String(s)) if s == "none" || s.is_empty() => String::new(),
            Some(other) => {
                let id = py::to_str(other);
                match output_names.iter().find(|(key, _)| *key == id) {
                    Some((_, name)) => py::to_str(name),
                    None => id,
                }
            }
        };
        let disabled = py::truthy(field(row, "disabled")?);
        let (x, y) = (py::int(field(row, "x")?)?, py::int(field(row, "y")?)?);
        monitor.insert("id".into(), selector.clone());
        monitor.insert("selector".into(), selector);
        monitor.insert("description".into(), Value::String(description));
        monitor.insert("width".into(), width.into());
        monitor.insert("height".into(), height.into());
        monitor.insert("refreshRate".into(), number_value(rate));
        monitor.insert("connected".into(), true.into());
        monitor.insert("mirrorOf".into(), mirror.into());
        monitor.insert("x".into(), if disabled { x.max(0) } else { x }.into());
        monitor.insert("y".into(), if disabled { y.max(0) } else { y }.into());
        result.push(monitor);
    }
    Ok(result)
}

fn num(monitor: &Monitor, key: &str) -> Result<f64, String> {
    py::number(field(monitor, key)?).ok_or_else(|| format!("Display {key} must be a number"))
}

fn footprint(m: &Monitor) -> Result<(f64, f64), String> {
    let scale = num(m, "scale")?;
    let (w, h) = (
        (num(m, "width")? / scale).round_ties_even(),
        (num(m, "height")? / scale).round_ties_even(),
    );
    Ok(if num(m, "transform")?.rem_euclid(2.0) != 0.0 {
        (h, w)
    } else {
        (w, h)
    })
}

fn ids(list: &[Monitor]) -> std::collections::HashSet<String> {
    list.iter().map(id_key).collect()
}

fn enabled(m: &Monitor) -> bool {
    !py::truthy(get(m, "disabled")) && !py::truthy(get(m, "mirrorOf"))
}

/// The draft can be tried: the same displays, one enabled, advertised modes
/// (or unchanged ones), whole-pixel scales in 0.25..=8, an enabled
/// unmirrored mirror source, no overlap.
fn validate(monitors: &[Monitor], live: &[Monitor]) -> Result<(), String> {
    if ids(monitors) != ids(live) {
        return Err("Displays changed. Discard the draft and try again".into());
    }
    if !monitors.iter().any(enabled) {
        return Err("Keep at least one display enabled".into());
    }
    for (index, m) in monitors.iter().enumerate() {
        if py::truthy(field(m, "disabled")?) {
            continue;
        }
        let (width, height, rate) = (
            field(m, "width")?,
            field(m, "height")?,
            num(m, "refreshRate")?,
        );
        let mut advertised = false;
        for text in field(m, "availableModes")?.as_array().into_iter().flatten() {
            let Some((w, h, r)) = text.as_str().and_then(parse_mode) else {
                continue;
            };
            if py::eq(&parse_int(w)?.into(), width)
                && py::eq(&parse_int(h)?.into(), height)
                && (parse_float(r)? - rate).abs() < 0.02
            {
                advertised = true;
                break;
            }
        }
        if !advertised {
            let key = id_key(m);
            let original = live
                .iter()
                .find(|v| id_key(v) == key)
                .ok_or("Displays changed. Discard the draft and try again")?;
            for k in ["width", "height", "refreshRate"] {
                if !py::same(field(m, k)?, field(original, k)?) {
                    return Err(format!(
                        "Unsupported resolution or refresh rate for {}",
                        py::to_str(field(m, "name")?)
                    ));
                }
            }
        }
        let scale = num(m, "scale")?;
        let fractional = |v: f64| (v / scale - (v / scale).round_ties_even()).abs() > 0.001;
        if !(0.25..=8.0).contains(&scale)
            || fractional(num(m, "width")?)
            || fractional(num(m, "height")?)
        {
            return Err(format!(
                "Unsupported scale for {}",
                py::to_str(field(m, "name")?)
            ));
        }
        let mirror = field(m, "mirrorOf")?;
        if py::truthy(mirror) {
            // by_name: the last display with that name.
            let target = monitors
                .iter()
                .rposition(|t| py::eq(get(t, "name"), mirror));
            let ok = target.is_some_and(|t| {
                let target = &monitors[t];
                t != index
                    && !py::truthy(get(target, "disabled"))
                    && !py::truthy(get(target, "mirrorOf"))
            });
            if !ok {
                return Err("Choose an enabled, non-mirrored source display".into());
            }
        }
    }
    let extended: Vec<&Monitor> = monitors.iter().filter(|m| enabled(m)).collect();
    for (i, a) in extended.iter().enumerate() {
        let (aw, ah) = footprint(a)?;
        for b in &extended[i + 1..] {
            let (bw, bh) = footprint(b)?;
            let (ax, ay, bx, by) = (num(a, "x")?, num(a, "y")?, num(b, "x")?, num(b, "y")?);
            if ax < bx + bw && ax + aw > bx && ay < by + bh && ay + ah > by {
                return Err("Displays overlap. Adjust their arrangement".into());
            }
        }
    }
    Ok(())
}

/// The runtime state directory, `$XDG_RUNTIME_DIR/foamy-monitor-<16 hex of
/// sha256(HYPRLAND_INSTANCE_SIGNATURE or "default")>`, and its files.
struct Store {
    directory: PathBuf,
    path: PathBuf,
}

impl Store {
    fn open() -> Result<Store, String> {
        use std::os::unix::ffi::OsStrExt as _;
        let signature = std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE")
            .unwrap_or_else(|| OsString::from("default"));
        let digest = Sha256::digest(signature.as_bytes());
        let session: String = digest.iter().take(8).map(|b| format!("{b:02x}")).collect();
        let runtime = env_path("XDG_RUNTIME_DIR").unwrap_or_else(|| {
            PathBuf::from(format!("/tmp/foamy-{}", rustix::process::getuid().as_raw()))
        });
        let directory = runtime.join(format!("foamy-monitor-{session}"));
        ensure_private_dir(&directory).map_err(|e| e.to_string())?;
        let path = directory.join("state.json");
        Ok(Store { directory, path })
    }

    fn lock(&self, name: &str) -> Result<FileLock, String> {
        FileLock::exclusive(&self.directory.join(name)).map_err(|e| e.to_string())
    }

    fn read(&self) -> Result<State, String> {
        let bytes = match read_file_limited(&self.path, FILE_LIMIT) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                let default =
                    json!({"phase": "idle", "base": [], "draft": [], "error": "", "revision": 0});
                return Ok(default.as_object().cloned().unwrap_or_default());
            }
            Err(error) => return Err(error.to_string()),
        };
        let text = std::str::from_utf8(&bytes).map_err(|e| py::decode_error(&bytes, &e))?;
        match serde_json::from_str(&py::universal_newlines(text)).map_err(|e| e.to_string())? {
            Value::Object(state) => Ok(state),
            _ => Err(format!(
                "{} does not hold a state object",
                self.path.display()
            )),
        }
    }

    fn write(&self, state: &mut State) -> Result<(), String> {
        let revision = match get(state, "revision") {
            Value::Number(n) if n.is_f64() => number_value(n.as_f64().unwrap_or(0.0) + 1.0),
            Value::Number(n) => n.as_i64().map_or(Value::Null, |r| (r + 1).into()),
            Value::Null => 1.into(),
            Value::Bool(b) => (i64::from(*b) + 1).into(),
            _ => return Err("The state file's revision is not a number".into()),
        };
        state.insert("revision".into(), revision);
        let text = serde_json::to_vec(state).map_err(|e| e.to_string())?;
        write_atomic(&self.path, &text, 0o600).map_err(|e| e.to_string())
    }
}

fn phase(state: &State) -> String {
    py::to_str(get(state, "phase"))
}

fn active(state: &State) -> bool {
    ACTIVE.contains(&phase(state).as_str())
}

/// Polling keeps draft edits (fields where draft and base differ) and takes
/// every other field from the live outputs; a disconnected display with
/// edits stays, marked `connected: false`.
fn reconcile(state: &mut State, live: &[Monitor]) -> Result<(), String> {
    if active(state) {
        return Ok(());
    }
    let base = monitors(get(state, "base"), "The state's base")?;
    let draft = monitors(get(state, "draft"), "The state's draft")?;
    let last = |list: &[Monitor], key: &str| list.iter().rev().find(|m| id_key(m) == key).cloned();
    let (mut new_base, mut new_draft) = (Vec::new(), Vec::new());
    for monitor in live {
        let key = id_key(monitor);
        let old_base = last(&base, &key).unwrap_or_else(|| monitor.clone());
        let old_draft = last(&draft, &key).unwrap_or_else(|| monitor.clone());
        let (mut b, mut d) = (monitor.clone(), monitor.clone());
        for name in EDITABLE {
            let (ob, od) = (field(&old_base, name)?, field(&old_draft, name)?);
            if !py::same(ob, od) {
                b.insert(name.into(), ob.clone());
                d.insert(name.into(), od.clone());
            }
        }
        new_base.push(b);
        new_draft.push(d);
    }
    let connected = ids(live);
    let mut seen = std::collections::HashSet::new();
    for entry in &draft {
        let key = id_key(entry);
        if connected.contains(&key) || !seen.insert(key.clone()) {
            continue;
        }
        let d = last(&draft, &key).unwrap_or_default();
        let b =
            last(&base, &key).ok_or("The state's base and draft disagree; discard the draft")?;
        let mut edited = false;
        for name in EDITABLE {
            edited |= !py::same(field(&b, name)?, field(&d, name)?);
        }
        if edited {
            let (mut b, mut d) = (b, d);
            b.insert("connected".into(), false.into());
            d.insert("connected".into(), false.into());
            new_base.push(b);
            new_draft.push(d);
        }
    }
    state.insert("base".into(), to_value(&new_base));
    state.insert("draft".into(), to_value(&new_draft));
    Ok(())
}

/// Enables sources before mirrors and disables outputs last, in one
/// `hyprctl eval`.
fn apply(list: &[Monitor]) -> Result<(), String> {
    let mut ordered: Vec<&Monitor> = list.iter().collect();
    ordered.sort_by_key(|m| {
        (
            py::truthy(get(m, "disabled")),
            py::truthy(get(m, "mirrorOf")),
        )
    });
    let rules: Vec<String> = ordered
        .iter()
        .map(|m| lua::monitor_rule(m))
        .collect::<Result<_, _>>()?;
    let result = run(&["hyprctl", "eval", &rules.join("; ")])?;
    if result
        .get(..5)
        .is_some_and(|start| start.eq_ignore_ascii_case("error"))
    {
        return Err(result);
    }
    Ok(())
}

fn verify(expected: &[Monitor], actual: &[Monitor]) -> Result<bool, String> {
    for m in expected {
        let key = id_key(m);
        let Some(got) = actual.iter().rev().find(|a| id_key(a) == key) else {
            return Ok(false);
        };
        if !py::eq(get(got, "disabled"), field(m, "disabled")?) {
            return Ok(false);
        }
        if py::truthy(field(m, "disabled")?) {
            continue;
        }
        let mut fields = vec![
            "width",
            "height",
            "refreshRate",
            "scale",
            "transform",
            "mirrorOf",
        ];
        if !py::truthy(field(m, "mirrorOf")?) {
            fields.extend(["x", "y"]);
        }
        for k in fields {
            if !py::same(field(m, k)?, get(got, k)) {
                return Ok(false);
            }
        }
    }
    Ok(true)
}

fn wait_verified(expected: &[Monitor], seconds: u64) -> Result<(), String> {
    let deadline = Instant::now() + Duration::from_secs(seconds);
    while Instant::now() < deadline {
        if verify(expected, &live_monitors()?)? {
            return Ok(());
        }
        thread::sleep(POLL);
    }
    Err("The display did not accept these settings".into())
}

/// Restores the snapshot on the outputs still connected; when none of them
/// would be enabled, the built-in panel (or the first output) at 0x0, scale 1.
fn rollback(snapshot: &[Monitor]) -> Result<(), String> {
    let connected = live_monitors()?;
    let name_of = |key: &str| {
        connected
            .iter()
            .rev()
            .find(|m| id_key(m) == key)
            .map(|m| get(m, "name").clone())
    };
    let mut restore: Vec<Monitor> = Vec::new();
    for m in snapshot {
        if let Some(name) = name_of(&id_key(m)) {
            let mut m = m.clone();
            m.insert("name".into(), name);
            restore.push(m);
        }
    }
    // A disconnected source must not leave the remaining monitor disabled/mirrored.
    let available: Vec<Value> = restore.iter().map(|m| get(m, "name").clone()).collect();
    for m in &mut restore {
        let mirror = get(m, "mirrorOf").clone();
        if !available.iter().any(|name| py::eq(name, &mirror)) {
            m.insert("mirrorOf".into(), "".into());
        }
    }
    if !restore.iter().any(|m| !py::truthy(get(m, "disabled"))) {
        let internal = |m: &&Monitor| {
            let name = py::to_str(get(m, "name"));
            ["eDP-", "LVDS-", "DSI-"]
                .iter()
                .any(|p| name.starts_with(p))
        };
        let mut fallback = connected
            .iter()
            .find(internal)
            .unwrap_or(&connected[0])
            .clone();
        for (key, value) in [
            ("disabled", json!(false)),
            ("mirrorOf", json!("")),
            ("x", json!(0)),
            ("y", json!(0)),
            ("scale", json!(1)),
        ] {
            fallback.insert(key.into(), value);
        }
        restore = vec![fallback];
    }
    apply(&restore)?;
    wait_verified(&restore, 4)
}

fn reload_config(monitor_changes: bool) -> Result<(), String> {
    // GTK-only saves must not reapply unrelated monitor geometry.
    if monitor_changes {
        run(&["hyprctl", "reload"])
    } else {
        run(&["hyprctl", "reload", "config-only"])
    }
    .map(drop)
}

fn eval_gtk_scale(value: &Value) -> Result<(), String> {
    let source = format!(
        "hl.env(\"GDK_SCALE\", {})",
        lua::lua_string(&py::to_str(value))
    );
    let result = run(&["hyprctl", "eval", &source])?;
    if result
        .get(..5)
        .is_some_and(|start| start.eq_ignore_ascii_case("error"))
    {
        return Err(result);
    }
    Ok(())
}

fn apply_gtk_scale(value: &Value) -> Result<(), String> {
    eval_gtk_scale(value)?;
    run(&[
        "dbus-update-activation-environment",
        "--systemd",
        &format!("GDK_SCALE={}", py::to_str(value)),
    ])
    .map(drop)
}

fn restore_gtk_scale(value: &Value, environment: &Value) -> Result<(), String> {
    eval_gtk_scale(value)?;
    let previous = environment.as_str().unwrap_or("");
    run(&[
        "dbus-update-activation-environment",
        "--systemd",
        &format!("GDK_SCALE={previous}"),
    ])?;
    if environment.is_null() {
        run(&["systemctl", "--user", "unset-environment", "GDK_SCALE"])?;
    }
    Ok(())
}

fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

/// The mode bits of `path` (symlinks followed), as `stat().st_mode & 0o777`.
fn mode_of(path: &Path) -> Result<u32, String> {
    std::fs::metadata(path)
        .map(|m| m.mode() & 0o777)
        .map_err(|e| py::os_error(&e, path))
}

static CANCELLED: AtomicBool = AtomicBool::new(false);

extern "C" fn on_cancel(_: libc::c_int) {
    CANCELLED.store(true, Ordering::SeqCst);
}

/// SIGTERM and SIGINT end the trial early (and revert), as before.
fn trap_cancel() {
    // SAFETY: a zeroed sigaction is valid; the handler only stores to an
    // atomic, which is async-signal-safe. SA_RESTART keeps blocking calls
    // (reads, waits) from failing with EINTR; sleeps run to their end and
    // the loop checks the flag after each one.
    unsafe {
        let mut action: libc::sigaction = std::mem::zeroed();
        action.sa_sigaction = on_cancel as *const () as libc::sighandler_t;
        action.sa_flags = libc::SA_RESTART;
        libc::sigemptyset(&mut action.sa_mask);
        for signal in [libc::SIGTERM, libc::SIGINT] {
            libc::sigaction(signal, &action, std::ptr::null_mut());
        }
    }
}

/// The detached trial: apply, wait for Keep, Revert, a disconnect or the
/// 15 s deadline, then save or roll back.
fn worker(store: &Store, token: &str) -> Result<(), String> {
    let _trial = store.lock("trial.lock")?;
    let state = store.read()?;
    if !py::eq(get(&state, "token"), &Value::String(token.to_owned()))
        || phase(&state) != "applying"
    {
        return Ok(());
    }
    let snapshot = monitors(get(&state, "snapshot"), "The trial's snapshot")?;
    let proposed = monitors(get(&state, "draft"), "The trial's draft")?;
    let plan = Trial::of(&state);
    let Trial {
        config_before,
        config_after,
        gtk_value,
        monitor_changes,
        ..
    } = &plan;
    let monitor_changes = *monitor_changes;
    let gtk_changed = plan.gtk_changed();
    let config = config_path();
    let backup = store.directory.join("monitors.lua.backup");
    let mut applied_gtk = false;
    let mut wrote_config = false;
    trap_cancel();

    let trial = (|| -> Result<bool, String> {
        if monitor_changes {
            apply(&proposed)?;
            wait_verified(&proposed, 4)?;
        }
        if gtk_changed {
            // Runtime-only until Keep; mark first so partial failures also restore it.
            applied_gtk = true;
            apply_gtk_scale(gtk_value)?;
        }
        let deadline = Instant::now() + TRIAL;
        {
            let _lock = store.lock("state.lock")?;
            let mut state = store.read()?;
            state.insert("phase".into(), "testing".into());
            state.insert("deadline".into(), number_value(now() + TRIAL.as_secs_f64()));
            store.write(&mut state)?;
        }
        while Instant::now() < deadline && !CANCELLED.load(Ordering::SeqCst) {
            thread::sleep(POLL);
            let state = store.read()?;
            let decision = py::to_str(get(&state, "decision"));
            if get(&state, "decision").as_str() == Some("revert") {
                break;
            }
            if ids(&live_monitors()?) != ids(&snapshot) {
                return Err("A display was disconnected during the test".into());
            }
            if decision != "keep" || !get(&state, "decision").is_string() {
                continue;
            }
            if Instant::now() >= deadline {
                break;
            }
            wait_verified(&proposed, 1)?;
            if read_text(&config)? != *config_before {
                return Err("monitors.lua changed during the test; try again".into());
            }
            {
                let _lock = store.lock("state.lock")?;
                let mut state = store.read()?;
                state.insert("phase".into(), "saving".into());
                store.write(&mut state)?;
            }
            write_atomic(&backup, config_before.as_bytes(), 0o600).map_err(|e| e.to_string())?;
            write_atomic(&config, config_after.as_bytes(), mode_of(&config)?)
                .map_err(|e| e.to_string())?;
            wrote_config = true;
            reload_config(monitor_changes)?;
            let errors = run(&["hyprctl", "configerrors"])?;
            if !errors.is_empty() {
                return Err(errors);
            }
            wait_verified(&proposed, 4)?;
            let _lock = store.lock("state.lock")?;
            let mut state = store.read()?;
            state.insert("phase".into(), "idle".into());
            state.insert("base".into(), to_value(&proposed));
            state.insert("draft".into(), to_value(&proposed));
            state.insert("error".into(), "".into());
            state.insert("deadline".into(), 0.into());
            if gtk_changed {
                state.insert(
                    "gtkScale".into(),
                    json!({"base": gtk_value.clone(), "value": gtk_value.clone()}),
                );
            }
            store.write(&mut state)?;
            return Ok(true);
        }
        Ok(false)
    })();
    let mut reason = match trial {
        Ok(true) => return Ok(()),
        Ok(false) => String::new(),
        Err(error) => error,
    };

    {
        let _lock = store.lock("state.lock")?;
        let mut state = store.read()?;
        state.insert("phase".into(), "reverting".into());
        store.write(&mut state)?;
    }
    revert(
        &plan,
        &snapshot,
        wrote_config,
        applied_gtk,
        &backup,
        &mut reason,
    );
    let _lock = store.lock("state.lock")?;
    let mut state = store.read()?;
    end_trial(&mut state, &plan, &snapshot, &reason);
    store.write(&mut state)
}

/// What a trial changed and how to undo it, from its state.
struct Trial {
    config_before: String,
    config_after: String,
    gtk_base: Value,
    gtk_value: Value,
    environment_before: Value,
    monitor_changes: bool,
}

impl Trial {
    fn of(state: &State) -> Trial {
        let gtk = get(state, "gtkScale")
            .as_object()
            .cloned()
            .unwrap_or_default();
        Trial {
            config_before: py::to_str(get(state, "configBefore")),
            config_after: py::to_str(get(state, "configAfter")),
            gtk_base: get(&gtk, "base").clone(),
            gtk_value: get(&gtk, "value").clone(),
            environment_before: get(state, "gtkEnvironmentBefore").clone(),
            monitor_changes: state.get("monitorChanges").is_none_or(py::truthy),
        }
    }

    fn gtk_changed(&self) -> bool {
        !py::eq(&self.gtk_base, &self.gtk_value)
    }
}

/// The revert: monitors.lua back to configBefore if the trial wrote it and it
/// still holds what the trial wrote, the displays back to the snapshot, the
/// GTK scale back to its base. What failed is appended to `reason`.
fn revert(
    trial: &Trial,
    snapshot: &[Monitor],
    wrote_config: bool,
    applied_gtk: bool,
    backup: &Path,
    reason: &mut String,
) {
    let config = config_path();
    let restored = (|| -> Result<(), String> {
        if wrote_config {
            if read_text(&config)? == trial.config_after {
                write_atomic(&config, trial.config_before.as_bytes(), mode_of(&config)?)
                    .map_err(|e| e.to_string())?;
                reload_config(trial.monitor_changes)?;
            } else {
                reason.push_str(&format!(
                    " Configuration changed externally; its backup is in {}",
                    backup.display()
                ));
            }
        }
        if trial.monitor_changes {
            rollback(snapshot)?;
        }
        Ok(())
    })();
    if let Err(error) = restored {
        reason.push_str(&format!(" Could not restore displays: {error}"));
    }
    if applied_gtk && let Err(error) = restore_gtk_scale(&trial.gtk_base, &trial.environment_before)
    {
        reason.push_str(&format!(" Could not restore GTK scale: {error}"));
    }
}

/// The state after a revert: idle on the snapshot, with `reason` as its error.
fn end_trial(state: &mut State, trial: &Trial, snapshot: &[Monitor], reason: &str) {
    state.insert("phase".into(), "idle".into());
    state.insert("base".into(), to_value(snapshot));
    state.insert("draft".into(), to_value(snapshot));
    state.insert("error".into(), py::strip(reason).into());
    state.insert("deadline".into(), 0.into());
    if trial.gtk_changed() {
        state.insert(
            "gtkScale".into(),
            json!({"base": trial.gtk_base, "value": trial.gtk_base}),
        );
    }
}

/// Whether the trial's detached worker still runs: `workerPid` names a
/// process whose command line still holds this trial's `worker --token
/// <token>`. A pid that is gone has no /proc entry, a zombie has an empty
/// command line, and a recycled pid runs something else (the token is 128
/// random bits). Under qemu-user the emulator's own arguments come first, so
/// the three arguments are looked for anywhere in it.
fn worker_alive(state: &State) -> bool {
    let (Some(pid), Some(token)) = (
        get(state, "workerPid").as_u64(),
        get(state, "token").as_str(),
    ) else {
        return false;
    };
    let Ok(cmdline) = read_file_limited(Path::new(&format!("/proc/{pid}/cmdline")), 64 << 10)
    else {
        return false;
    };
    let args: Vec<&[u8]> = cmdline.split(|byte| *byte == 0).collect();
    args.windows(3)
        .any(|w| w[0] == b"worker" && w[1] == b"--token" && w[2] == token.as_bytes())
}

/// A trial whose worker died without reverting (SIGKILL, the OOM killer, a
/// crash) stayed active for good: the displays kept the trial settings and
/// every edit answered "already running". When the worker is gone and
/// trial.lock is free (the worker holds it from its start; the pid covers
/// the moment before it takes it), its revert runs here, under state.lock.
fn recover_dead_trial(store: &Store, state: &mut State) -> Result<(), String> {
    if !active(state) || worker_alive(state) {
        return Ok(());
    }
    let Some(_trial) =
        FileLock::try_exclusive(&store.directory.join("trial.lock")).map_err(|e| e.to_string())?
    else {
        return Ok(());
    };
    let mut trial = Trial::of(state);
    let mut problems = String::new();
    let snapshot =
        monitors(get(state, "snapshot"), "The trial's snapshot").unwrap_or_else(|error| {
            // Nothing to roll back to: the next status reads the outputs as they are.
            problems.push_str(&format!(" {error}"));
            trial.monitor_changes = false;
            Vec::new()
        });
    // The worker may or may not have written monitors.lua (it does on Keep):
    // restore it only while it holds exactly what the trial wrote.
    let config = read_text(&config_path()).unwrap_or_default();
    let wrote_config = trial.config_after != trial.config_before && config == trial.config_after;
    let backup = store.directory.join("monitors.lua.backup");
    revert(
        &trial,
        &snapshot,
        wrote_config,
        trial.gtk_changed(),
        &backup,
        &mut problems,
    );
    let reason = if problems.is_empty() {
        "The display test stopped unexpectedly. The previous settings were restored.".to_owned()
    } else {
        format!("The display test stopped unexpectedly.{problems}")
    };
    end_trial(state, &trial, &snapshot, &reason);
    store.write(state)
}

fn patch(state: &mut State, request: &Value) -> Result<(), String> {
    let invalid = || "Invalid display change".to_owned();
    let request = request.as_object().ok_or_else(invalid)?;
    let changes = get(request, "changes").as_object().ok_or_else(invalid)?;
    let wanted = get(request, "id").clone();
    let mut draft = monitors(get(state, "draft"), "The state's draft")?;
    let monitor = draft
        .iter_mut()
        .find(|m| py::eq(get(m, "id"), &wanted))
        .filter(|m| py::truthy(get(m, "connected")))
        .ok_or("Display is disconnected")?;
    for (key, value) in changes {
        if !EDITABLE.contains(&key.as_str()) {
            return Err("Unknown display setting".into());
        }
        let valid = match key.as_str() {
            "disabled" => value.is_boolean(),
            "mirrorOf" => value.as_str().is_some_and(|s| s.chars().count() < 256),
            _ => match value {
                Value::Number(n) => {
                    let v = n.as_f64().unwrap_or(f64::NAN);
                    let mut valid = v.is_finite();
                    if valid && key != "scale" && key != "refreshRate" {
                        valid = v.fract() == 0.0 && v.abs() < 100000.0;
                    }
                    if valid && key == "transform" {
                        valid = (0.0..=7.0).contains(&v);
                    }
                    if valid && ["scale", "refreshRate", "width", "height"].contains(&key.as_str())
                    {
                        valid = v > 0.0;
                    }
                    valid
                }
                _ => false,
            },
        };
        if !valid {
            return Err(format!("Invalid display setting: {key}"));
        }
        monitor.insert(key.clone(), value.clone());
    }
    if !draft
        .iter()
        .any(|m| py::truthy(get(m, "connected")) && enabled(m))
    {
        return Err("Keep at least one display enabled".into());
    }
    state.insert("draft".into(), to_value(&draft));
    state.insert("error".into(), "".into());
    Ok(())
}

fn token() -> Result<String, String> {
    let mut bytes = [0u8; 16];
    let mut filled = 0;
    while filled < bytes.len() {
        // SAFETY: getrandom writes at most the given length into the buffer.
        let got = unsafe {
            libc::getrandom(bytes[filled..].as_mut_ptr().cast(), bytes.len() - filled, 0)
        };
        if got < 0 {
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::Interrupted {
                return Err(error.to_string());
            }
        } else {
            filled += got as usize;
        }
    }
    // uuid4().hex
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

/// Starts this binary as `worker --token T` in a new session, with
/// /dev/null for its standard streams and no inherited descriptors, so it
/// outlives the caller (Quickshell kills the caller's process group).
fn spawn_worker(token: &str) -> Result<u32, String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let mut command = Command::new(&exe);
    command
        .args(["worker", "--token", token])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    // SAFETY: runs in the forked child before exec and only makes system
    // calls (setsid, close_range or fcntl); nothing allocates or locks.
    unsafe {
        command.pre_exec(|| {
            rustix::process::setsid()?;
            close_inherited();
            Ok(())
        });
    }
    command
        .spawn()
        .map(|child| child.id())
        .map_err(|e| py::os_error(&e, &exe))
}

/// close_fds: every descriptor above 2 closes on exec (std's own
/// error-report pipe included, which is close-on-exec already).
fn close_inherited() {
    const CLOSE_RANGE_CLOEXEC: libc::c_uint = 1 << 2;
    // SAFETY: close_range and fcntl only change descriptor flags.
    unsafe {
        if libc::syscall(
            libc::SYS_close_range,
            3 as libc::c_uint,
            libc::c_uint::MAX,
            CLOSE_RANGE_CLOEXEC,
        ) == 0
        {
            return;
        }
        let mut limit: libc::rlimit = std::mem::zeroed();
        let top = if libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) == 0 {
            limit.rlim_cur.min(65536) as libc::c_int
        } else {
            1024
        };
        for fd in 3..top {
            libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC);
        }
    }
}

fn read_request() -> Result<Value, String> {
    let mut line = Vec::new();
    let mut byte = [0u8; 1];
    let mut stdin = io::stdin().lock();
    loop {
        match stdin.read(&mut byte) {
            Ok(0) => break,
            Ok(_) => {
                line.push(byte[0]);
                if byte[0] == b'\n' {
                    break;
                }
                if line.len() > REQUEST_LIMIT {
                    return Err("The request is longer than 1 MiB".into());
                }
            }
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e.to_string()),
        }
    }
    let text = std::str::from_utf8(&line).map_err(|e| py::decode_error(&line, &e))?;
    serde_json::from_str(text).map_err(|e| e.to_string())
}

fn command(store: &Store, action: &str, request: &Value) -> Result<Value, String> {
    let _lock = store.lock("state.lock")?;
    let mut state = store.read()?;
    recover_dead_trial(store, &mut state)?;
    let previous = Value::Object(state.clone());
    let live = live_monitors()?;
    reconcile(&mut state, &live)?;
    let config = config_path();
    let (current_gtk, gtk_error) =
        match read_text(&config).and_then(|text| lua::gtk_scale_setting(&text)) {
            Ok((value, _)) => (Value::from(value), String::new()),
            Err(error) => (Value::Null, error),
        };
    let default_gtk = json!({"base": current_gtk, "value": current_gtk});
    let mut gtk = state
        .get("gtkScale")
        .cloned()
        .unwrap_or(default_gtk.clone());
    let side = |gtk: &Value, key: &str| gtk.get(key).cloned().unwrap_or(Value::Null);
    // Polling follows external edits only while this global setting is clean.
    if !active(&state) && py::eq(&side(&gtk, "base"), &side(&gtk, "value")) {
        gtk = default_gtk.clone();
    }
    state.insert("gtkScale".into(), gtk.clone());
    if ["patch", "discard", "apply", "gtk-scale"].contains(&action) && active(&state) {
        return Err("A display test is already running".into());
    }
    let request_get = |key: &str| request.get(key).cloned().unwrap_or(Value::Null);
    match action {
        "patch" => patch(&mut state, request)?,
        "gtk-scale" => {
            if !gtk_error.is_empty() {
                return Err(gtk_error);
            }
            let value = request_get("value");
            lua::update_gtk_scale(&read_text(&config)?, &value)?;
            let mut gtk = gtk
                .as_object()
                .cloned()
                .ok_or("The state's GTK scale is invalid")?;
            gtk.insert("value".into(), value);
            state.insert("gtkScale".into(), Value::Object(gtk));
            state.insert("error".into(), "".into());
        }
        "discard" => {
            state.insert("base".into(), to_value(&live));
            state.insert("draft".into(), to_value(&live));
            state.insert("error".into(), "".into());
            state.insert("gtkScale".into(), default_gtk);
        }
        "apply" => {
            let base = monitors(get(&state, "base"), "The state's base")?;
            let draft = monitors(get(&state, "draft"), "The state's draft")?;
            validate(&draft, &live)?;
            let mut edited = Vec::new();
            for (b, d) in base.iter().zip(&draft) {
                let key = id_key(b);
                let actual = live
                    .iter()
                    .rev()
                    .find(|m| id_key(m) == key)
                    .ok_or("Displays changed. Discard the draft and try again")?;
                let mut changed = false;
                for k in EDITABLE {
                    let differs = !py::same(field(b, k)?, field(d, k)?);
                    if differs && !py::same(field(b, k)?, field(actual, k)?) {
                        return Err(
                            "Display settings changed elsewhere. Discard the draft and try again"
                                .into(),
                        );
                    }
                    changed |= differs;
                }
                if changed {
                    edited.push(d.clone());
                }
            }
            let (gtk_base, gtk_value) = (side(&gtk, "base"), side(&gtk, "value"));
            let gtk_changed = !py::eq(&gtk_base, &gtk_value);
            if gtk_changed && (!gtk_error.is_empty() || !py::eq(&current_gtk, &gtk_base)) {
                return Err(if gtk_error.is_empty() {
                    "GTK scale changed elsewhere. Discard the draft and try again".into()
                } else {
                    gtk_error
                });
            }
            if edited.is_empty() && !gtk_changed {
                return Err("No unsaved changes".into());
            }
            if config
                .symlink_metadata()
                .is_ok_and(|m| m.file_type().is_symlink())
            {
                return Err("monitors.lua must be a machine-local file outside Stow".into());
            }
            let before = read_text(&config)?;
            if !run(&["hyprctl", "configerrors"])?.is_empty() {
                return Err("Fix Hyprland configuration errors before saving".into());
            }
            let token = token()?;
            let mut after = if edited.is_empty() {
                before.clone()
            } else {
                lua::update_config(&before, &edited, &draft, &base)?
            };
            if gtk_changed {
                after = lua::update_gtk_scale(&after, &gtk_value)?;
                let environment = run(&["systemctl", "--user", "show-environment"])?;
                let previous = py::splitlines(&environment)
                    .into_iter()
                    .find_map(|line| line.strip_prefix("GDK_SCALE="))
                    .map_or(Value::Null, |v| v.into());
                state.insert("gtkEnvironmentBefore".into(), previous);
            }
            state.insert("phase".into(), "applying".into());
            state.insert("token".into(), token.clone().into());
            state.insert("snapshot".into(), to_value(&live));
            state.insert("decision".into(), "".into());
            state.insert("error".into(), "".into());
            state.insert("configBefore".into(), before.into());
            state.insert("configAfter".into(), after.into());
            state.insert("monitorChanges".into(), (!edited.is_empty()).into());
            store.write(&mut state)?;
            match spawn_worker(&token) {
                Ok(pid) => {
                    state.insert("workerPid".into(), pid.into());
                }
                Err(error) => {
                    state.insert("phase".into(), "idle".into());
                    store.write(&mut state)?;
                    return Err(error);
                }
            }
        }
        "keep" | "revert" => {
            if phase(&state) != "testing" || !py::eq(&request_get("token"), get(&state, "token")) {
                return Err("This display test has ended".into());
            }
            state.insert("decision".into(), action.into());
        }
        _ => {}
    }
    if !py::eq(&Value::Object(state.clone()), &previous) {
        store.write(&mut state)?;
    }
    let mut shown = state.clone();
    for hidden in [
        "configBefore",
        "configAfter",
        "snapshot",
        "gtkEnvironmentBefore",
    ] {
        shown.remove(hidden);
    }
    let mut gtk = get(&state, "gtkScale")
        .as_object()
        .cloned()
        .ok_or("The state's GTK scale is invalid")?;
    gtk.insert("error".into(), gtk_error.into());
    Ok(json!({
        "ok": true,
        "state": shown,
        "live": to_value(&live),
        "gtkScale": gtk,
        // The shell watches this file instead of polling for trial and draft changes.
        "statePath": store.path.to_string_lossy(),
    }))
}

/// One display action (not the worker): the request (patch, keep, revert,
/// gtk-scale) is one JSON line on standard input.
pub fn run_action(action: &str) -> Result<Value, String> {
    let store = Store::open()?;
    let request = if ["patch", "keep", "revert", "gtk-scale"].contains(&action) {
        read_request()?
    } else {
        json!({})
    };
    command(&store, action, &request)
}

/// The detached trial worker.
pub fn run_worker(token: &str) -> Result<(), String> {
    let store = Store::open()?;
    worker(&store, token)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn monitor(value: Value) -> Monitor {
        value.as_object().cloned().unwrap()
    }

    #[test]
    fn modes_parse_like_the_old_pattern() {
        assert_eq!(
            parse_mode("1920x1080@60.00Hz"),
            Some(("1920", "1080", "60.00"))
        );
        for bad in [
            "1920x1080@60.00",
            "1920x@60Hz",
            "x1080@60Hz",
            "1920x1080@Hz",
            "1920x1080@6a0Hz",
            "1920 x1080@60Hz",
        ] {
            assert_eq!(parse_mode(bad), None, "{bad}");
        }
    }

    #[test]
    fn footprints_round_half_to_even_and_rotate() {
        let m = monitor(json!({"width": 2560, "height": 1600, "scale": 1.6, "transform": 1}));
        assert_eq!(footprint(&m).unwrap(), (1000.0, 1600.0));
        let m = monitor(json!({"width": 5, "height": 3, "scale": 2, "transform": 0}));
        assert_eq!(footprint(&m).unwrap(), (2.0, 2.0));
    }

    #[test]
    fn tokens_are_uuid4_hex() {
        let token = token().unwrap();
        assert_eq!(token.len(), 32);
        assert!(
            token
                .bytes()
                .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
        );
        assert_eq!(&token[12..13], "4");
        assert_ne!(token, super::token().unwrap());
    }
}
