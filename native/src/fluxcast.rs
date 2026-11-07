//! The structured, lifecycle-safe bridge between Quickshell and FluxCast
//! (formerly `fluxcast_bridge.py`). See the contract in `main.rs`.

use std::ffi::OsString;
use std::io::{self, PipeReader, Read as _, Write as _};
use std::os::fd::{AsFd as _, IntoRawFd as _};
use std::os::unix::process::{CommandExt as _, ExitStatusExt as _};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus};
use std::sync::atomic::{AtomicI32, Ordering};
use std::time::Duration;

use rustix::event::{PollFd, PollFlags, Timespec, poll};
use rustix::fs::{Access, access};
use rustix::process::{
    Pid, Signal, getpid, getppid, kill_process, kill_process_group, set_parent_process_death_signal,
};
use serde_json::{Value, json};

use crate::py;

/// Exit status for "a package is missing" (127 before: helpers never exit
/// 126 or 127, which mean "no helper for this CPU" to the shell).
pub const MISSING: u8 = 69;
/// The scan's output kept for parsing; more is read and dropped.
const SCAN_OUTPUT: usize = 4 << 20;
/// A longer cast log line is cut here (the rest of the line is dropped).
const LINE_LIMIT: usize = 64 << 10;

fn emit(payload: &Value) {
    let mut line = serde_json::to_string(payload).unwrap_or_default();
    line.push('\n');
    let mut stdout = io::stdout().lock();
    let _ = stdout.write_all(line.as_bytes());
    let _ = stdout.flush();
}

/// The write end of the self-pipe the signal handler wakes the loop with.
static WAKE: AtomicI32 = AtomicI32::new(-1);

extern "C" fn on_stop(_: libc::c_int) {
    let fd = WAKE.load(Ordering::SeqCst);
    if fd >= 0 {
        let byte = 1u8;
        // SAFETY: write(2) is async-signal-safe; the descriptor is a
        // non-blocking pipe this process keeps open for its lifetime.
        unsafe {
            libc::write(fd, (&raw const byte).cast(), 1);
        }
    }
}

/// SIGTERM and SIGINT stop the child (one byte per signal on the returned
/// pipe, so the main loop handles each one, as the old handler did).
fn trap_stop() -> io::Result<PipeReader> {
    let (reader, writer) = io::pipe()?;
    rustix::fs::fcntl_setfl(&writer, rustix::fs::OFlags::NONBLOCK)?;
    rustix::fs::fcntl_setfl(&reader, rustix::fs::OFlags::NONBLOCK)?;
    WAKE.store(writer.into_raw_fd(), Ordering::SeqCst);
    // SAFETY: a zeroed sigaction is valid; the handler only reads an atomic
    // and calls write(2). SA_RESTART keeps reads and waits going.
    unsafe {
        let mut action: libc::sigaction = std::mem::zeroed();
        action.sa_sigaction = on_stop as *const () as libc::sighandler_t;
        action.sa_flags = libc::SA_RESTART;
        libc::sigemptyset(&mut action.sa_mask);
        for signal in [libc::SIGTERM, libc::SIGINT] {
            libc::sigaction(signal, &action, std::ptr::null_mut());
        }
    }
    Ok(reader)
}

/// Startup shared by check, scan and cast: the stop handlers, then
/// `PR_SET_PDEATHSIG(SIGTERM)` so the bridge stops FluxCast through the
/// normal path when the shell dies. `None`: the parent is already gone.
pub fn prepare() -> Option<PipeReader> {
    let parent = getppid();
    let stops = trap_stop().ok();
    let _ = set_parent_process_death_signal(Some(Signal::TERM));
    if getppid() != parent {
        return None;
    }
    // A pipe failure leaves the default actions (the bridge just ends).
    Some(stops.unwrap_or_else(|| {
        io::pipe()
            .map(|(r, _)| r)
            .expect("a pipe for the signal loop")
    }))
}

pub struct ScanArgs {
    pub timeout: i64,
}

