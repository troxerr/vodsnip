//! The parts of `yt-dlp -J` output the app uses.
use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq)]
pub struct VideoInfo {
    pub id: String,
    pub title: Option<String>,
    pub uploader: Option<String>,
    pub duration: Option<f64>,
    pub is_live: Option<bool>,
    pub thumbnail: Option<String>,
    pub webpage_url: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct VideoList {
    pub entries: Option<Vec<Entry>>,
}

#[derive(Debug, Deserialize)]
pub struct Entry {
    pub id: Option<String>,
    pub url: Option<String>,
}

impl VideoList {
    /// The newest video (Twitch lists newest first), as a watch URL.
    pub fn newest_url(&self) -> Option<String> {
        let e = self.entries.as_ref()?.first()?;
        if let Some(url) = &e.url {
            if url.starts_with("http") {
                return Some(url.clone());
            }
        }
        e.id.as_ref().map(|id| format!("https://www.twitch.tv/videos/{}", id.replace('v', "")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes() {
        let json = r#"{"id":"v1","title":"T","uploader":"U","duration":120.5,"is_live":false,"formats":[]}"#;
        let i: VideoInfo = serde_json::from_str(json).unwrap();
        assert_eq!(i.title.as_deref(), Some("T"));
        assert_eq!(i.duration, Some(120.5));
        assert_eq!(i.is_live, Some(false));
    }

    #[test]
    fn newest_entry() {
        let json = r#"{"entries":[{"id":"v99","url":"https://www.twitch.tv/videos/99"}]}"#;
        let l: VideoList = serde_json::from_str(json).unwrap();
        assert_eq!(l.newest_url().as_deref(), Some("https://www.twitch.tv/videos/99"));
    }
}
