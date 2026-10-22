//! BasicShell for Linux. For now: one window, one page, from the address
//! given (or a start page), on WPE WebKit's own Wayland platform.

mod folder;
mod proxy;

use wpe_webkit::prelude::*;

const START: &str = "https://duckduckgo.com";

fn main() -> glib::ExitCode {
    // Before anything of GLib's or WebKit's starts: they read these once.
    folder::point_at_folder();

    let address = std::env::args().nth(1).unwrap_or_else(|| START.to_owned());
    let main_loop = glib::MainLoop::new(None, false);

    let session = wpe_webkit::NetworkSession::new(
        Some(&folder::data_dir().to_string_lossy()),
        Some(&folder::cache_dir().to_string_lossy()),
    );
    proxy::apply(&session);
    let settings = wpe_webkit::Settings::new();
    settings.set_enable_developer_extras(true);

    let view: wpe_webkit::WebView = glib::Object::builder()
        .property("network-session", &session)
        .property("settings", &settings)
        .build();

    let Some(wpe_view) = view.wpe_view() else {
        eprintln!("basicshell: WebKit has no view (is there a Wayland display?)");
        return glib::ExitCode::FAILURE;
    };
    let toplevel = wpe_view.toplevel();
    if let Some(toplevel) = &toplevel {
        toplevel.set_title(Some("BasicShell"));
        toplevel.resize(1280, 800);
    }

    view.connect_title_notify(move |view| {
        if let Some(toplevel) = &toplevel {
            let title = view.title().filter(|t| !t.is_empty());
            toplevel.set_title(Some(title.as_deref().unwrap_or("BasicShell")));
        }
    });
    let quit = main_loop.clone();
    view.connect_close(move |_| quit.quit());
    if let Some(display) = wpe_view.display() {
        let quit = main_loop.clone();
        display.connect_disconnected(move |_, _| quit.quit());
    }

    view.load_uri(&address);
    main_loop.run();
    glib::ExitCode::SUCCESS
}