pub struct CastArgs {
    pub peer: String,
    pub monitor: String,
    pub output_res: String,
    pub fps: i64,
    pub bitrate: String,
    pub timeout: i64,
}

fn fluxcast_command() -> OsString {
    std::env::var_os("FLUXCAST_BIN").unwrap_or_else(|| "fluxcast".into())
}

fn executable(path: &Path) -> bool {
    path.exists() && access(path, Access::EXEC_OK).is_ok() && !path.is_dir()
}

/// `shutil.which(command) is not None`.
fn which(command: &OsString) -> bool {
    use std::os::unix::ffi::OsStrExt as _;
    let path = Path::new(command);
    if command.as_bytes().contains(&b'/') {
        return executable(path);
    }
    let search = std::env::var_os("PATH").unwrap_or_else(|| "/bin:/usr/bin".into());
    if search.is_empty() {
        return false;
    }
    let mut seen = Vec::new();
    for dir in search.as_bytes().split(|&b| b == b':') {
        if seen.contains(&dir) {
            continue;
        }
        seen.push(dir);
        let candidate = if dir.is_empty() {
            PathBuf::from(command)
        } else {
            Path::new(std::ffi::OsStr::from_bytes(dir)).join(command)
        };
        if executable(&candidate) {
            return true;
        }
    }
    false
}

/// FluxCast owns discovery and capture fallback; only casting needs FFmpeg.
fn missing_packages(for_cast: bool) -> Vec<&'static str> {
    let mut required: Vec<(OsString, &str)> = vec![(fluxcast_command(), "fluxcast-git")];
    if for_cast {
        required.push(("ffmpeg".into(), "ffmpeg"));
    }
    required
        .into_iter()
        .filter(|(command, _)| !which(command))
        .map(|(_, package)| package)
        .collect()
}

fn dependency_status(for_cast: bool) -> Value {
    let missing = missing_packages(for_cast);
    let error = if missing.is_empty() {
        String::new()
    } else {
        format!("Please install {}", missing.join(", "))
    };
    json!({"ok": missing.is_empty(), "missingPackages": missing, "peers": [], "error": error})
}

pub fn check() -> u8 {
    emit(&dependency_status(false));
    0
}

/// A started FluxCast: its own session, its output and error merged into
/// one pipe, `PYTHONUNBUFFERED=1`, and `PR_SET_PDEATHSIG(SIGINT)` (its own
/// cleanup path) for when Quickshell SIGKILLs the bridge.
fn start(args: &[String]) -> io::Result<(Child, PipeReader)> {
    let (reader, writer) = io::pipe()?;
    let mut command = Command::new(fluxcast_command());
    command
        .args(args)
        .env("PYTHONUNBUFFERED", "1")
        .stdout(writer.try_clone()?)
        .stderr(writer);
    let bridge = getpid();
    // SAFETY: runs in the forked child before exec and only makes system
    // calls (setsid, prctl, getppid); nothing allocates or locks.
    unsafe {
        command.pre_exec(move || {
            rustix::process::setsid()?;
            set_parent_process_death_signal(Some(Signal::INT))?;
            if getppid() != Some(bridge) {
                // The bridge died between fork and prctl: never start.
                return Err(io::Error::from_raw_os_error(libc::ESRCH));
            }
            Ok(())
        });
    }
    let child = command.spawn()?;
    drop(command);
    rustix::fs::fcntl_setfl(&reader, rustix::fs::OFlags::NONBLOCK)?;
    Ok((child, reader))
}

/// What a stop signal does: the first asks FluxCast to clean up (SIGINT to
/// it), every later one escalates to SIGTERM for its whole process group.
struct Stopper {
    cast: bool,
    count: u32,
}

impl Stopper {
    fn stop(&mut self, child: Option<&Child>) {
        self.count += 1;
        if self.cast {
            emit(
                &json!({"type": "phase", "phase": "stopping", "detail": "Stopping the cast cleanly"}),
            );
        }
        let Some(child) = child else { return };
        let Some(pid) = Pid::from_raw(child.id() as i32) else {
            return;
        };
        if self.count == 1 {
            let _ = kill_process(pid, Signal::INT);
        } else if kill_process_group(pid, Signal::TERM).is_err() {
            let _ = kill_process(pid, Signal::TERM);
        }
    }

