//! BasicShell for Linux. For now: one window, one page, from the address
//! given (or a start page), with a bar over it, on BasicShell's own Wayland
//! platform.

mod address;
mod chrome;
mod folder;
mod platform;
mod proxy;

use glib::prelude::*;
use wpe_webkit::prelude::*;

const START: &str = "https://duckduckgo.com";

fn main() -> glib::ExitCode {
    // Before anything of GLib's or WebKit's starts: they read these once.
    folder::point_at_folder();

    let address = std::env::args().nth(1).unwrap_or_else(|| START.to_owned());
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
    let settings = wpe_webkit::Settings::new();
    settings.set_enable_developer_extras(true);

    let view: wpe_webkit::WebView = glib::Object::builder()
        .property("display", display.upcast_ref::<wpe_platform::Display>())
        .property("network-session", &session)
        .property("settings", &settings)
        .build();
    let Some(wpe_view) = view.wpe_view() else {
        eprintln!("basicshell: WebKit made no view");
        return glib::ExitCode::FAILURE;
    };
    wpe_view.set_toplevel(Some(toplevel.upcast_ref::<wpe_platform::Toplevel>()));

    let window = toplevel.clone();
    view.connect_title_notify(move |view| {
        let title = view.title().filter(|t| !t.is_empty());
        window.set_title(Some(title.as_deref().unwrap_or("BasicShell")));
    });
    let quit = main_loop.clone();
    view.connect_close(move |_| quit.quit());

    // Over the page, so after it.
    let Some(_chrome) = chrome::Chrome::new(&display, &toplevel, &view) else {
        eprintln!("basicshell: WebKit made no view for the interface");
        return glib::ExitCode::FAILURE;
    };

    view.load_uri(&address::resolve(&address).unwrap_or(address));
    main_loop.run();
    glib::ExitCode::SUCCESS
}
