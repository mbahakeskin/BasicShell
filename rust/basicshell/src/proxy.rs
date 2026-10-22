//! The proxy, handed to WebKit by BasicShell itself: GIO's own proxy modules
//! aren't shipped (GNOME's ends the process where no GSettings schemas are
//! installed). For now from the environment, as curl and most programs read
//! it; GNOME's and KDE's settings come later.

use std::env;
use wpe_webkit::{NetworkProxyMode, NetworkProxySettings, NetworkSession};

fn variable(names: &[&str]) -> Option<String> {
    names.iter().find_map(|name| env::var(name).ok()).filter(|value| !value.is_empty())
}

/// http_proxy, https_proxy, all_proxy and no_proxy (either case), or the
/// system's default (no proxy) when none is set.
pub fn apply(session: &NetworkSession) {
    let http = variable(&["http_proxy", "HTTP_PROXY"]);
    let https = variable(&["https_proxy", "HTTPS_PROXY"]);
    let all = variable(&["all_proxy", "ALL_PROXY"]);
    if http.is_none() && https.is_none() && all.is_none() {
        return;
    }
    let ignore = variable(&["no_proxy", "NO_PROXY"]).unwrap_or_default();
    let ignore: Vec<&str> = ignore.split(',').map(str::trim).filter(|h| !h.is_empty()).collect();
    let mut settings = NetworkProxySettings::new(all.as_deref(), &ignore);
    if let Some(uri) = &http {
        settings.add_proxy_for_scheme("http", uri);
    }
    if let Some(uri) = &https {
        settings.add_proxy_for_scheme("https", uri);
    }
    session.set_proxy_settings(NetworkProxyMode::Custom, Some(&settings));
}
