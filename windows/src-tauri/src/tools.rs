//! Finds yt-dlp and ffmpeg: first the copies shipped inside the app, then the system.
use std::ffi::OsString;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
pub struct Tools {
    pub ytdlp: PathBuf,
    pub ffmpeg: Option<PathBuf>,
}

fn exe_name(name: &str) -> String {
    if cfg!(windows) { format!("{name}.exe") } else { name.to_string() }
}

/// Folders to search, in order. `bundled` is the app's own `bin` folder when it exists.
pub fn search_dirs(bundled: Option<&Path>) -> Vec<PathBuf> {
    let mut dirs: Vec<PathBuf> = bundled.map(|b| b.to_path_buf()).into_iter().collect();
    if let Some(path) = std::env::var_os("PATH") {
        dirs.extend(std::env::split_paths(&path));
    }
    // Developer machines (this app is also built and run on a Mac while it is written).
    #[cfg(target_os = "macos")]
    dirs.extend(["/opt/homebrew/bin", "/usr/local/bin"].map(PathBuf::from));
    dirs
}

pub fn find(name: &str, dirs: &[PathBuf]) -> Option<PathBuf> {
    let file = exe_name(name);
    dirs.iter().map(|d| d.join(&file)).find(|p| p.is_file())
}

/// None when yt-dlp is missing. ffmpeg may be None: cutting and merging then fail with a clear message.
pub fn locate(bundled: Option<&Path>) -> Option<Tools> {
    let dirs = search_dirs(bundled);
    let ytdlp = find("yt-dlp", &dirs)?;
    Some(Tools { ytdlp, ffmpeg: find("ffmpeg", &dirs) })
}

/// PATH for child processes, so yt-dlp finds ffmpeg and ffprobe.
pub fn child_path(bundled: Option<&Path>) -> OsString {
    std::env::join_paths(search_dirs(bundled)).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundled_dir_comes_first() {
        let dirs = search_dirs(Some(Path::new("/app/bin")));
        assert_eq!(dirs[0], PathBuf::from("/app/bin"));
    }

    #[test]
    fn missing_tool_is_none() {
        assert!(find("definitely-not-a-real-tool", &[PathBuf::from("/nonexistent")]).is_none());
    }
}