    fn requested(&self) -> bool {
        self.count > 0
    }
}

fn drain_signals(stops: &mut PipeReader) -> u32 {
    let mut buffer = [0u8; 64];
    let mut count = 0;
    loop {
        match stops.read(&mut buffer) {
            Ok(0) => return count,
            Ok(n) => count += n as u32,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(_) => return count,
        }
    }
}

enum Ready {
    Output,
    Signal,
}

/// Waits for output or a signal.
fn wait_ready(
    output: Option<&PipeReader>,
    stops: &PipeReader,
    timeout: Option<Duration>,
) -> Vec<Ready> {
    let mut fds = vec![PollFd::from_borrowed_fd(stops.as_fd(), PollFlags::IN)];
    if let Some(output) = output {
        fds.push(PollFd::from_borrowed_fd(output.as_fd(), PollFlags::IN));
    }
    let wait = timeout.map(|t| Timespec {
        tv_sec: t.as_secs() as _,
        tv_nsec: t.subsec_nanos() as _,
    });
    match poll(&mut fds, wait.as_ref()) {
        Ok(_) => {}
        Err(_) => return Vec::new(),
    }
    let ready = |fd: &PollFd<'_>| {
        fd.revents()
            .intersects(PollFlags::IN | PollFlags::HUP | PollFlags::ERR)
    };
    let mut result = Vec::new();
    if ready(&fds[0]) {
        result.push(Ready::Signal);
    }
    if fds.len() > 1 && ready(&fds[1]) {
        result.push(Ready::Output);
    }
    result
}

/// Reads FluxCast's output until it ends, handling stop signals; `chunk`
/// gets each piece read.
fn pump(
    child: &Child,
    mut output: PipeReader,
    stops: &mut PipeReader,
    stopper: &mut Stopper,
    mut chunk: impl FnMut(&[u8]),
) {
    let mut buffer = vec![0u8; 16 * 1024];
    let mut open = true;
    while open {
        for ready in wait_ready(Some(&output), stops, None) {
            match ready {
                Ready::Signal => {
                    for _ in 0..drain_signals(stops) {
                        stopper.stop(Some(child));
                    }
                }
                Ready::Output => loop {
                    match output.read(&mut buffer) {
                        Ok(0) => {
                            open = false;
                            break;
                        }
                        Ok(n) => chunk(&buffer[..n]),
                        Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                        Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                        Err(_) => {
                            open = false;
                            break;
                        }
                    }
                },
            }
        }
    }
}

/// Waits for FluxCast to exit, still handling stop signals.
fn reap(mut child: Child, stops: &mut PipeReader, stopper: &mut Stopper) -> io::Result<ExitStatus> {
    loop {
        if let Some(status) = child.try_wait()? {
            return Ok(status);
        }
        for ready in wait_ready(None, stops, Some(Duration::from_millis(20))) {
            if let Ready::Signal = ready {
                for _ in 0..drain_signals(stops) {
                    stopper.stop(Some(&child));
                }
            }
        }
    }
}

/// Python's returncode: the exit status, or minus the signal.
fn return_code(status: ExitStatus) -> i32 {
    status
        .code()
        .unwrap_or_else(|| -status.signal().unwrap_or(0))
}

/// The bridge's own exit status for a FluxCast return code (`sys.exit(rc)`:
/// the low byte; 126 and 127 become 1).
fn exit_status(code: i32) -> u8 {
    match (code & 0xff) as u8 {
        126 | 127 => 1,
        status => status,
    }
}

fn start_error(error: &io::Error) -> String {
    format!(
        "Could not start FluxCast: {}",
        py::os_error(error, Path::new(&fluxcast_command()))
    )
}

