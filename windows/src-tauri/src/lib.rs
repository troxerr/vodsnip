mod info;
mod progress;
mod request;
mod runner;
mod timecode;
mod tools;
mod twitch_url;

use info::{VideoInfo, VideoList};
use request::{DownloadRequest, Quality, Range, FILE_PREFIX};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use tauri::ipc::Channel;
use tauri::{AppHandle, Manager, State};
use twitch_url::TwitchUrl;

#[derive(Default)]
struct AppState {
    pid: Mutex<Option<u32>>,
    busy: AtomicBool,
    cancelled: AtomicBool,
}

fn bundled_dir(app: &AppHandle) -> Option<PathBuf> {
    let dir = app.path().resource_dir().ok()?.join("bin");
    dir.is_dir().then_some(dir)
}

fn tools_for(app: &AppHandle) -> Result<tools::Tools, String> {
    tools::locate(bundled_dir(app).as_deref())
        .ok_or_else(|| "yt-dlp was not found. Reinstall Vodsnip, or put yt-dlp on your PATH.".to_string())
}

/// The most useful line of yt-dlp's error output.
fn error_line(stderr: &str) -> String {
    let lines: Vec<&str> = stderr.lines().filter(|l| !l.trim().is_empty()).collect();
    let line = lines.iter().rev().find(|l| l.starts_with("ERROR")).or(lines.last()).copied().unwrap_or("yt-dlp failed.");
    line.replace("ERROR: ", "")
}

fn cookie_args(cookies: &str) -> Vec<String> {
    if cookies.is_empty() { vec![] } else { vec!["--cookies".into(), cookies.into()] }
}

async fn video_info(app: &AppHandle, url: &str, cookies: &str) -> Result<VideoInfo, String> {
    let t = tools_for(app)?;
    let mut args: Vec<String> = ["-J", "--no-playlist", "--no-warnings"].map(String::from).to_vec();
    args.extend(cookie_args(cookies));
    args.push(url.into());
    let out = runner::run(&t.ytdlp, &args, &tools::child_path(bundled_dir(app).as_deref())).await.map_err(|e| e.to_string())?;
    if out.status != 0 {
        return Err(error_line(&out.stderr));
    }
    serde_json::from_slice(&out.stdout).map_err(|e| format!("Could not read the video info: {e}"))
}

