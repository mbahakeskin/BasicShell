//! Where BasicShell is: the folder it was unpacked into (basicshell/, with
//! this program in bin/), and where it keeps what it saves.

use std::env;
use std::path::PathBuf;

/// The folder: bin/basicshell's parent's parent.
pub fn root() -> PathBuf {
    let exe = env::current_exe().and_then(|p| p.canonicalize()).unwrap_or_default();
    exe.parent().and_then(|bin| bin.parent()).map(PathBuf::from).unwrap_or_default()
}

/// Points WebKit, GStreamer and GIO at what is in the folder instead of at
/// the system's (the same as lib/environment.sh does for MiniBrowser). Left
/// alone when the folder doesn't have them, as in a build tree.
pub fn point_at_folder() {
    let root = root();
    let lib = root.join("lib");
    let set = |name: &str, value: PathBuf| {
        if value.exists() {
            // SAFETY: called first thing in main, before any thread is started.
            unsafe { env::set_var(name, value) };
        }
    };
    set("WEBKIT_INJECTED_BUNDLE_PATH", lib.join("wpe-webkit-2.0/injected-bundle"));
    set("GST_PLUGIN_SYSTEM_PATH_1_0", lib.join("gstreamer-1.0"));
    set("GST_PLUGIN_SCANNER_1_0", root.join("libexec/gstreamer-1.0/gst-plugin-scanner"));
    set("GIO_EXTRA_MODULES", lib.join("gio/modules"));
    if lib.join("gstreamer-1.0").exists() {
        let registry = cache_dir().join("gstreamer-1.0-registry.bin");
        // SAFETY: as above.
        unsafe {
            env::set_var("GST_PLUGIN_PATH_1_0", "");
            env::set_var("GST_REGISTRY_1_0", registry);
        }
    }
}

fn xdg(variable: &str, fallback: &str) -> PathBuf {
    env::var_os(variable)
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| PathBuf::from(env::var_os("HOME").unwrap_or_default()).join(fallback))
        .join("basicshell")
}

pub fn data_dir() -> PathBuf {
    xdg("XDG_DATA_HOME", ".local/share")
}

pub fn cache_dir() -> PathBuf {
    xdg("XDG_CACHE_HOME", ".cache")
}