/// Peer records from `fluxcast --wfd-scan` output: `[n] MAC name via
/// source` lines, `wfdCapable` from a following "WFD capability data
/// detected" line.
pub fn parse_scan_output(output: &str) -> Vec<Value> {
    let mut peers: Vec<Value> = Vec::new();
    for raw in py::splitlines(output) {
        let line = py::rstrip(raw);
        if let Some((index, address, tail)) = peer_line(line) {
            let tail = py::strip(tail);
            let (name, source) = if let Some(source) = tail.strip_prefix("via ") {
                ("", source)
            } else if let Some(at) = tail.rfind(" via ") {
                (&tail[..at], &tail[at + 5..])
            } else {
                (tail, "")
            };
            peers.push(json!({
                "index": index,
                "address": address.to_ascii_uppercase(),
                "name": py::strip(name),
                "source": py::strip(source),
                "wfdCapable": false,
            }));
            continue;
        }
        if line.contains("WFD capability data detected")
            && let Some(current) = peers.last_mut()
        {
            current["wfdCapable"] = true.into();
        }
    }
    peers
}

/// `^\s*\[(\d+)]\s+([0-9a-fA-F:]{17})(?:\s+(.*))?$`
fn peer_line(line: &str) -> Option<(u64, &str, &str)> {
    let rest = line.trim_start_matches(py::is_space).strip_prefix('[')?;
    let digits = rest.bytes().take_while(u8::is_ascii_digit).count();
    let index = rest[..digits].parse().ok()?;
    let rest = rest[digits..].strip_prefix(']')?;
    let spaced = rest.trim_start_matches(py::is_space);
    if spaced.len() == rest.len() {
        return None;
    }
    let mac = spaced.get(..17)?;
    if !mac.bytes().all(|b| b.is_ascii_hexdigit() || b == b':') {
        return None;
    }
    let after = &spaced[17..];
    if after.is_empty() {
        return Some((index, mac, ""));
    }
    let tail = after.trim_start_matches(py::is_space);
    (tail.len() < after.len()).then_some((index, mac, tail))
}

/// The phase a FluxCast log line reports, if any.
pub fn phase_for_line(line: &str) -> Option<(&'static str, String)> {
    if line.contains("Starting NetworkManager Wi-Fi Direct scan")
        || line.contains("Starting Wi-Fi Direct scan")
    {
        return Some((
            "scanning",
            "Looking for the selected wireless display".into(),
        ));
    }
    if line.contains("Connecting to ") {
        return Some(("connecting", "Creating the Wi-Fi Direct connection".into()));
    }
    if line.contains("P2P link is activated") || line.contains("Waiting for TV RTSP/WFD session") {
        return Some((
            "waiting",
            "Waiting for the receiver to start mirroring".into(),
        ));
    }
    if line.contains("PLAY accepted; media stream started") {
        return Some(("casting", "Desktop and audio are being shared".into()));
    }
    if line.contains(" ERROR:") || line.starts_with("ERROR:") {
        let detail = py::strip(line.rsplit_once("ERROR:").map_or(line, |(_, after)| after));
        return Some((
            "error",
            if detail.is_empty() {
                "FluxCast failed".into()
            } else {
                detail.into()
            },
        ));
    }
    None
}

pub fn scan(args: &ScanArgs, mut stops: PipeReader) -> u8 {
    let dependencies = dependency_status(false);
    if dependencies["ok"] != true {
        emit(&dependencies);
        return MISSING;
    }
    let mut stopper = Stopper {
        cast: false,
        count: 0,
    };
    let command = [
        "--wfd-scan".to_owned(),
        "--wfd-timeout".to_owned(),
        args.timeout.to_string(),
    ];
    let (child, output) = match start(&command) {
        Ok(started) => started,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            emit(
                &json!({"ok": false, "error": "Please install fluxcast-git", "missingPackages": ["fluxcast-git"], "peers": []}),
            );
            return MISSING;
        }
        Err(error) => {
            emit(&json!({"ok": false, "error": start_error(&error), "peers": []}));
            return 1;
        }
    };
    let mut text = Vec::new();
    pump(&child, output, &mut stops, &mut stopper, |chunk| {
        let room = SCAN_OUTPUT.saturating_sub(text.len());
        text.extend_from_slice(&chunk[..chunk.len().min(room)]);
    });
    let code = match reap(child, &mut stops, &mut stopper) {
        Ok(status) => return_code(status),
        Err(error) => {
            emit(&json!({"ok": false, "error": start_error(&error), "peers": []}));
            return 1;
        }
    };
    let output = String::from_utf8_lossy(&text);
    let peers = parse_scan_output(&output);
    if stopper.requested() {
        emit(&json!({"ok": false, "error": "Scan cancelled", "peers": []}));
        return 130;
    }
    if code != 0 {
        let message = py::splitlines(&output)
            .into_iter()
            .map(py::strip)
            .rfind(|line| line.contains("ERROR:"))
            .map(|line| {
                py::strip(line.split_once("ERROR:").map_or(line, |(_, after)| after)).to_owned()
            })
            .unwrap_or_else(|| "Wireless display scan failed".into());
        emit(&json!({"ok": false, "error": message, "peers": []}));
        return exit_status(code);
    }
    emit(&json!({"ok": true, "error": "", "peers": peers}));
    0
}

