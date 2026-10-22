//! What was typed in the address field: a place to go, or words to search
//! for. The macOS app's Address.swift and Engine.swift, the same rules.

/// Schemes a page shows itself. Anything else with a scheme typed in is
/// treated as a search rather than handed to another program.
const OURS: [&str; 5] = ["http", "https", "file", "about", "data"];

/// An address for what was typed, or a search for it when it isn't one.
pub fn resolve(typed: &str) -> Option<String> {
    let text = typed.trim();
    if text.is_empty() {
        return None;
    }
    Some(url_from(text).unwrap_or_else(|| search(text)))
}

fn url_from(text: &str) -> Option<String> {
    if text.contains(char::is_whitespace) {
        return None;
    }
    if let Some((scheme, _)) = text.split_once("://") {
        return OURS.contains(&scheme.to_lowercase().as_str()).then(|| text.to_owned());
    }
    let lower = text.to_lowercase();
    if lower.starts_with("about:") || lower.starts_with("data:") {
        return Some(text.to_owned());
    }

    // It has to look like a host before it gets a scheme in front of it.
    let head = text.split(['/', '?', '#']).next().unwrap_or(text);
    if head.contains('@') {
        return None;
    }
    let host = head.split(':').next().unwrap_or(head);
    if !looks_like_host(host) {
        return None;
    }

    // A local server rarely has a certificate.
    let local = host == "localhost"
        || host.ends_with(".localhost")
        || host.ends_with(".test")
        || host == "127.0.0.1"
        || host == "0.0.0.0"
        || host.starts_with("192.168.")
        || host.starts_with("10.");
    Some(format!("{}{text}", if local { "http://" } else { "https://" }))
}

fn looks_like_host(host: &str) -> bool {
    if host == "localhost" {
        return true;
    }
    let labels: Vec<&str> = host.split('.').collect();
    if labels.len() == 4 && labels.iter().all(|l| l.parse::<u8>().is_ok()) {
        return true;
    }
    if labels.len() < 2 {
        return false;
    }
    let fine = |l: &&str| {
        !l.is_empty() && !l.starts_with('-') && !l.ends_with('-') && l.chars().all(|c| c.is_alphanumeric() || c == '-')
    };
    if !labels.iter().all(fine) {
        return false;
    }
    // Ending in letters is a domain; ending in digits is a version number.
    let tld = labels[labels.len() - 1];
    tld.chars().count() >= 2 && tld.chars().all(char::is_alphabetic)
}

/// The address as a person reads it: no scheme, no "www.", the path if
/// there is more than "/" (http and https; anything else as it is).
pub fn pretty(uri: &str) -> String {
    let Some(rest) = uri.strip_prefix("https://").or_else(|| uri.strip_prefix("http://")) else { return uri.to_owned() };
    let end = rest.find(['?', '#']).unwrap_or(rest.len());
    let rest = &rest[..end];
    let (host, path) = rest.split_at(rest.find('/').unwrap_or(rest.len()));
    let host = host.rsplit('@').next().unwrap_or(host);
    let host = host.strip_prefix("www.").unwrap_or(host);
    if path.is_empty() || path == "/" { host.to_owned() } else { format!("{host}{path}") }
}

/// A Google search, in the system's language and region: Google picks them
/// from the address the search comes from otherwise, another country
/// entirely behind a VPN. Google is the macOS app's default engine too.
fn search(words: &str) -> String {
    let mut address = format!("https://www.google.com/search?q={}", encode(words));
    if let Some((language, region)) = locale() {
        address += &format!("&hl={}", encode(&language));
        if let Some(region) = region {
            address += &format!("&gl={}", encode(&region));
        }
    }
    address
}

/// The language and region the system is set to, from the environment
/// ("tr_TR.UTF-8" is ("tr", Some("TR"))), as Google writes them.
fn locale() -> Option<(String, Option<String>)> {
    let value = ["LC_ALL", "LC_MESSAGES", "LANG"]
        .iter()
        .filter_map(|name| std::env::var(name).ok())
        .find(|v| !v.is_empty())?;
    let name = value.split(['.', '@']).next()?;
    if name == "C" || name == "POSIX" || name.is_empty() {
        return None;
    }
    let (language, region) = match name.split_once('_') {
        Some((l, r)) => (l.to_owned(), Some(r.to_owned())),
        None => (name.to_owned(), None),
    };
    let language = match (&*language, &region) {
        ("pt" | "zh", Some(r)) => format!("{language}-{r}"),
        _ => language,
    };
    Some((language, region))
}

/// Percent-encoding for a query value.
fn encode(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for byte in text.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => out.push(byte as char),
            _ => out += &format!("%{byte:02X}"),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn places() {
        assert_eq!(url_from("example.com").as_deref(), Some("https://example.com"));
        assert_eq!(url_from("en.wikipedia.org/wiki/Rust?x#y").as_deref(), Some("https://en.wikipedia.org/wiki/Rust?x#y"));
        assert_eq!(url_from("localhost:8000/a").as_deref(), Some("http://localhost:8000/a"));
        assert_eq!(url_from("192.168.1.1").as_deref(), Some("http://192.168.1.1"));
        assert_eq!(url_from("HTTP://x.org").as_deref(), Some("HTTP://x.org"));
        assert_eq!(url_from("about:blank").as_deref(), Some("about:blank"));
        assert_eq!(url_from("türkçe.com.tr").as_deref(), Some("https://türkçe.com.tr"));
    }

    #[test]
    fn searches() {
        for text in ["rust", "rust lang", "1.2.3", "ssh://host", "user@host.com", "-a.com", "a.c"] {
            assert_eq!(url_from(text), None, "{text}");
        }
        assert!(resolve("ç ğ").unwrap().starts_with("https://www.google.com/search?q=%C3%A7%20%C4%9F"));
        assert_eq!(resolve("  "), None);
    }

    #[test]
    fn pretty_addresses() {
        assert_eq!(pretty("https://www.example.com/"), "example.com");
        assert_eq!(pretty("https://en.wikipedia.org/wiki/Rust?x=1#y"), "en.wikipedia.org/wiki/Rust");
        assert_eq!(pretty("http://127.0.0.1:8765/a.html"), "127.0.0.1:8765/a.html");
        assert_eq!(pretty("about:blank"), "about:blank");
    }
}
