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
- Ads and trackers are blocked with EasyList and EasyPrivacy, as WebKit
  content rule lists enforced before any request is made. The shield in the
  top bar turns blocking off for one site.
- Tabs off screen are frozen: no script, no timers, nothing lost. After six
  hours off screen, or when memory runs short, a tab is unloaded and comes
  back where it was. Tabs holding unsent typing, sound or a call are left
  alone, and a site can be kept awake (the sun in the top bar).
- History, bookmarks, downloads and archived tabs, each a searchable panel
  over the page; the new-tab field suggests open tabs, bookmarks and history.
- Tabs opened from a link sit under the tab they came from.
- Picture in picture: `⇧⌘P` lifts a video into a small window above
  everything.
- Google searches carry the Mac's language and region, so a VPN doesn't
  switch results to another country.
- Chrome extensions from the Chrome Web Store (signature checked) or a
  folder, on WebKit's own extension engine.
- `⇧⌘C` copies the address.

Two private WebKit features are used, each only where WebKit has it:
`_suspendPage:` freezes tabs off screen (Settings › Tabs turns it off), and
`_persistedSites` keeps WebKit's tracking prevention from deleting an
extension's own storage, which would stop its background worker.

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

## Block lists

The lists are not in the app. `./publish-lists.sh` fetches the latest
EasyList and EasyPrivacy, converts them (`Tools/BlockLists.swift`), signs
them with an Ed25519 key kept in `~/.config/basicshell/` (`Tools/SignLists.swift`)
and uploads them to this repository's `blocklists` release. The app downloads
them once, the first time it runs, and uses them only if the signature and
every file's hash check out; *BasicShell › Update Block Lists* fetches newer
ones. That, and the pages you open, is all the network traffic it makes.

The macOS 27 SDK turns SwiftUI's `@State` into a macro whose plugin ships only
with Xcode, so views here store `State` by hand instead of using the attribute.

## Credits

Parts of BasicShell (the address parser, the ad blocker, the traffic-light
placement and the Safari user-agent handling) are adapted from
[Search](https://github.com/driceroland/Search) by Office Commun, under the
MIT license. See [LICENSE](LICENSE).

The block lists are EasyList and EasyPrivacy by The EasyList authors
(https://easylist.to), GPLv3 / CC BY-SA 3.0.
