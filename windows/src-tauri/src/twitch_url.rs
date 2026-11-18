//! What a pasted Twitch link points at.

#[derive(Debug, PartialEq, Clone)]
pub enum TwitchUrl {
    Vod(String),
    Channel(String),
    Other(String),
}

const RESERVED: [&str; 10] =
    ["videos", "directory", "downloads", "jobs", "turbo", "settings", "p", "store", "login", "signup"];

impl TwitchUrl {
    /// The address to hand to yt-dlp.
    pub fn canonical(&self) -> String {
        match self {
            TwitchUrl::Vod(id) => format!("https://www.twitch.tv/videos/{id}"),
            TwitchUrl::Channel(name) => format!("https://www.twitch.tv/{name}"),
            TwitchUrl::Other(s) => s.clone(),
        }
    }
}

pub fn parse(input: &str) -> Option<TwitchUrl> {
    let text = input.trim();
    if text.is_empty() {
        return None;
    }
    // A bare number is a VOD id; a bare word is a channel name.
    if text.chars().all(|c| c.is_ascii_digit()) {
        return Some(TwitchUrl::Vod(text.to_string()));
    }
    let is_name = (3..=25).contains(&text.len()) && text.chars().all(|c| c.is_ascii_alphanumeric() || c == '_');
    if is_name {
        return Some(TwitchUrl::Channel(text.to_lowercase()));
    }
    let with_scheme = if text.contains("://") { text.to_string() } else { format!("https://{text}") };
    let rest = with_scheme.split("://").nth(1)?;
    let rest = rest.split(['?', '#']).next()?;
    let (authority, path) = rest.split_once('/').unwrap_or((rest, ""));
    let host = authority.rsplit('@').next()?.split(':').next()?.to_lowercase();
    if host != "twitch.tv" && !host.ends_with(".twitch.tv") {
        return None;
    }
    if host.starts_with("clips.") {
        return Some(TwitchUrl::Other(with_scheme));
    }
    let parts: Vec<&str> = path.split('/').filter(|p| !p.is_empty()).collect();
    let first = *parts.first()?;
    if first == "videos" && parts.len() >= 2 && parts[1].chars().all(|c| c.is_ascii_digit()) {
        return Some(TwitchUrl::Vod(parts[1].to_string()));
    }
    if parts.len() >= 3 && parts[1] == "clip" {
        return Some(TwitchUrl::Other(with_scheme));
    }
    if RESERVED.contains(&first.to_lowercase().as_str()) {
        return None;
    }
    Some(TwitchUrl::Channel(first.to_lowercase()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vod() {
        assert_eq!(parse("https://www.twitch.tv/videos/123456"), Some(TwitchUrl::Vod("123456".into())));
        assert_eq!(parse("twitch.tv/videos/123456?t=1h2m"), Some(TwitchUrl::Vod("123456".into())));
        assert_eq!(parse("123456"), Some(TwitchUrl::Vod("123456".into())));
    }

    #[test]
    fn channel() {
        assert_eq!(parse("https://www.twitch.tv/Shroud"), Some(TwitchUrl::Channel("shroud".into())));
        assert_eq!(parse("https://twitch.tv/shroud/videos"), Some(TwitchUrl::Channel("shroud".into())));
        assert_eq!(parse("shroud"), Some(TwitchUrl::Channel("shroud".into())));
    }

    #[test]
    fn invalid() {
        assert_eq!(parse("https://example.com/videos/1"), None);
        assert_eq!(parse(""), None);
        assert_eq!(parse("https://www.twitch.tv/directory"), None);
        assert_eq!(parse("https://nottwitch.tv/shroud"), None);
    }

    #[test]
    fn clips_and_canonical() {
        assert!(matches!(parse("https://clips.twitch.tv/AbcDef"), Some(TwitchUrl::Other(_))));
        assert!(matches!(parse("https://www.twitch.tv/shroud/clip/AbcDef"), Some(TwitchUrl::Other(_))));
        assert_eq!(parse("shroud").unwrap().canonical(), "https://www.twitch.tv/shroud");
    }
}
