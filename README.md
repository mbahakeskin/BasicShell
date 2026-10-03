# BasicShell

A small, quiet web browser for macOS 27, written in Swift on the WebKit that
ships with the Mac. No dependencies, no telemetry, nothing sent anywhere but
the pages you open.

- The page takes the whole window. Tabs live in a sidebar that comes out when
  the pointer reaches the left edge; back, forward, reload and the address
  come down from the top edge. Either can be pinned open (View menu).
- Full screen uses every pixel: the same bars, the same edges.
- A new tab starts as a field over the current page; the tab exists only
  once you enter an address or a search.
- Private tabs sit beside ordinary ones. They share one cookie jar that is
  kept only in memory, never on disk, and goes when the app quits; they are
  never saved in the session.
- Several windows, each with its own tabs.
- Ads and trackers, YouTube's ads included, are blocked by uBlock Origin
  Lite, the Safari extension that comes with its app from the App Store.
  BasicShell adds it when that app is on the Mac, running it from a copy of
  the app's files that keeps WebKit from compiling its rules anew at every
  launch; the first launch without it asks whether to get it, and with a
  yes it is added as soon as it is there (Settings › Privacy turns that off). Its button in the
  top bar turns it off for a site; removed, it stays removed.
- Tabs off screen are frozen: no script, no timers, nothing lost. After six
  hours off screen, or when memory runs short, a tab is unloaded and comes
  back where it was. Tabs holding unsent typing, sound or a call are left
  alone, and a site can be kept awake (the sun in the top bar).
- History, bookmarks, downloads and archived tabs, each a searchable panel
  over the page; the new-tab field suggests open tabs, bookmarks and history.
- Tabs opened from a link sit under the tab they came from.
- Picture in picture, the system's own: just the video, in a borderless
  window you can resize, the page staying where it is (`⇧⌘P`). A video
  playing goes into it by itself when you leave its tab or the window
  (another desktop, minimized), and comes back when you return.
- Google searches carry the Mac's language and region, so a VPN doesn't
  switch results to another country.
- Extensions on WebKit's own extension engine: from the Chrome Web Store
  (signature checked), from a folder, or a Safari extension loaded from
  inside the app it came with. Chrome extensions can talk to apps on this
  Mac the way they do in Chrome (Bitwarden's Touch ID through its desktop
  app).
- An address typed as http is tried over https first, falling back to http
  when the site has none; tracking parameters (`fbclid`, `gclid` and the
  like) come off the links you follow, from the list macOS keeps for Safari.
- Notifications from the sites you allow (WhatsApp, Gmail, Discord…) go to
  Notification Center; a click brings their tab forward. Each site asks once
  and is remembered (never for a private tab); Settings › Privacy takes it
  back. Only while the site is open in a tab: there is no push to a closed
  one.
- `⇧⌘C` copies the address.

Private WebKit features are used, each only where WebKit has it:
`_suspendPage:` freezes tabs off screen (Settings › Tabs turns it off);
`_persistedSites` keeps WebKit's tracking prevention from deleting an
extension's own storage, which would stop its background worker; and
`_setAllowsPictureInPictureMediaPlayback:` with a script run as though
clicked (`_callAsyncJavaScript:…withUserGesture:`) gives picture in picture,
and `_setWindowOcclusionDetectionEnabled:` keeps a page whose video is in it
awake on another desktop, for the captions to go on; and when an extension's background fails to
start again after macOS ended its process, `_backgroundWebView`,
`_webProcessIdentifier` and `_terminateServiceWorkers` let BasicShell end
the broken processes and start it afresh; and `_features` with
`_setEnabled:forFeature:` turn on `requestIdleCallback`, HTTPS first and
the removal of tracking parameters, which WebKit has but keeps off; `_setDeveloperExtrasEnabled:` puts Inspect Element in a
page's right-click menu, which `_webView:contextMenu:forElement:` lets
BasicShell arrange. Outside WebKit, SkyLight's `CGSCopyManagedDisplaySpaces` and
`CGSCopySpacesForWindows` tell which way you went to another desktop, for a
video to fly into picture in picture from that side.

What it can't do: passkeys. WebKit gives them to a browser only with an
entitlement Apple grants on request, tied to a paid Developer ID.

## Building

Needs macOS 27 and the Command Line Tools (Swift 6.4); Xcode is not required.

    ./build.sh          # build/BasicShell.app, ad-hoc signed

`swift build` alone builds the executable.

`build.sh` signs with a code-signing identity named "BasicShell Local Signing"
if the keychain has one (a self-signed certificate is enough), so macOS keeps
the app's permissions (location, camera, microphone) from build to build;
otherwise it signs ad hoc, and macOS asks again after each build.

## Network traffic

Besides the pages you open: nothing of BasicShell's own. uBlock Origin Lite's
lists come with its app, which the App Store keeps up to date. An extension you
add from the Chrome Web Store is fetched from Google, once.

The macOS 27 SDK turns SwiftUI's `@State` into a macro whose plugin ships only
with Xcode, so views here store `State` by hand instead of using the attribute.

## Credits

Parts of BasicShell (the address parser, the traffic-light
placement, the Safari user-agent handling and the WebSocket an extension's
worker gets) are adapted from
[Search](https://github.com/driceroland/Search) by Office Commun, under the
MIT license. See [LICENSE](LICENSE).
