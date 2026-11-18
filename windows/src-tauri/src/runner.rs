//! Runs yt-dlp as a child process.
use std::ffi::OsString;
use std::io;
use std::path::Path;
use std::process::Stdio;
use std::sync::Mutex;
use tokio::io::{AsyncRead, AsyncReadExt};
use tokio::process::Command;
use tokio::sync::mpsc;

pub struct Output {
    pub stdout: Vec<u8>,
    pub stderr: String,
    pub status: i32,
}

fn command(exe: &Path, args: &[String], path_env: &OsString) -> Command {
    let mut cmd = Command::new(exe);
    cmd.args(args).env("PATH", path_env).stdin(Stdio::null()).kill_on_drop(true);
    // No flashing console window behind the app.
    #[cfg(windows)]
    cmd.creation_flags(0x0800_0000);
    cmd
}

/// Runs a command to the end and returns what it printed.
pub async fn run(exe: &Path, args: &[String], path_env: &OsString) -> io::Result<Output> {
    let out = command(exe, args, path_env).stdout(Stdio::piped()).stderr(Stdio::piped()).output().await?;
    Ok(Output {
        stdout: out.stdout,
        stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
        status: out.status.code().unwrap_or(-1),
    })
}

/// Splits a byte stream into lines. Progress bars use \r, so both \r and \n end a line.
async fn read_lines<R: AsyncRead + Unpin>(mut reader: R, tx: mpsc::UnboundedSender<String>) {
    let mut pending: Vec<u8> = Vec::new();
    let mut buf = [0u8; 8192];
    loop {
        let n = match reader.read(&mut buf).await {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        pending.extend_from_slice(&buf[..n]);
        while let Some(i) = pending.iter().position(|b| *b == b'\n' || *b == b'\r') {
            let line: Vec<u8> = pending.drain(..=i).collect();
            let text = String::from_utf8_lossy(&line[..line.len() - 1]).into_owned();
            if !text.is_empty() {
                let _ = tx.send(text);
            }
        }
    }
    if !pending.is_empty() {
        let _ = tx.send(String::from_utf8_lossy(&pending).into_owned());
    }
}

/// Runs a command, calling `on_line` for every line of stdout and stderr, and returns the exit code.
/// The process id goes into `pid_slot` while it runs, so `kill_tree` can stop it.
pub async fn stream(
    exe: &Path,
    args: &[String],
    path_env: &OsString,
    pid_slot: &Mutex<Option<u32>>,
    mut on_line: impl FnMut(String),
) -> io::Result<i32> {
    let mut child = command(exe, args, path_env).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn()?;
    *pid_slot.lock().unwrap() = child.id();
    let (tx, mut rx) = mpsc::unbounded_channel();
    tokio::spawn(read_lines(child.stdout.take().unwrap(), tx.clone()));
    tokio::spawn(read_lines(child.stderr.take().unwrap(), tx));
    while let Some(line) = rx.recv().await {
        on_line(line);
    }
    let status = child.wait().await?;
    *pid_slot.lock().unwrap() = None;
    Ok(status.code().unwrap_or(-1))
}

/// Stops a process and the ffmpeg it started.
pub fn kill_tree(pid: u32) {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        let _ = std::process::Command::new("taskkill")
            .args(["/PID", &pid.to_string(), "/T", "/F"])
            .creation_flags(0x0800_0000)
            .output();
    }
    #[cfg(not(windows))]
    {
        let _ = std::process::Command::new("pkill").args(["-TERM", "-P", &pid.to_string()]).output();
        let _ = std::process::Command::new("kill").args(["-TERM", &pid.to_string()]).output();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn splits_on_cr_and_lf() {
        let (tx, mut rx) = mpsc::unbounded_channel();
        read_lines(&b"one\rtwo\nthree"[..], tx).await;
        let mut got = Vec::new();
        while let Some(l) = rx.recv().await {
            got.push(l);
        }
        assert_eq!(got, ["one", "two", "three"]);
    }
}
