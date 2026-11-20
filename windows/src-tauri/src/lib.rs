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
use std::sync::Mutex;
use tauri::ipc::Channel;
use tauri::{AppHandle, Manager, State};
use tauri_plugin_opener::OpenerExt;
use tokio::sync::watch;
use twitch_url::TwitchUrl;

#[derive(Default)]
struct AppState {
    download: Mutex<Option<watch::Sender<bool>>>,
    saved_file: Mutex<Option<String>>,
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
    if smoke_url().as_deref() == Some(url.as_str()) {
        let info = video_info(&app, &url, "").await?;
        return Ok(Fetched { info, download_url: url, is_live_now: false, live_edge: None });
    }
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
    Started,
    /// A live recording's length, read again just before the download starts.
    Length { seconds: f64 },
    Progress(progress::Progress),
    Log { line: String },
    Done { file: String },
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
        if let Some(d) = p.live_edge.or(p.duration) {
            if start >= d {
                return Err(format!("Start time is past the end of the video ({}).", timecode::format(d)));
            }
            if p.is_live_now {
                end = Some(end.map_or(d, |e| e.min(d)));
            } else if end.is_some_and(|e| e > d) {
                return Err("End time must be within the video.".into());
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
) -> Result<DownloadEvent, String> {
    let t = tools_for(&app)?;
    let (cancel, mut cancelled) = watch::channel(false);
    {
        let mut download = state.download.lock().unwrap();
        if download.is_some() {
            return Err("A download is already running.".into());
        }
        *download = Some(cancel);
    }
    let _ = on_event.send(DownloadEvent::Started);
    let result = run_download(&app, params, &t, &on_event, &mut cancelled).await;
    let mut download = state.download.lock().unwrap();
    let was_cancelled = *cancelled.borrow();
    *download = None;
    match result {
        Ok(Some(DownloadEvent::Done { file })) => {
            *state.saved_file.lock().unwrap() = Some(file.clone());
            Ok(DownloadEvent::Done { file })
        }
        _ if was_cancelled => Ok(DownloadEvent::Cancelled),
        Ok(Some(event)) => Ok(event),
        Ok(None) => Ok(DownloadEvent::Cancelled),
        Err(message) => Ok(DownloadEvent::Failed { message }),
    }
}

async fn run_download(
    app: &AppHandle,
    mut params: DownloadParams,
    t: &tools::Tools,
    on_event: &Channel<DownloadEvent>,
    cancelled: &mut watch::Receiver<bool>,
) -> Result<Option<DownloadEvent>, String> {
    if params.is_live_now {
        // "Now" is the moment you click Download, so read the length again.
        let fresh = tokio::select! {
            biased;
            _ = cancelled.changed() => return Ok(None),
            result = video_info(app, &params.download_url, &params.cookies) => result?,
        };
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
    let status = runner::stream(&t.ytdlp, &request.arguments(), &path_env, cancelled, |line| {
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

    Ok(status.map(|status| match (status, file) {
        (0, Some(file)) if std::path::Path::new(&file).is_file() => DownloadEvent::Done { file },
        (0, _) => DownloadEvent::Failed { message: "The downloader finished, but Vodsnip could not find the saved file.".into() },
        (status, _) => DownloadEvent::Failed {
            message: last_error.unwrap_or_else(|| format!("Download failed (exit {status}). See the log.")),
        },
    }))
}

#[tauri::command]
fn cancel_download(state: State<'_, AppState>) {
    if let Some(cancel) = state.download.lock().unwrap().as_ref() {
        cancel.send_replace(true);
    }
}

#[tauri::command]
fn open_saved_file(app: AppHandle, state: State<'_, AppState>) -> Result<(), String> {
    let file = state.saved_file.lock().unwrap().clone().ok_or("No saved file is available.")?;
    app.opener().open_path(file, None::<&str>).map_err(|e| format!("Could not open the saved file: {e}"))
}

#[tauri::command]
async fn reveal_saved_file(app: AppHandle, state: State<'_, AppState>) -> Result<(), String> {
    let file = state.saved_file.lock().unwrap().clone().ok_or("No saved file is available.")?;
    tauri::async_runtime::spawn_blocking(move || {
        let path = std::path::Path::new(&file);
        if app.opener().reveal_item_in_dir(path).is_ok() {
            return Ok(());
        }
        let folder = path.parent().ok_or("The save folder is unavailable.")?;
        app.opener().open_path(folder.to_string_lossy(), None::<&str>)
            .map_err(|e| format!("Could not open the save folder: {e}"))
    })
    .await
    .map_err(|e| format!("Could not show the saved file: {e}"))?
}

#[tauri::command]
fn tools_status(app: AppHandle) -> serde_json::Value {
    let t = tools::locate(bundled_dir(&app).as_deref());
    serde_json::json!({
        "ytdlp": t.as_ref().map(|t| t.ytdlp.to_string_lossy().into_owned()),
        "ffmpeg": t.as_ref().and_then(|t| t.ffmpeg.as_ref()).map(|p| p.to_string_lossy().into_owned()),
    })
}

// The installed-app smoke test serves a local file so CI doesn't depend on Twitch.
fn smoke_url() -> Option<String> {
    std::env::var_os("VODSNIP_SMOKE_DIR")?;
    let url = std::env::var("VODSNIP_URL").ok()?;
    let parsed = tauri::Url::parse(&url).ok()?;
    (parsed.scheme() == "http" && parsed.host_str() == Some("127.0.0.1")
        && parsed.username().is_empty() && parsed.password().is_none()
        && parsed.path() == "/fixture.mp4").then_some(url)
}

/// Test hooks: VODSNIP_URL=<link> VODSNIP_MODE=range VODSNIP_AUTO=download[,cancel:<seconds>]
#[tauri::command]
fn startup_hooks() -> serde_json::Value {
    let get = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty());
    let dir = smoke_url().and_then(|_| get("VODSNIP_SMOKE_DIR"));
    serde_json::json!({ "url": get("VODSNIP_URL"), "mode": get("VODSNIP_MODE"), "auto": get("VODSNIP_AUTO"), "smokeDir": dir })
}

#[tauri::command]
fn report_smoke_result(result: serde_json::Value) -> Result<(), String> {
    smoke_url().ok_or("Smoke test is disabled.")?;
    let dir = std::env::var_os("VODSNIP_SMOKE_DIR").ok_or("Smoke test directory is missing.")?;
    let path = PathBuf::from(dir).join("result.json");
    let temp = path.with_extension("tmp");
    std::fs::write(&temp, result.to_string()).and_then(|_| std::fs::rename(temp, path)).map_err(|e| e.to_string())
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
            open_saved_file,
            reveal_saved_file,
            tools_status,
            startup_hooks,
            report_smoke_result,
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
        p.end_text = "00:02:00".into();
        assert!(make_request(&p, Some(&ff)).unwrap_err().contains("within the video"));
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
