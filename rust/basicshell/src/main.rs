//! BasicShell for Linux: one window of tabs with the sidebar over them, on
//! BasicShell's own Wayland platform.

mod address;
mod browser;
mod chrome;
mod folder;
mod platform;
mod proxy;
mod state;

use glib::prelude::*;

fn main() -> glib::ExitCode {
    // Before anything of GLib's or WebKit's starts: they read these once.
    folder::point_at_folder();

    let main_loop = glib::MainLoop::new(None, false);

    let display = platform::Display::new();
    if let Err(e) = wpe_platform::prelude::DisplayExt::connect(display.upcast_ref::<wpe_platform::Display>()) {
        eprintln!("basicshell: {e}");
        return glib::ExitCode::FAILURE;
    }
    let toplevel = platform::Toplevel::new(&display);
    let quit = main_loop.clone();
    toplevel.connect_close(move || quit.quit());

    let session = wpe_webkit::NetworkSession::new(
        Some(&folder::data_dir().to_string_lossy()),
        Some(&folder::cache_dir().to_string_lossy()),
    );
    proxy::apply(&session);

    let quit = main_loop.clone();
    let Some(browser) = browser::Browser::new(&display, &toplevel, session, move || quit.quit()) else {
        eprintln!("basicshell: WebKit made no view for the interface");
        return glib::ExitCode::FAILURE;
    };
    // The addresses given, each in a tab; none, the field for one.
    let addresses: Vec<String> = std::env::args().skip(1).collect();
    for typed in &addresses {
        if let Some(uri) = address::resolve(typed) {
            browser.open(&uri, false, None);
        }
    }
    if addresses.is_empty() {
        browser.ask_when_ready("new");
    }

    main_loop.run();
    glib::ExitCode::SUCCESS
}
