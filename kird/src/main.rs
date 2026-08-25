//! kird — forwards Ruwido remote keypresses (BCM7231 KIR, /dev/input) to the
//! maison backend over plain HTTP on the LAN.
//!
//! Config via environment (set by /etc/init.d/kird from /etc/kird.conf):
//!   KIRD_URL     e.g. http://192.168.1.40:3033/api/ir/key
//!   KIRD_TOKEN   bearer token expected by maison
//!   KIRD_DEVICE  input device (default /dev/input/event0)
//!
//! Every EV_KEY event is forwarded with its value (1=press, 2=autorepeat,
//! 0=release) — maison decides what to act on. A failed send drops the event:
//! keypresses are ephemeral, there is nothing useful to queue.
//!
//! Reading and sending are deliberately decoupled. The remote emits a frame
//! every ~120 ms while a key is held, and maison can take longer than that to
//! answer (an ADB round-trip to the TV box runs ~150 ms, far more if the box
//! is asleep). Posting inline would block the read loop past the next frame,
//! so every held key accrued delay — a third of a second after ten frames,
//! growing for as long as the button was down.
//!
//! So the reader never blocks: it stamps each event and hands it to a single
//! sender thread through a bounded channel. One thread keeps ordering intact.
//! Stale autorepeats are dropped rather than replayed late, which is what
//! stops the backlog from simply moving into the queue; presses and releases
//! always go through, however late, because those carry the user's intent.

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream, ToSocketAddrs};
use std::sync::mpsc::{sync_channel, TrySendError};
use std::time::{Duration, Instant};

const EV_KEY: u16 = 1;
/// struct input_event on a 32-bit kernel ABI: u32 sec, u32 usec,
/// u16 type, u16 code, i32 value — 16 bytes, little-endian on mipsel.
const EVENT_SIZE: usize = 16;

/// Deep enough to ride out a slow backend reply, shallow enough that a
/// wedged backend cannot bank seconds of keypresses to replay later.
const QUEUE_DEPTH: usize = 64;

/// An autorepeat older than this has been overtaken by reality: the frame it
/// represents is two remote frames in the past. Dropping it is what keeps the
/// D-pad tracking the finger instead of trailing it.
const MAX_AUTOREPEAT_AGE: Duration = Duration::from_millis(250);

struct Url {
    host: String,
    port: u16,
    path: String,
}

fn parse_url(url: &str) -> Result<Url, String> {
    let rest = url
        .strip_prefix("http://")
        .ok_or("KIRD_URL must start with http:// (plain HTTP, LAN only)")?;
    let (hostport, path) = match rest.find('/') {
        Some(i) => (&rest[..i], &rest[i..]),
        None => (rest, "/"),
    };
    let (host, port) = match hostport.rsplit_once(':') {
        Some((h, p)) => (h, p.parse::<u16>().map_err(|_| "bad port in KIRD_URL")?),
        None => (hostport, 80),
    };
    Ok(Url {
        host: host.to_string(),
        port,
        path: path.to_string(),
    })
}

/// `addr` is resolved once at startup rather than per keypress.
fn post(addr: &SocketAddr, url: &Url, token: &str, body: &str) -> Result<(), String> {
    let mut s = TcpStream::connect_timeout(addr, Duration::from_secs(3))
        .map_err(|e| format!("connect: {e}"))?;
    let _ = s.set_write_timeout(Some(Duration::from_secs(3)));
    let _ = s.set_read_timeout(Some(Duration::from_secs(3)));
    let req = format!(
        "POST {} HTTP/1.1\r\nHost: {}\r\nAuthorization: Bearer {}\r\n\
         Content-Type: application/json\r\nContent-Length: {}\r\n\
         Connection: close\r\n\r\n{}",
        url.path,
        url.host,
        token,
        body.len(),
        body
    );
    s.write_all(req.as_bytes()).map_err(|e| format!("send: {e}"))?;
    let mut buf = [0u8; 256];
    let n = s.read(&mut buf).unwrap_or(0);
    let head = String::from_utf8_lossy(&buf[..n]);
    let status = head.split_whitespace().nth(1).unwrap_or("<none>").to_string();
    if status.starts_with('2') {
        Ok(())
    } else {
        Err(format!("HTTP {status}"))
    }
}

/// One keypress on its way out, stamped when it left the driver.
struct Event {
    code: u16,
    value: i32,
    at: Instant,
}

fn main() {
    let url_raw = std::env::var("KIRD_URL").expect("KIRD_URL not set");
    let token = std::env::var("KIRD_TOKEN").expect("KIRD_TOKEN not set");
    let device =
        std::env::var("KIRD_DEVICE").unwrap_or_else(|_| "/dev/input/event0".to_string());
    let url = match parse_url(&url_raw) {
        Ok(u) => u,
        Err(e) => {
            eprintln!("bad KIRD_URL {url_raw:?}: {e}");
            std::process::exit(1);
        }
    };

    // Resolved once: doing it per keypress put a lookup on the hot path.
    let addr = match (url.host.as_str(), url.port).to_socket_addrs() {
        Ok(mut addrs) => match addrs.next() {
            Some(addr) => addr,
            None => {
                eprintln!("resolve {}: no address", url.host);
                std::process::exit(1);
            }
        },
        Err(e) => {
            eprintln!("resolve {}: {e}", url.host);
            std::process::exit(1);
        }
    };

    println!("forwarding {device} -> {url_raw}");

    let (tx, rx) = sync_channel::<Event>(QUEUE_DEPTH);

    // Single sender thread: keeps events in order without ever blocking the
    // reader. Ordering matters — a release overtaking its press would leave
    // maison believing a key is still held.
    std::thread::spawn(move || {
        for ev in rx {
            // Presses and releases carry intent and always go through, even
            // late. Autorepeat is a stream: a stale one is noise.
            if ev.value == 2 && ev.at.elapsed() > MAX_AUTOREPEAT_AGE {
                continue;
            }
            let body = format!("{{\"code\":{},\"value\":{}}}", ev.code, ev.value);
            if let Err(e) = post(&addr, &url, &token, &body) {
                eprintln!("key {} (value {}) dropped: {e}", ev.code, ev.value);
            }
        }
    });

    loop {
        let mut f = match std::fs::File::open(&device) {
            Ok(f) => f,
            Err(e) => {
                eprintln!("open {device}: {e} — retrying in 5s");
                std::thread::sleep(Duration::from_secs(5));
                continue;
            }
        };
        let mut ev = [0u8; EVENT_SIZE];
        loop {
            if let Err(e) = f.read_exact(&mut ev) {
                eprintln!("read {device}: {e} — reopening");
                std::thread::sleep(Duration::from_secs(1));
                break;
            }
            let typ = u16::from_le_bytes([ev[8], ev[9]]);
            let code = u16::from_le_bytes([ev[10], ev[11]]);
            let value = i32::from_le_bytes([ev[12], ev[13], ev[14], ev[15]]);
            if typ != EV_KEY {
                continue;
            }
            // try_send, never send: a full queue means the backend is behind,
            // and blocking here is precisely the bug this design removes.
            match tx.try_send(Event {
                code,
                value,
                at: Instant::now(),
            }) {
                Ok(()) => {}
                Err(TrySendError::Full(_)) => {
                    eprintln!("key {code} (value {value}) dropped: queue full")
                }
                Err(TrySendError::Disconnected(_)) => {
                    eprintln!("sender thread died — exiting");
                    std::process::exit(1);
                }
            }
        }
    }
}
