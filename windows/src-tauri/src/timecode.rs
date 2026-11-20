//! "HH:MM:SS" style times.

/// "90", "1:30", "01:02:03", "1:02:03.5" -> seconds. None when it is not a time.
pub fn parse(text: &str) -> Option<f64> {
    let t = text.trim();
    if t.is_empty() {
        return None;
    }
    let parts: Vec<&str> = t.split(':').collect();
    if parts.len() > 3 {
        return None;
    }
    let mut values = Vec::new();
    for p in &parts {
        // Digits and one dot only: Rust's f64 parser would also accept "inf", "1e3" and "+5".
        if p.is_empty() || !p.chars().all(|c| c.is_ascii_digit() || c == '.') {
            return None;
        }
        values.push(p.parse::<f64>().ok()?);
    }
    // Minutes and seconds after the first part must be under 60.
    if values.iter().skip(1).any(|v| *v >= 60.0) {
        return None;
    }
    let seconds = values.iter().fold(0.0, |acc, v| acc * 60.0 + v);
    seconds.is_finite().then_some(seconds)
}

/// 3725 -> "01:02:05".
pub fn format(seconds: f64) -> String {
    let total = seconds.max(0.0).round() as u64;
    format!("{:02}:{:02}:{:02}", total / 3600, (total % 3600) / 60, total % 60)
}

/// 3725 -> "01-02-05", safe inside a file name.
pub fn file_safe(seconds: f64) -> String {
    format(seconds).replace(':', "-")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses() {
        assert_eq!(parse("90"), Some(90.0));
        assert_eq!(parse("1:30"), Some(90.0));
        assert_eq!(parse("01:02:03"), Some(3723.0));
        assert_eq!(parse(" 0:00:10.5 "), Some(10.5));
    }

    #[test]
    fn rejects() {
        for bad in ["", "abc", "1:75", "1:2:3:4", "-5", "inf", "1e3", "+5", "1::2"] {
            assert_eq!(parse(bad), None, "{bad:?}");
        }
    }

    #[test]
    fn formats() {
        assert_eq!(format(3725.0), "01:02:05");
        assert_eq!(file_safe(3725.0), "01-02-05");
    }
}
