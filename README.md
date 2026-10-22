# BasicShell for Linux

This branch is the Linux version of BasicShell, kept apart from `main` (the
macOS app) and never merged into it: it shares no files and no history with
it.

What it is to be: the same small, quiet browser on Wayland, written in Rust
on WPE WebKit, with WebKit, GStreamer and FFmpeg shipped inside it, so it
asks nothing of the system beyond its graphics drivers, glibc and the
Wayland compositor. Built on Ubuntu 24.04, so it runs there and on anything
newer. There are no releases yet.

So far there is only WebKit.

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
something under `webkit/` changes on this branch, or from the Actions tab.

### How far a build is

Next to the newest commit on the
[branch's commits page](https://github.com/mbahakeskin/BasicShell/commits/linux)
there is a status, "WebKit build", updated every minute:

    41% · 3328/8119 steps · 1:12 in · ~1:43 left · try 1

A click on it opens the run. The time left is a guess from the pace so far,
and the steps aren't alike: WebCore compiles slower than what comes before
it, and linking at the end takes a while.

A runner stops a job after six hours. The build stops itself after five,
keeps what the compiler has done, and starts the workflow again, which goes
on from there; four tries at most. A finished build is in the run's
artifacts, `wpewebkit-basicshell`, for 14 days.

Built on a computer of your own, it is the same script, with the progress in
`build/progress.txt`.