async fn newest_archive(app: &AppHandle, channel: &str, cookies: &str) -> Result<String, String> {
    let t = tools_for(app)?;
    let mut args: Vec<String> =
        ["-J", "--flat-playlist", "--playlist-end", "1", "--no-warnings"].map(String::from).to_vec();
    args.extend(cookie_args(cookies));
    args.push(format!("https://www.twitch.tv/{channel}/videos?filter=archives&sort=time"));
    let out = runner::run(&t.ytdlp, &args, &tools::child_path(bundled_dir(app).as_deref())).await.map_err(|e| e.to_string())?;
    if out.status != 0 {
        return Err(error_line(&out.stderr));
    }
    let list: VideoList = serde_json::from_slice(&out.stdout).map_err(|e| e.to_string())?;
    list.newest_url().ok_or_else(|| {
        format!("{channel} is live, but has no recording to download from the start (past broadcasts may be turned off).")
    })
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Fetched {
    info: VideoInfo,
    download_url: String,
    is_live_now: bool,
    live_edge: Option<f64>,
}

#[tauri::command]
async fn fetch_video(app: AppHandle, url: String, cookies: String) -> Result<Fetched, String> {
    tools_for(&app)?;
    let parsed = twitch_url::parse(&url).ok_or("That doesn't look like a Twitch video or channel link.")?;
    match &parsed {
        TwitchUrl::Vod(_) | TwitchUrl::Other(_) => {
            let download_url = parsed.canonical();
            let info = video_info(&app, &download_url, &cookies).await?;
            Ok(Fetched { info, download_url, is_live_now: false, live_edge: None })
        }
        TwitchUrl::Channel(name) => {
            let live = video_info(&app, &parsed.canonical(), &cookies).await.ok();
            if live.and_then(|l| l.is_live) != Some(true) {
                return Err(format!("{name} isn't live right now. Paste a video (VOD) link to download past streams."));
            }
            let download_url = newest_archive(&app, name, &cookies).await?;
            let info = video_info(&app, &download_url, &cookies).await?;
            let live_edge = info.duration;
            Ok(Fetched { info, download_url, is_live_now: true, live_edge })
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DownloadParams {
    download_url: String,
    /// "entire", "range" or "startNow"
    mode: String,
    start_text: String,
    end_text: String,
    quality: Quality,
    accurate_cuts: bool,
    output_dir: String,
    cookies: String,
    is_live_now: bool,
    live_edge: Option<f64>,
    duration: Option<f64>,
}

#[derive(Serialize, Clone)]
#[serde(tag = "event", content = "data", rename_all = "camelCase")]
enum DownloadEvent {
    /// A live recording's length, read again just before the download starts.
    Length { seconds: f64 },
    Progress(progress::Progress),
    Log { line: String },
    Done { file: Option<String> },
    Failed { message: String },
    Cancelled,
}

/// Checks the time fields and builds the request, or explains what is wrong.
fn make_request(p: &DownloadParams, ffmpeg: Option<&PathBuf>) -> Result<DownloadRequest, String> {
    let mut range = Range::Entire;
    if p.mode == "range" {
        let start = timecode::parse(&p.start_text).ok_or("Start time must look like 01:23:45.")?;
        let mut end = None;
        if !p.end_text.trim().is_empty() {
            let e = timecode::parse(&p.end_text).ok_or("End time must look like 01:23:45, or be empty for the end.")?;
            if e <= start {
                return Err("End time must be after the start time.".into());
            }
            end = Some(e);
        }
        if let (true, Some(edge)) = (p.is_live_now, p.live_edge) {
            end = Some(end.map_or(edge, |e| e.min(edge)));
        }
        if let Some(d) = p.duration {
            if start >= d {
                return Err(format!("Start time is past the end of the video ({}).", timecode::format(d)));
            }
        }
        range = Range::Section { start, end };
    }
    let ffmpeg = ffmpeg.ok_or("ffmpeg is needed to cut and merge video, but was not found. Reinstall Vodsnip.")?;
    Ok(DownloadRequest {
        url: p.download_url.clone(),
        output_directory: p.output_dir.clone(),
        range,
        quality: p.quality,
        accurate_cuts: p.accurate_cuts,
        ffmpeg_path: Some(ffmpeg.to_string_lossy().into_owned()),
        cookies_path: Some(p.cookies.clone()),
        native_hls: p.is_live_now && p.mode != "range",
    })
}

#[tauri::command]
async fn start_download(
    app: AppHandle,
    state: State<'_, AppState>,
    params: DownloadParams,
    on_event: Channel<DownloadEvent>,
) -> Result<(), String> {
    let t = tools_for(&app)?;
    if state.busy.swap(true, Ordering::SeqCst) {
        return Err("A download is already running.".into());
    }
    state.cancelled.store(false, Ordering::SeqCst);
    let result = run_download(&app, &state, params, &t, &on_event).await;
    state.busy.store(false, Ordering::SeqCst);
    if let Err(message) = result {
        let _ = on_event.send(DownloadEvent::Failed { message });
    }
    Ok(())
}

async fn run_download(
    app: &AppHandle,
    state: &AppState,
    mut params: DownloadParams,
    t: &tools::Tools,
    on_event: &Channel<DownloadEvent>,
) -> Result<(), String> {
    if params.is_live_now {
        // "Now" is the moment you click Download, so read the length again.
        let fresh = video_info(app, &params.download_url, &params.cookies).await?;
        params.live_edge = fresh.duration;
        params.duration = fresh.duration;
        if let Some(seconds) = fresh.duration {
            let _ = on_event.send(DownloadEvent::Length { seconds });
        }
    }
    let request = make_request(&params, t.ffmpeg.as_ref())?;
    std::fs::create_dir_all(&params.output_dir).map_err(|e| format!("Could not create the save folder: {e}"))?;

    let mut file: Option<String> = None;
    let mut last_error: Option<String> = None;
    let path_env = tools::child_path(bundled_dir(app).as_deref());
    let status = runner::stream(&t.ytdlp, &request.arguments(), &path_env, &state.pid, |line| {
        if let Some(p) = progress::parse(&line) {
            let _ = on_event.send(DownloadEvent::Progress(p));
        } else if let Some(f) = line.strip_prefix(FILE_PREFIX) {
            file = Some(f.to_string());
        } else {
            if line.starts_with("ERROR") {
                last_error = Some(line.replace("ERROR: ", ""));
            }
            let _ = on_event.send(DownloadEvent::Log { line });
        }
    })
    .await
    .map_err(|e| format!("Could not start yt-dlp: {e}"))?;

    let event = if state.cancelled.load(Ordering::SeqCst) {
        DownloadEvent::Cancelled
    } else if status == 0 {
        DownloadEvent::Done { file }
    } else {
        DownloadEvent::Failed {
            message: last_error.unwrap_or_else(|| format!("Download failed (exit {status}). See the log.")),
        }
    };
    let _ = on_event.send(event);
    Ok(())
}

#[tauri::command]
fn cancel_download(state: State<'_, AppState>) {
    state.cancelled.store(true, Ordering::SeqCst);
    if let Some(pid) = *state.pid.lock().unwrap() {
        runner::kill_tree(pid);
    }
}

#[tauri::command]
fn tools_status(app: AppHandle) -> serde_json::Value {
    let t = tools::locate(bundled_dir(&app).as_deref());
    serde_json::json!({
        "ytdlp": t.as_ref().map(|t| t.ytdlp.to_string_lossy().into_owned()),
        "ffmpeg": t.as_ref().and_then(|t| t.ffmpeg.as_ref()).map(|p| p.to_string_lossy().into_owned()),
    })
}

/// Test hooks: VODSNIP_URL=<link> VODSNIP_MODE=range VODSNIP_AUTO=download[,cancel:<seconds>]
#[tauri::command]
fn startup_hooks() -> serde_json::Value {
    let get = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty());
    serde_json::json!({ "url": get("VODSNIP_URL"), "mode": get("VODSNIP_MODE"), "auto": get("VODSNIP_AUTO") })
}

#[tauri::command]
fn default_output_dir() -> String {
    let home = std::env::var_os("USERPROFILE").or_else(|| std::env::var_os("HOME")).map(PathBuf::from).unwrap_or_default();
    home.join(if cfg!(windows) { "Videos" } else { "Movies" }).join("Twitch").to_string_lossy().into_owned()
}

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .manage(AppState::default())
        .invoke_handler(tauri::generate_handler![
            fetch_video,
            start_download,
            cancel_download,
            tools_status,
            startup_hooks,
            default_output_dir
        ])
        .run(tauri::generate_context!())
        .expect("error while running Vodsnip");
}

#[cfg(test)]
mod tests {
    use super::*;

    fn params(mode: &str) -> DownloadParams {
        DownloadParams {
            download_url: "https://www.twitch.tv/videos/1".into(),
            mode: mode.into(),
            start_text: "00:00:10".into(),
            end_text: "".into(),
            quality: Quality::Source,
            accurate_cuts: false,
            output_dir: "/tmp".into(),
            cookies: "".into(),
            is_live_now: false,
            live_edge: None,
            duration: Some(100.0),
        }
    }

    #[test]
    fn range_validation() {
        let ff = PathBuf::from("/x/ffmpeg");
        assert!(make_request(&params("entire"), Some(&ff)).is_ok());
        assert!(make_request(&params("range"), None).unwrap_err().contains("ffmpeg"));
        let mut p = params("range");
        p.start_text = "nope".into();
        assert!(make_request(&p, Some(&ff)).unwrap_err().contains("Start time"));
        p.start_text = "00:01:00".into();
        p.end_text = "00:00:30".into();
        assert!(make_request(&p, Some(&ff)).unwrap_err().contains("after the start"));
        p.end_text = "".into();
        p.start_text = "00:05:00".into();
        assert!(make_request(&p, Some(&ff)).unwrap_err().contains("past the end"));
    }

    #[test]
    fn live_end_is_clamped_and_uses_native_hls() {
        let ff = PathBuf::from("/x/ffmpeg");
        let mut p = params("range");
        p.is_live_now = true;
        p.live_edge = Some(50.0);
        p.end_text = "00:10:00".into();
        let r = make_request(&p, Some(&ff)).unwrap();
        assert_eq!(r.range, Range::Section { start: 10.0, end: Some(50.0) });
        assert!(!r.native_hls);
        let mut q = params("startNow");
        q.is_live_now = true;
        assert!(make_request(&q, Some(&ff)).unwrap().native_hls);
    }

    #[test]
    fn picks_the_last_error_line() {
        assert_eq!(error_line("WARNING: x\nERROR: Video is private\n"), "Video is private");
    }
}
