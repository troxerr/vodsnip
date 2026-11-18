//! Everything yt-dlp needs for one download. Mirrors the Mac app's DownloadRequest.
use crate::timecode;
use serde::Deserialize;

#[derive(Debug, Deserialize, Clone, Copy, PartialEq, Default)]
#[serde(rename_all = "lowercase")]
pub enum Quality {
    #[default]
    Source,
    P1080,
    P720,
    P480,
    P360,
    Audio,
}

impl Quality {
    fn selector(self) -> &'static str {
        match self {
            Quality::Source => "best",
            Quality::P1080 => "best[height<=1080]/best",
            Quality::P720 => "best[height<=720]/best",
            Quality::P480 => "best[height<=480]/best",
            Quality::P360 => "best[height<=360]/best",
            Quality::Audio => "Audio_Only/bestaudio/worst",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Range {
    Entire,
    /// Seconds from the start. `end` None means until the end.
    Section { start: f64, end: Option<f64> },
}

#[derive(Debug, Clone)]
pub struct DownloadRequest {
    pub url: String,
    pub output_directory: String,
    pub range: Range,
    pub quality: Quality,
    /// Re-encode at the cut points so they land on the exact second. Slower.
    pub accurate_cuts: bool,
    pub ffmpeg_path: Option<String>,
    pub cookies_path: Option<String>,
    /// For a recording that is still in progress: the native HLS downloader takes the fragments listed now and stops.
    pub native_hls: bool,
}

/// Marker yt-dlp prints once with the final file path.
pub const FILE_PREFIX: &str = "TGFILE ";
pub const PROGRESS_TEMPLATE: &str = "download:TGP %(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s|%(progress.fragment_index)s|%(progress.fragment_count)s";

impl DownloadRequest {
    fn file_suffix(&self) -> String {
        match &self.range {
            Range::Section { start, end } => {
                let end_text = end.map(timecode::file_safe).unwrap_or_else(|| "end".into());
                format!(" [{} to {}]", timecode::file_safe(*start), end_text)
            }
            Range::Entire => String::new(),
        }
    }

    pub fn arguments(&self) -> Vec<String> {
        let dir = self.output_directory.trim_end_matches(['/', '\\']);
        let mut a: Vec<String> = [
            // --print makes yt-dlp quiet, which hides progress lines; --progress turns them back on.
            "--no-playlist", "--newline", "--no-colors", "--no-simulate", "--progress",
            "--concurrent-fragments", "4", "--retries", "10", "--fragment-retries", "10",
            "-f", self.quality.selector(),
            "--progress-template", PROGRESS_TEMPLATE,
            "--print", &format!("after_move:{FILE_PREFIX}%(filepath)s"),
            "-o", &format!("{dir}/%(uploader)s - %(title).100B [%(id)s]{}.%(ext)s", self.file_suffix()),
        ]
        .iter()
        .map(|s| s.to_string())
        .collect();
        if self.quality != Quality::Audio {
            a.extend(["--merge-output-format".into(), "mp4".into()]);
        }
        if let Range::Section { start, end } = &self.range {
            let end_text = end.map(timecode::format).unwrap_or_else(|| "inf".into());
            a.extend(["--download-sections".into(), format!("*{}-{}", timecode::format(*start), end_text)]);
            if self.accurate_cuts {
                a.push("--force-keyframes-at-cuts".into());
            }
        }
        if self.native_hls {
            a.extend(["--downloader".into(), "m3u8:native".into()]);
        }
        if let Some(p) = &self.ffmpeg_path {
            a.extend(["--ffmpeg-location".into(), p.clone()]);
        }
        if let Some(c) = self.cookies_path.as_ref().filter(|c| !c.is_empty()) {
            a.extend(["--cookies".into(), c.clone()]);
        }
        a.push(self.url.clone());
        a
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn base() -> DownloadRequest {
        DownloadRequest {
            url: "https://www.twitch.tv/videos/1".into(),
            output_directory: "/tmp/out".into(),
            range: Range::Entire,
            quality: Quality::Source,
            accurate_cuts: false,
            ffmpeg_path: None,
            cookies_path: None,
            native_hls: false,
        }
    }

    #[test]
    fn entire() {
        let a = base().arguments();
        assert!(!a.contains(&"--download-sections".to_string()));
        assert_eq!(a.last().unwrap(), "https://www.twitch.tv/videos/1");
        assert!(a.contains(&"--merge-output-format".to_string()));
        // Without --progress, --print silences the progress lines the app reads.
        assert!(a.contains(&"--progress".to_string()));
    }

    #[test]
    fn section() {
        let r = DownloadRequest {
            range: Range::Section { start: 720.0, end: Some(2730.0) },
            accurate_cuts: true,
            ffmpeg_path: Some("C:/x/ffmpeg.exe".into()),
            cookies_path: Some("C:/c.txt".into()),
            ..base()
        };
        let a = r.arguments();
        let i = a.iter().position(|x| x == "--download-sections").unwrap();
        assert_eq!(a[i + 1], "*00:12:00-00:45:30");
        assert!(a.contains(&"--force-keyframes-at-cuts".to_string()));
        assert!(a.contains(&"C:/x/ffmpeg.exe".to_string()));
        assert!(a.contains(&"C:/c.txt".to_string()));
        assert!(a.join(" ").contains("[00-12-00 to 00-45-30]"));
    }

    #[test]
    fn open_ended() {
        let a = DownloadRequest { range: Range::Section { start: 60.0, end: None }, ..base() }.arguments();
        let i = a.iter().position(|x| x == "--download-sections").unwrap();
        assert_eq!(a[i + 1], "*00:01:00-inf");
    }

    #[test]
    fn audio_has_no_merge() {
        let a = DownloadRequest { quality: Quality::Audio, ..base() }.arguments();
        assert!(!a.contains(&"--merge-output-format".to_string()));
    }

    #[test]
    fn native_hls_for_live_recording() {
        let a = DownloadRequest { native_hls: true, ..base() }.arguments();
        let i = a.iter().position(|x| x == "--downloader").unwrap();
        assert_eq!(a[i + 1], "m3u8:native");
        assert!(!base().arguments().contains(&"--downloader".to_string()));
    }

    #[test]
    fn windows_dir_has_no_double_slash() {
        let a = DownloadRequest { output_directory: "C:\\Users\\me\\Videos\\Twitch\\".into(), ..base() }.arguments();
        let o = a.iter().position(|x| x == "-o").unwrap();
        assert!(a[o + 1].starts_with("C:\\Users\\me\\Videos\\Twitch/%(uploader)s"));
    }
}
