# shellcheck shell=sh
# Sourced with the folder's path in $BASICSHELL: points WebKit, GStreamer and
# GIO at what is in the folder rather than at the system's.
export WEBKIT_INJECTED_BUNDLE_PATH="$BASICSHELL/lib/wpe-webkit-2.0/injected-bundle"
export GST_PLUGIN_SYSTEM_PATH_1_0="$BASICSHELL/lib/gstreamer-1.0"
export GST_PLUGIN_PATH_1_0=""
export GST_PLUGIN_SCANNER_1_0="$BASICSHELL/libexec/gstreamer-1.0/gst-plugin-scanner"
export GST_REGISTRY_1_0="${XDG_CACHE_HOME:-$HOME/.cache}/basicshell/gstreamer-1.0-registry.bin"
export GIO_EXTRA_MODULES="$BASICSHELL/lib/gio/modules"