fn mac_address(text: &str) -> bool {
    text.len() == 17
        && text.bytes().enumerate().all(|(i, b)| {
            if i % 3 == 2 {
                b == b':'
            } else {
                b.is_ascii_hexdigit()
            }
        })
}

/// Splits a byte stream into lines like a text-mode reader (`\n`, `\r\n`
/// and a lone `\r` end a line), each cut at [`LINE_LIMIT`].
struct Lines {
    pending: Vec<u8>,
    carriage: bool,
    overlong: bool,
}

impl Lines {
    fn feed(&mut self, bytes: &[u8], line: &mut impl FnMut(&[u8])) {
        for &b in bytes {
            if self.carriage {
                self.carriage = false;
                if b == b'\n' {
                    continue;
                }
            }
            if b == b'\n' || b == b'\r' {
                self.carriage = b == b'\r';
                line(&self.pending);
                self.pending.clear();
                self.overlong = false;
            } else if self.pending.len() < LINE_LIMIT {
                self.pending.push(b);
            } else {
                self.overlong = true;
            }
        }
    }

    fn finish(&mut self, line: &mut impl FnMut(&[u8])) {
        if !self.pending.is_empty() {
            line(&self.pending);
            self.pending.clear();
        }
    }
}

pub fn cast(args: &CastArgs, mut stops: PipeReader) -> u8 {
    let dependencies = dependency_status(true);
    if dependencies["ok"] != true {
        emit(&json!({"type": "phase", "phase": "error", "detail": dependencies["error"]}));
        return MISSING;
    }
    let peer = args.peer.to_uppercase();
    if !mac_address(&peer) {
        emit(
            &json!({"type": "phase", "phase": "error", "detail": "Invalid wireless display address"}),
        );
        return 2;
    }
    let command = [
        "--protocol".to_owned(),
        "wfd".to_owned(),
        "--wfd-peer".to_owned(),
        peer,
        "--monitor".to_owned(),
        args.monitor.clone(),
        "--output-res".to_owned(),
        args.output_res.clone(),
        "--fps".to_owned(),
        args.fps.to_string(),
        "--bitrate".to_owned(),
        args.bitrate.clone(),
        "--wfd-timeout".to_owned(),
        args.timeout.to_string(),
    ];
    emit(&json!({"type": "phase", "phase": "starting", "detail": "Preparing FluxCast"}));
    let mut stopper = Stopper {
        cast: true,
        count: 0,
    };
    let (child, output) = match start(&command) {
        Ok(started) => started,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            emit(
                &json!({"type": "phase", "phase": "error", "detail": "Please install fluxcast-git"}),
            );
            return MISSING;
        }
        Err(error) => {
            emit(&json!({"type": "phase", "phase": "error", "detail": start_error(&error)}));
            return 1;
        }
    };
    let mut last_error = String::new();
    let mut reached_casting = false;
    let mut on_line = |bytes: &[u8]| {
        let text = String::from_utf8_lossy(bytes);
        let line = py::rstrip(&text);
        if line.is_empty() {
            return;
        }
        if let Some((phase, detail)) = phase_for_line(line) {
            if phase == "casting" {
                reached_casting = true;
            } else if phase == "error" {
                last_error = detail.clone();
            }
            emit(&json!({"type": "phase", "phase": phase, "detail": detail}));
        }
    };
    let mut lines = Lines {
        pending: Vec::new(),
        carriage: false,
        overlong: false,
    };
    pump(&child, output, &mut stops, &mut stopper, |chunk| {
        lines.feed(chunk, &mut on_line)
    });
    lines.finish(&mut on_line);
    let code = match reap(child, &mut stops, &mut stopper) {
        Ok(status) => return_code(status),
        Err(error) => {
            emit(&json!({"type": "phase", "phase": "error", "detail": start_error(&error)}));
            return 1;
        }
    };
    if stopper.requested() {
        emit(&json!({"type": "exit", "expected": true, "code": code}));
        return 0;
    }
    if code != 0 {
        let detail = if last_error.is_empty() {
            format!("FluxCast exited with code {code}")
        } else {
            last_error
        };
        emit(&json!({"type": "phase", "phase": "error", "detail": detail}));
        emit(&json!({"type": "exit", "expected": false, "code": code}));
        return exit_status(code);
    }
    if reached_casting {
        emit(&json!({"type": "phase", "phase": "idle", "detail": "Cast ended"}));
    } else {
        let detail = if last_error.is_empty() {
            "FluxCast ended before casting started".to_owned()
        } else {
            last_error
        };
        emit(&json!({"type": "phase", "phase": "error", "detail": detail}));
    }
    emit(&json!({"type": "exit", "expected": false, "code": code}));
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn peers_parse_like_the_old_pattern() {
        let output = "[FluxCast WFD] Wi-Fi Direct peer(s):\n  [0] 7a:2d:91:40:0b:ce  Living Room TV via NetworkManager\n\
            \x20     WFD capability data detected\n  [1] 02:11:22:33:44:55 via wpa_cli\n[2]02:11:22:33:44:55\n\
            [3] 02:11:22:33:44:55x\n[4] 02:11:22:33:44:55\t\n";
        let peers = parse_scan_output(output);
        assert_eq!(peers.len(), 3);
        assert_eq!(
            peers[0],
            json!({"index": 0, "address": "7A:2D:91:40:0B:CE", "name": "Living Room TV", "source": "NetworkManager", "wfdCapable": true})
        );
        assert_eq!(peers[1]["source"], "wpa_cli");
        assert_eq!(peers[2]["index"], 4);
        assert!(parse_scan_output("WFD capability data detected").is_empty());
    }

    #[test]
    fn phases() {
        assert_eq!(
            phase_for_line("x ERROR: a ERROR: b"),
            Some(("error", "b".into()))
        );
        assert_eq!(
            phase_for_line("ERROR:  "),
            Some(("error", "FluxCast failed".into()))
        );
        assert_eq!(phase_for_line("xERROR: a"), None);
        assert_eq!(phase_for_line("Connecting to x").unwrap().0, "connecting");
    }

    #[test]
    fn line_splitting_is_text_mode() {
        let mut lines = Lines {
            pending: Vec::new(),
            carriage: false,
            overlong: false,
        };
        let mut seen = Vec::new();
        let mut push = |line: &[u8]| seen.push(String::from_utf8_lossy(line).into_owned());
        lines.feed(b"a\r", &mut push);
        lines.feed(b"\nb\rc\n\nd", &mut push);
        lines.finish(&mut push);
        assert_eq!(seen, ["a", "b", "c", "", "d"]);
    }

    #[test]
    fn addresses_and_exit_codes() {
        assert!(mac_address("AA:BB:CC:DD:EE:FF"));
        assert!(!mac_address("AA:BB:CC:DD:EE:F"));
        assert!(!mac_address("AA-BB:CC:DD:EE:FF"));
        assert_eq!(exit_status(-15), 241);
        assert_eq!(exit_status(127), 1);
        assert_eq!(exit_status(3), 3);
    }
}
