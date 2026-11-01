//! wheelffb-relay: runs next to FS22 (inside its Proton prefix on Linux, or plainly on Windows).
//!
//! The FS22 mod can only write to a Windows named pipe (FS22's Lua has no sockets), and a
//! native Linux program can't open a pipe that lives inside Wine. This relay serves
//! `\\.\pipe\WheelFFB` and forwards every line over a WebSocket to the FFB server at
//! ws://127.0.0.1:47820/telemetry (Wine sockets are real host sockets).
//!
//! Usage:
//!   wheelffb-relay.exe                      relay only
//!   wheelffb-relay.exe --exec GAME.exe ...  start the relay, run the game, exit with it
//!                                            (used by the Steam launch wrapper)

use std::io::Write;
use std::net::TcpStream;
use std::process::Command;
use std::thread;
use std::time::{Duration, Instant};

use tungstenite::stream::MaybeTlsStream;
use tungstenite::{Message, WebSocket};
use windows_sys::Win32::Foundation::{
    CloseHandle, GetLastError, ERROR_PIPE_CONNECTED, HANDLE, INVALID_HANDLE_VALUE,
};
use windows_sys::Win32::Storage::FileSystem::{ReadFile, PIPE_ACCESS_INBOUND};
use windows_sys::Win32::System::Pipes::{
    ConnectNamedPipe, CreateNamedPipeW, DisconnectNamedPipe, PIPE_READMODE_BYTE, PIPE_TYPE_BYTE,
    PIPE_WAIT,
};

const PIPE_NAME: &str = r"\\.\pipe\WheelFFB";
const SERVER_URL: &str = "ws://127.0.0.1:47820/telemetry";

