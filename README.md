# BasicShell for Linux

This branch is the Linux version of BasicShell, kept apart from `main` (the
macOS app) and never merged into it: it shares no files and no history with
it.

What it is to be: the same small, quiet browser on Wayland, written in Rust
on WPE WebKit, with WebKit, GStreamer and FFmpeg shipped inside it, so it
asks nothing of the system beyond its graphics drivers, glibc, GLib and the
Wayland compositor. Built on Ubuntu 24.04, so it runs there and on anything
newer. There are no releases: builds are the Actions runs' artifacts.

So far: the engine and what it plays media with, put together into a folder
that runs, Rust bindings for WebKit, and the first of BasicShell itself, a
window with a page in it and a bar over the page.

## Trying it

From the newest run of the
[Package workflow](https://github.com/mbahakeskin/BasicShell/actions/workflows/package.yml),
download `basicshell-linux` (signed in to GitHub), unpack it anywhere and
run it:

    unzip basicshell-linux.zip && tar -xf basicshell-linux.tar.xz
    basicshell/bin/basicshell https://en.wikipedia.org

`basicshell/bin/minibrowser` is WebKit's own test browser, from the same
folder, to compare against.

WebKit's sandbox needs `bwrap` and `xdg-dbus-proxy` from the system
(`sudo apt install bubblewrap xdg-dbus-proxy` where they aren't there).
Tried on Ubuntu 26.04.1 (a bare system with only the libraries a GNOME
desktop has): pages over HTTPS, the sandbox, and H.264 with AAC, VP9 with
Opus, and AV1 video.

## WebKit

`webkit/build.sh` builds WPE WebKit, the release named in `webkit/VERSION`
(checked against the SHA-256 wpewebkit.org gives for it), with the patches
in `webkit/patches/`, and installs it into a folder that works wherever it is
put. `webkit/ci/install-deps.sh` installs what it is built with, Ubuntu
24.04's own packages: every version WebKit 2.54.1 asks for is met by them
(GLib 2.70: 2.80; HarfBuzz 2.7.4: 8.3.0; ICU 70.1: 74.2; libsoup 3.0: 3.4.4;
GStreamer 1.18.4: 1.24.2; Wayland 1.20: 1.22; GCC 12.2: 13.3, though it is
built with Clang 18; CMake 3.20: 3.28).

What is turned off: the old libwpe API (BasicShell uses WPEPlatform), the
DRM platform (it runs in a compositor), WebDriver and the documentation.
WebRTC is off, as WebKit has it for WPE.

The patch, `0001`: a build that isn't a developer build looks for its
processes only in the folder named when it was built, and its sandbox lets
in only that folder. With it, a WebKit that has been moved finds them from
where its library was loaded, and its sandbox is given the folder it is in.

It is built in GitHub Actions (`.github/workflows/webkit.yml`) whenever
something under `webkit/` changes on this branch, or from the Actions tab;
a build takes about two and a half hours.

### How far a build is

Next to the newest commit on the
[branch's commits page](https://github.com/mbahakeskin/BasicShell/commits/linux)
there is a status, "WebKit build", updated every minute:

    41% · 3328/8919 steps · 1:12 in · ~1:43 left · try 1

A click on it opens the run. The time left is a guess from the pace of the
last 20 minutes, shown after the first 15: the first thousands of steps take
seconds, WebCore's take minutes, and linking at the end takes a while.

A runner stops a job after six hours. The build stops itself after five,
keeps what the compiler has done, and starts the workflow again, which goes
on from there; four tries at most. A finished build is in the run's
artifacts, `wpewebkit-basicshell`, and starts the Package workflow.

Built on a computer of your own, it is the same script, with the progress in
`build/progress.txt`.

## Media

`media/build.sh` builds FFmpeg 7.1.5 (its tarball's signature checked
against FFmpeg's release key) and gst-libav 1.24.13, the GStreamer plugin
that hands FFmpeg's decoders to WebKit. FFmpeg is LGPL: no `--enable-gpl`,
no `--enable-nonfree` (which makes what is built unredistributable), shared
libraries, and only what decodes and demuxes; nothing that encodes, records
or goes on the network. That gives H.264, HEVC, AAC, VP8, VP9, Opus,
Vorbis, MP3 and the rest. Not AV1: gst-libav leaves out FFmpeg's AV1 decoder
and every decoder wrapping another library, so AV1 is GStreamer's own
(libaom), and VP8 and VP9 can also go through libvpx.

## The folder

`package/assemble.sh` puts WebKit, the media build and what they need from
Ubuntu 24.04 into `basicshell/`, and points every library and program in it
at the folder's `lib/` with a relative RPATH:

- GStreamer's plugins, those in `package/gstreamer-plugins.txt` (playback,
  the containers and parsers the web uses, libvpx, libaom, VA-API for the
  GPU's decoders, Web Audio, PulseAudio), its plugin scanner, and
  glib-networking's TLS module;
- every library those and WebKit ask for, followed from what each file asks
  for by name, except the ones in `package/system-libraries.txt`: glibc, the
  graphics drivers and Wayland, GLib, fontconfig and FreeType, D-Bus,
  systemd, ALSA and PipeWire, GnuTLS. Every desktop has those, newer
  versions keep working for what was built against older ones, and the
  system's own libraries load them too, so an older copy in the folder
  could take their place. What one of them needs in turn is not followed.

PulseAudio's client is shipped, though: GStreamer's plugin links its
versioned private library. glib-networking's proxy modules are not:
GNOME's ends the process where no GSettings schemas are installed;
BasicShell is to hand WebKit the proxy itself.

The folder is about 290 MB, 77 MB packed.

## BasicShell (rust/)

The browser, in Rust, on bindings for WPE WebKit made by gir (gtk-rs's
generator) from the `.gir` files WebKit's build writes (`rust/gir-files`):

- `sys/`: the C API as it is, one crate per library (WPEPlatform, its
  Wayland platform, JavaScriptCore, WebKit). `cargo test` builds C against
  WebKit's headers and checks every struct's size and layout and every
  constant against the Rust side.
- `wpe-platform`, `wpe-javascriptcore`, `wpe-webkit`: the safe API on
  glib-rs (objects, signals, properties), for the parts BasicShell uses, listed in each `Gir.toml`; a
  few functions gir can't translate are left out there, to write by hand
  when needed.
- `wpe-platform` also has what it takes to subclass WPEPlatform's Display,
  View and Toplevel from Rust (`subclass/`): a platform of one's own.
- `basicshell`: the program, on a platform of its own (`platform/`): its
  own Wayland connection (smithay-client-toolkit, read on GLib's main loop),
  one window whose surface the first view draws into and where every other
  view gets a subsurface over it, placed where BasicShell says (WebKit's
  own Wayland platform can't place its views, and the browser's interface
  is to sit over the page). WebKit's frames come as shared memory and are
  copied into the compositor's; pointer, wheel, touchpad and keyboard go to
  WebKit as its own events. So far one window with one page; tried in the
  headless compositor: a page, clicking, typing and scrolling. Still to
  come: the pointer's cursor shapes, key repeat, a screen's scale, and
  frames passed without a copy (DMA-BUF). It points WebKit, GStreamer and
  GIO at the folder it is in, and hands WebKit the proxy from the
  environment (`https_proxy` and the rest).
- Its interface (`ui/chrome.html`, `chrome.rs`) is a page too, in a second
  view over the first: transparent, and taking the pointer only where
  something of it is shown (the page says where, and BasicShell sets the
  subsurface's input region to that). The bar is hidden until the pointer
  touches the top edge, or Ctrl+L (also Alt+D, F6); back, forward, reload
  and the address, which takes an address or words to search for (Google,
  in the system's language and region, as on macOS: `address.rs`).
  Alt+Left and Alt+Right go back and forward, Ctrl+R and F5 reload. They
  talk through a script message handler one way and JavaScript the other.

`rust/regenerate.sh` makes the bindings again after WebKit is updated. They
are built in the Package workflow, against the WebKit build it packs.

## Looking at it without a screen

`tools/headless/start.sh` starts a screen nobody sees (sway on its headless
backend, rendering in software), with grim for pictures of it, a pointer
that stays (`tools/headless/vpointer.c`, on wlroots' virtual pointer), and
typing through wtype; `tools/rangeserver.py` serves files with the Range
requests WebKit's media player makes; `tools/pages/` has a page for input
and one with a video in each format (`make-videos.sh` makes them).

    eval "$(tools/headless/start.sh)"
    basicshell/bin/minibrowser file://$PWD/tools/pages/input.html &
    pointer move 420 245; pointer click; typetext "Merhaba"; grim shot.png
