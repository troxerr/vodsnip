//! Reads the lines made by `request::PROGRESS_TEMPLATE`.
use serde::Serialize;

#[derive(Debug, Serialize, Clone, PartialEq, Default)]
pub struct Progress {
    /// 0..=1, None when yt-dlp does not know the total yet.
    pub fraction: Option<f64>,
    /// Bytes per second.
    pub speed: Option<f64>,
    /// Seconds left.
    pub eta: Option<f64>,
    pub downloaded_bytes: Option<f64>,
}

pub fn parse(line: &str) -> Option<Progress> {
    let rest = line.strip_prefix("TGP ")?;
    let f: Vec<Option<f64>> = rest.split('|').map(|s| s.trim().parse::<f64>().ok()).collect();
    if f.len() < 7 {
        return None;
    }
    let (downloaded, total, frag_index, frag_count) = (f[0], f[1].or(f[2]), f[5], f[6]);
    let fraction = match (frag_index, frag_count, downloaded, total) {
        (Some(i), Some(c), _, _) if c > 0.0 => Some(i / c),
        (_, _, Some(d), Some(t)) if t > 0.0 => Some(d / t),
        _ => None,
    };
    Some(Progress { fraction: fraction.map(|x| x.clamp(0.0, 1.0)), speed: f[3], eta: f[4], downloaded_bytes: downloaded })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fragments() {
        let p = parse("TGP 1000|NA|5000|2000000.5|12|3|10").unwrap();
        assert_eq!(p.fraction, Some(0.3));
        assert_eq!(p.speed, Some(2000000.5));
        assert_eq!(p.eta, Some(12.0));
    }

    #[test]
    fn bytes_only() {
        let p = parse("TGP 500|1000|NA|NA|NA|NA|NA").unwrap();
        assert_eq!(p.fraction, Some(0.5));
        assert_eq!(p.speed, None);
    }

    #[test]
    fn not_progress() {
        assert_eq!(parse("[download] hello"), None);
    }
}