fn log(msg: &str) {
    let _ = writeln!(std::io::stderr(), "[wheelffb-relay] {msg}");
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// WebSocket to the FFB server, reconnected lazily and rate-limited so a missing server
/// costs nothing. The mod's hello is remembered and re-sent after every reconnect.
struct Uplink {
    ws: Option<WebSocket<MaybeTlsStream<TcpStream>>>,
    next_try: Instant,
    hello: Option<String>,
}

impl Uplink {
    fn new() -> Self {
        Self { ws: None, next_try: Instant::now(), hello: None }
    }

    fn send(&mut self, line: &str) {
        let is_hello = line.contains("\"type\":\"hello\"");
        if is_hello {
            self.hello = Some(line.to_owned());
        }
        if self.ws.is_none() {
            if Instant::now() < self.next_try {
                return;
            }
            self.next_try = Instant::now() + Duration::from_secs(2);
            match tungstenite::connect(SERVER_URL) {
                Ok((ws, _)) => {
                    if let MaybeTlsStream::Plain(s) = ws.get_ref() {
                        let _ = s.set_nodelay(true);
                    }
                    log("connected to the FFB server");
                    self.ws = Some(ws);
                    if let (false, Some(h)) = (is_hello, self.hello.clone()) {
                        self.send_raw(&h);
                    }
                }
                Err(_) => return,
            }
        }
        self.send_raw(line);
    }

    fn send_raw(&mut self, line: &str) {
        if let Some(ws) = self.ws.as_mut() {
            if ws.send(Message::text(line.to_owned())).is_err() {
                log("lost the FFB server connection");
                self.ws = None;
            }
        }
    }
}

/// Serves the named pipe forever: one game connection at a time, re-armed after each.
fn serve_pipe() {
    let name = wide(PIPE_NAME);
    let mut uplink = Uplink::new();
    loop {
        let pipe: HANDLE = unsafe {
            CreateNamedPipeW(
                name.as_ptr(),
                PIPE_ACCESS_INBOUND,
                PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
                1,
                0,
                64 * 1024,
                0,
                std::ptr::null(),
            )
        };
        if pipe == INVALID_HANDLE_VALUE {
            log(&format!("CreateNamedPipe failed (error {})", unsafe { GetLastError() }));
            thread::sleep(Duration::from_secs(2));
            continue;
        }

        let connected = unsafe { ConnectNamedPipe(pipe, std::ptr::null_mut()) } != 0
            || unsafe { GetLastError() } == ERROR_PIPE_CONNECTED;
        if connected {
            log("game connected to pipe");
            pump(pipe, &mut uplink);
            log("game disconnected from pipe");
        }
        unsafe {
            DisconnectNamedPipe(pipe);
            CloseHandle(pipe);
        }
    }
}

/// Reads newline-separated telemetry from the pipe and forwards each complete line.
fn pump(pipe: HANDLE, uplink: &mut Uplink) {
    let mut buf = [0u8; 16 * 1024];
    let mut acc: Vec<u8> = Vec::with_capacity(32 * 1024);
    loop {
        let mut read = 0u32;
        let ok = unsafe {
            ReadFile(pipe, buf.as_mut_ptr(), buf.len() as u32, &mut read, std::ptr::null_mut())
        };
        if ok == 0 || read == 0 {
            return;
        }
        acc.extend_from_slice(&buf[..read as usize]);
        while let Some(pos) = acc.iter().position(|b| *b == b'\n') {
            let line: Vec<u8> = acc.drain(..=pos).collect();
            if let Ok(s) = std::str::from_utf8(&line[..line.len() - 1]) {
                let s = s.trim_end_matches('\r');
                if !s.is_empty() {
                    uplink.send(s);
                }
            }
        }
        // A runaway line without newlines would be a bug; don't let it grow forever.
        if acc.len() > 1024 * 1024 {
            acc.clear();
        }
    }
}

/// Test mode: acts like the FS22 mod, opening the pipe as a client and writing fake telemetry
/// (a slow left/right weave over a bumpy field). Exercises the real Wine pipe path end to end.
fn fake_game() {
    thread::sleep(Duration::from_millis(500));
    let mut f = loop {
        match std::fs::OpenOptions::new().write(true).open(PIPE_NAME) {
            Ok(f) => break f,
            Err(_) => thread::sleep(Duration::from_millis(200)),
        }
    };
    log("fake game: writing telemetry for 10 s");
    let start = Instant::now();
    let mut seq = 0u64;
    while start.elapsed() < Duration::from_secs(10) {
        seq += 1;
        let t = start.elapsed().as_secs_f64();
        let bump = if seq % 30 < 3 { 0.04 } else { 0.0 };
        let line = format!(
            "{{\"v\":1,\"seq\":{seq},\"t\":{t:.3},\"active\":true,\"speed\":{sp:.2},\"engine\":true,\"rpm\":1400,\"load\":0.5,\
             \"vFwd\":{sp:.2},\"vUp\":0,\"yawRate\":0,\"wheels\":[\
             {{\"i\":1,\"steered\":true,\"steer\":0,\"steerMax\":0.6,\"y\":{bump},\"x\":1,\"surface\":\"field\"}},\
             {{\"i\":2,\"steered\":true,\"steer\":0,\"steerMax\":0.6,\"y\":0,\"x\":-1,\"surface\":\"field\"}}]}}\n",
            sp = 4.0 + t, bump = bump
        );
        if f.write_all(line.as_bytes()).is_err() {
            break;
        }
        thread::sleep(Duration::from_millis(16));
    }
    log("fake game: done");
    std::process::exit(0);
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    thread::spawn(serve_pipe);
    if args.iter().any(|a| a == "--fake") {
        fake_game();
    }

    if let Some(i) = args.iter().position(|a| a == "--exec") {
        let Some(exe) = args.get(i + 1) else {
            log("--exec needs a program");
            std::process::exit(2);
        };
        let dir = std::path::Path::new(exe).parent().map(|p| p.to_path_buf());
        let mut cmd = Command::new(exe);
        cmd.args(&args[i + 2..]);
        if let Some(d) = dir {
            cmd.current_dir(d);
        }
        log(&format!("starting {exe}"));
        let code = match cmd.status() {
            Ok(s) => s.code().unwrap_or(0),
            Err(e) => {
                log(&format!("could not start game: {e}"));
                1
            }
        };
        log("game exited, relay stopping");
        std::process::exit(code);
    }

    log(&format!("relaying {PIPE_NAME} -> {SERVER_URL} (Ctrl+C to stop)"));
    loop {
        thread::park();
    }
}
