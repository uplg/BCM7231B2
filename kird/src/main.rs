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

use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::time::Duration;

const EV_KEY: u16 = 1;
/// struct input_event on a 32-bit kernel ABI: u32 sec, u32 usec,
/// u16 type, u16 code, i32 value — 16 bytes, little-endian on mipsel.
const EVENT_SIZE: usize = 16;

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

fn post(url: &Url, token: &str, body: &str) -> Result<(), String> {
    let addr = (url.host.as_str(), url.port)
        .to_socket_addrs()
        .map_err(|e| format!("resolve: {e}"))?
        .next()
        .ok_or("resolve: no address")?;
    let mut s = TcpStream::connect_timeout(&addr, Duration::from_secs(3))
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
    println!("forwarding {device} -> {url_raw}");

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
            let body = format!("{{\"code\":{code},\"value\":{value}}}");
            if let Err(e) = post(&url, &token, &body) {
                eprintln!("key {code} (value {value}) dropped: {e}");
            }
        }
    }
}
