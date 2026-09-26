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
- Private tabs sit beside ordinary ones, each with its own cookie jar that
  goes when the tab closes.
- Several windows, each with its own tabs.
- Ads and trackers are blocked by a WebKit content rule list before any
  request is made.
- `⇧⌘C` copies the address.

## Building

Needs macOS 27 and the Command Line Tools (Swift 6.4); Xcode is not required.

    ./build.sh          # build/BasicShell.app, ad-hoc signed

`swift build` alone builds the executable.

The macOS 27 SDK turns SwiftUI's `@State` into a macro whose plugin ships only
with Xcode, so views here store `State` by hand instead of using the attribute.

## Credits

Parts of BasicShell (the address parser, the ad blocker, the traffic-light
placement and the Safari user-agent handling) are adapted from
[Search](https://github.com/driceroland/Search) by Office Commun, under the
MIT license. See [LICENSE](LICENSE).
