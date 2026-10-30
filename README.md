# BasicShell

A small, quiet web browser for macOS 27, written in Swift on the WebKit that
ships with the Mac. No dependencies, no telemetry, nothing sent anywhere but
the pages you open (and, in a release build, a once-a-day look at GitHub for a
newer version, which Settings turns off).

- The page takes the whole window. Tabs live in a sidebar that comes out when
  the pointer reaches the left edge; back, forward, reload and the address
  come down from the top edge. Either can be pinned open (View menu). Or,
  in Settings › General, there is no top bar: the sidebar has the traffic
  lights, back and forward, the site (a click brings up its whole address
  over the page) and the site's buttons above the tabs; the extensions are
  in the Extensions menu, as in Arc.
- Full screen uses every pixel: the same bars, the same edges. On a screen
  with a notch the top bar runs through the strip the menu bar would have,
  the notch in its middle, and the window's corners are the screen's own;
  the menu bar and the Dock are macOS's own, hidden until the pointer
  presses against the top or the Dock's edge; a click anywhere else in the
  strip beside the notch is the page's. The menu bar moves the top bar down
  below it while it is there.
- A new tab starts as a field over the current page; the tab exists only
  once you enter an address or a search. Asked for with the New Tab row
  above the sidebar's tabs it goes first in the list, with the one below
  them, last.
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
  A word needn't be typed whole: its letters in order ("gthub"), or the
  initials of two words ("gh bs"), find it too, after what matches whole.
- The web cache is kept under a limit (Settings › Privacy, 250 MB unless
  changed) and emptied when it passes it; what an extension stored goes
  when the extension is removed.
- Tabs opened from a link sit under the tab they came from. Closing the tab
  shown goes back to the one shown before it, not to its neighbour.
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
- Find in the page (`⌘F`): a small field at the page's top right, every
  match marked and counted, `⌘G` and `⇧⌘G` for the next and the one before.
- Updates (the build with the agent tools, which is what releases are):
  BasicShell menu › Check for Updates…, and once a day by itself unless
  Settings › General turns that off, it asks github.com for the latest release
  and, if its version number is higher than the running one's (0.6.0 over 0.5.3;
  the time anything was built plays no part), offers it with its notes. Update
  and Restart downloads the zip, checks it against the SHA-256 GitHub gives for
  the file, opens it, checks that the app in it has this app's identifier and
  the release's version and that its signature holds together, then quits; a
  script puts the old app in the Trash and the new one in its place, and opens
  it. Nothing is installed without your say.
- `⇧⌘C` copies the address, and the pill that says so holds two buttons for
  a moment: a QR code of the address (a card under the pill, "Copy Image" for
  the code as a picture) and AirDrop.
- `⇧⌘R` copies the whole page, top to bottom, as one picture. Pictures that
  wait to be scrolled to are asked for first, the page is put back where it was,
  and the drawing runs off the main thread within a pixel budget (a very long
  page is drawn at less than full density, and says so).
- Reader (`⌥⌘R`, and a button in the top bar when the page has an article):
  the article on its own, light, sepia, dark or following the system, serif or
  sans, five sizes, three widths. The page is read, never touched: a script
  in an isolated world only reads, and hands back text made of a short list of
  tags (no scripts, styles, frames, forms or classes of the site's). That is
  shown in a second web view with JavaScript off and a content security policy
  that lets in nothing but pictures. Only a page that has an article offers it
  (a front page, a list, a bot check do not), found once the page has loaded,
  in a few milliseconds. Esc closes it; Find, links (`⌘`-click for a new tab)
  and `⇧⌘R` work in it.
- A speaker on a tab that makes sound, in the sidebar and the top bar, turns
  it off; Tab › Mute This Site keeps a site quiet (Settings › Tabs lists them).
- Downloads can be paused, resumed, cancelled and restarted, with the speed and
  the time left. A paused one, and the last hundred finished, are still there
  after BasicShell is quit; a server that cannot go on from the middle starts
  the file again.
- The lock at the left of the address (an "i" where the page isn't secure)
  brings up the site's information: how it was fetched and by whose
  certificate (with the system's own viewer), what it was allowed (location,
  notifications; each can be taken back), what it keeps on this Mac (its
  cookies and stored data, which can be removed), and its zoom. Zoom is kept
  by site: `⌘+`, `⌘−` and the panel's buttons set it, and it comes back
  whenever a tab goes to the site (never remembered from a private tab).
- Develop and Debug menus in the menu bar, as in Safari, out of sight until
  Settings › General turns them on. Develop: the Web Inspector, its console,
  a page's source and resources, picking an element on it, recording its
  timeline; the inspector of an extension's background page; the user agent a
  tab introduces itself with (an iPhone, an iPad, Chrome, Firefox, or one
  typed in, which is remembered), a phone's, a tablet's or a typed-in size,
  a light or dark look; a tab without JavaScript, images or styles, without
  the same-origin policy, or without the limits on what a file may read; emptying the
  caches; WebKit's experimental features. Debug: WebKit's internal debugging
  features (compositing borders, repaint counters, the resource usage
  overlay…), the web process's number and crashing it, the page as a web
  archive. What is switched in them is kept and put on the pages opened
  after; "Reset All WebKit Features to Defaults" takes it back. Safari's own
  Debug menu has more (iCloud, CloudKit, AutoFill); that is Safari's, not
  WebKit's.
- In a build made with the agent tools (what a release is, or
  `./build.sh agent`), AI agents can use it when you turn that on: Claude Code,
  the Claude app, Antigravity or any other that speaks the Model Context
  Protocol get tools for the tabs and the pages in them. See
  [Agents](#agents). The plain build has none of it.

Private WebKit features are used, each only where WebKit has it:
`_suspendPage:` freezes tabs off screen (Settings › Tabs turns it off);
`_persistedSites` keeps WebKit's tracking prevention from deleting an
extension's own storage, which would stop its background worker; and
`_setAllowsPictureInPictureMediaPlayback:` with a script run as though
clicked (`_callAsyncJavaScript:…withUserGesture:`) gives picture in picture,
and `_setWindowOcclusionDetectionEnabled:` keeps a page whose video is in it
awake on another desktop, for the captions to go on (and a page an agent works
in, while it does); and when an extension's background fails to
start again after macOS ended its process, `_backgroundWebView`,
`_webProcessIdentifier` and `_terminateServiceWorkers` let BasicShell end
the broken processes and start it afresh; and `_features` with
`_setEnabled:forFeature:` turn on `requestIdleCallback`, HTTPS first and
the removal of tracking parameters, which WebKit has but keeps off; `_setDeveloperExtrasEnabled:` puts Inspect Element in a
page's right-click menu, which `_webView:contextMenu:forElement:` lets
BasicShell arrange; `_setPageMuted:` and a key-value observer on `_isPlayingAudio` for the speaker
and its mute; `WKDownload`'s resume data for a paused download;
`_findString:options:maxCount:` with a `_findDelegate`
marks and counts what is looked for in a page (`_hideFindUI` takes the marks
away); the Develop and Debug menus: `_inspector` (`show`, `showConsole`,
`toggleElementSelection`, `showMainResourceForFrame:` with `_mainFrame`) for
a page's and an extension background's inspector, `_experimentalFeatures`,
`_internalDebugFeatures` with `_isEnabledForFeature:` and
`_setEnabled:forFeature:` for the features, `_setAuthorAndUserStylesEnabled:`
for a tab without styles, `_killWebContentProcess` and
`_webProcessIdentifier` for the web process. Outside WebKit, SkyLight's `CGSCopyManagedDisplaySpaces` and
`CGSCopySpacesForWindows` tell which way you went to another desktop, for a
video to fly into picture in picture from that side.

What it can't do: passkeys. WebKit gives them to a browser only with an
entitlement Apple grants on request, tied to a paid Developer ID.

## Building

Needs macOS 27 and the Command Line Tools (Swift 6.4); Xcode is not required.

    ./build.sh          # build/BasicShell.app, ad-hoc signed
    ./build.sh agent    # the same with the agent tools (see Agents, below)

`swift build` alone builds the executable (`-Xswiftc -DAGENT` for the one
with the agent tools).

`build.sh` signs with a code-signing identity named "BasicShell Local Signing"
if the keychain has one (a self-signed certificate is enough), so macOS keeps
the app's permissions (location, camera, microphone) from build to build;
otherwise it signs ad hoc, and macOS asks again after each build.

## Agents

Anthropic's own extension, Claude in Chrome, drives pages through Chrome's
debugger, which WebKit's extensions don't have. BasicShell offers the same
things itself, as tools over the Model Context Protocol, with no key and no
account of its own: whichever agent you already use calls them (Claude Code,
the Claude app, Antigravity, or any other MCP client).

It is in the build only when asked for: `./build.sh agent`, which is also what
a release is (from 0.6.0 on, a release has this build alone). The plain build,
`./build.sh`, has no part of it, not the Settings page, not the code.

Turn it on in Settings › Agents, then connect from there: a button adds
BasicShell to Claude Code (or copies the command, `claude mcp add --scope
user basicshell -- …/BasicShell.app/Contents/MacOS/BasicShell --mcp`), another
writes it into the Claude app's settings, another into Antigravity's
(`~/.gemini/config/mcp_config.json`, which its command line, `agy`, and its
editor share), and a last one copies the entry for any other agent. The agent
starts BasicShell's own program with `--mcp`; that speaks the protocol and
passes each call to the running browser over a socket in its folder that only
your user can open.

The agent is handed a short list: each tool's name, a line and its
parameters (about 17,000 characters for 48 tools, where 29,000 were for 42).
The whole description of any tool, what each parameter means and the limits,
is one call away: `help` (with `tool`; without, the list). Settings › Agents ›
Connect also writes a skill for Claude Code (`~/.claude/skills/basicshell`)
on how to work in BasicShell without wasting turns.

The tools:

- `tabs`, `open`, `close`, `select`, `navigate`: the tabs in every window,
  asleep ones too (one is woken when an agent reads it). An address is a web
  page's or a file on this Mac's (`file://`, or a path). Every file counts as
  one site, "files on this Mac", asked about once like any other and listed in
  Settings with the sites; with bypass on, any file opens, unasked.
- `read_text`, `read_page`, `find`, `screenshot`: a page's text, what on it
  can be clicked or filled (each with a number to refer to it by), and a
  picture of it. A long page is read in windows (`offset`): the answer says
  which lines it has and where the rest is, so nothing is cut unsaid. `find`
  takes several things at once, puts the closest names first, says where
  controls that are called the same are (the card a button is on), and takes
  a regular expression; when it finds nothing it lists what the page has. A
  page that is not in English says what language it is in. Under an open
  dialog the controls behind it are marked, and a part of the page that
  scrolls by itself is said, with a point to scroll from.
- `click`, `hover`, `type`, `key`, `scroll`, `fill`: made as AppKit's own
  events and handed to the page's view, so the page takes them for real
  ones, the pointer stays where you have it, and it all works in a tab
  behind the one you are looking at.
- Fewer round trips, so the agent waits less on its own thinking: what a
  click, a key or a fill did comes back with it (what appeared, went or
  changed among the things that can be clicked or filled, or, on a new
  page, what is on it), `open` and `navigate` list what is on the page,
  `fill_form` fills a whole form and `search` uses the site's search in one
  call, and `read_pages` reads up to 25 addresses in one call, in tabs of
  their own (without pictures, video or fonts), then closes them: as many at
  once as the Mac is good for (half its cores, 5 at most, fewer when it is
  hot or saving power), and the next begins as soon as any one has finished.
- Nothing is waited for by guessing how long it takes. Input is given to the
  page and the call goes on when the page has said it took it (a listener in
  the page, since WebKit queues input events and a message sent after them
  could pass them); a load by the load's own events (the tab says when it
  begins and ends loading, also for a navigation a click decided on); `wait`
  and `expect` by a `MutationObserver` that wakes them when the page changes,
  not by looking every so often; a dialog, a file chooser and a download by
  theirs. What is left is a watchdog (for the event that never comes) and the
  one thing with no event of its own, whether a click's effects are over. That
  was a window of 150 ms without a change in the page; it is now a tracker put
  in the page (in its own world, the first time an agent acts in a document,
  so a page nobody works in pays nothing: about 0.1 microsecond more per
  timer). What was going on when the action began is background; what is
  started after it, by it or by anything it started (a timer up to 0.6 s, a
  frame, a request and its body, a transition, a picture), is waited for until
  it has run, then two turns of the page's event loop and 30 ms of no change.
  Tried against the window on 17 patterns of page reaction (a timer of 50 to
  400 ms, a chain of two, a fetch, a chain of fetches, an XHR, a picture, a
  transition, a debounce, a ticking clock): the window missed 31 of 85 runs
  (everything that reacted later than 150 ms after its last change) and
  waited 107 ms too long on average; the tracker missed none and waited 43.
  A page that does nothing is quiet in 40 ms, not 150. A request is waited for
  at most 0.4 s from when it began (a reaction fetches and renders within
  that; a beacon goes on much longer), the whole wait at most 0.5 s. A wait
  that went past the old 150 ms with something pending and then ended with no
  change at all was wasted: after two of those in a document, or two caps in
  a row with new work still starting, that document is noisy and gets the old
  window from then on (so the old 150 ms is the fallback, reached by what the
  page has shown rather than assumed up front: a cap of 150 from the start
  missed 33 of 64 reactions in the lab). What was still pending at a cap is
  background from then on.
  Limits: the main frame's timers only (another site's frame is covered by the
  30 ms), no sight of messages between tasks or of sockets, and the cap is paid
  when something pending never ends. With `expect` the call waits for what it
  names, not for this. It puts code in the pages an agent works in (timers,
  frames, `fetch` and XHR wrapped by proxies, so a page that asks a function
  for its source is told "[native code]", and found under a symbol, not a
  named global; nothing in other pages, and not in a page that has a password
  or card field, which are the ones that look hardest at what runs in them);
  Settings › Agents › Waiting chooses another way (`settle` lets an agent
  choose, until BasicShell quits: it is told it may switch when an action
  comes back too early or late, or a page seems to mind the script):
  the Web Inspector, which puts nothing in the page, or the old 150 ms
  window. A determined detector can still tell the tracker
  (the proxy's source reads `function ProxyObject() { [native code] }`, and
  one symbol is on `window`).
- The Web Inspector way: a hidden inspector is connected to the tab the agent
  acts in (WebKit's `_inspector`), and what WebKit's own instruments say (timers
  set and fired, frames asked for, requests, layout and paint) is read from the
  inspector's page, BasicShell's own, whose connection is hooked so that the
  frontend records nothing and BasicShell is told only when it has decided.
  A finite CSS animation is asked for the way the inspector's console would
  (read only). The debugger is off, so a `debugger;` statement stops nothing;
  the page can tell it is being inspected, as with Safari's inspector open.
  On the lab of 17 patterns, through the agent's own clicks: none returned
  early, 47-86 ms after the page's own end (the tracker, 34-46 ms). It costs
  about 130 MB for each tab worked in, and 0.2 s the first time in a tab;
  the connection closes 8 s after the last action and WebKit gives the
  process back within a minute.
  A click is 0.04 s (it was 0.23; 0.16 with events alone), a hover 0.04
  (0.27), a `type` 0.04 (0.30), a read of a tab that was asleep 0.09 (0.35),
  and the default report now sees what a page adds 400 ms after a click, or
  after a fetch, where it did not.
- The browser is not held up for the agent: pictures are drawn and encoded on
  another thread at utility priority (a screenshot stalled the main thread for
  95 ms, an overview for 250; now 0), answers are written to the socket from
  another thread, and the socket's buffers are a megabyte, not a few
  kilobytes.
- The frame and the pill ("Agent at work", with Stop) show while the agent is
  at work in the tab shown, say "Agent done" 10 seconds after its last call
  (or at once when its program goes), and are gone 3 seconds later; the tab is
  let go after 2 minutes, not 10, each by a timer set when a call ends.
- A picture is the agent's to size: `screenshot` takes `max_width`
  and `quality`, `marks` (the refs drawn on what can be clicked, to answer
  with a number), and `full_page` with `tile` (one view of a long page at a
  time, 77 on a long article) or `overview` (all of it: a page too tall for
  one strip is laid out in numbered columns side by side, so it can still be
  read). A `region` or a `tile` is clickable too: its positions are in its own
  pixels, with the `picture` number the answer gives. `marks` keeps its
  numbers off each other and, with a `region`, draws only what is in it.
- Naming a thing without a ref: `click`, `hover`, `drag`, `type`, `fill`,
  `fill_form` and `scroll` take a `label` (what it says), or a CSS `selector`,
  with `role` and `nth`, looked for when the call is made, so one `batch` can
  go to a page, search and click. `expect` (`text`, `gone`, `selector`,
  `url_contains`) on an acting tool waits for the page to be so and fails if it
  is not. A number the page replaced by another of the same kind (a search box
  rebuilt as you type) still leads to the new one. `hover` says what
  appeared. `evaluate` takes `args`, values that need no quoting in the code.
- Calls that arrive together run together: a tool call is written to the
  socket as it comes and answered by its id, so an agent that sends three
  calls in a turn waits for the slowest, not the sum (three 2 s waits: 2.4 s,
  not 7.3). Calls that change or picture the same tab take turns (three
  clicks sent at once all landed, one after another); another tab goes on at
  once.
- `api` (developer tools): the fetch and XHR calls the page made, and what one
  gives, repeated as the tab's own session: its JSON as a shape and sample,
  or, with `path` and `fields`, just the values, one row each
  (`data.items[*]`, `[name, price.value]`). A site's own data instead of
  scraping its page; only GET is repeated, only the page's own site or what
  the page itself called, and a path that names a token or password is
  refused. `read_page` with `since_last` says only what changed since the last
  `read_page` of that page. `batch` actions may be `optional` (go on if they
  fail) or `repeat` (until they fail: click Load more until it is gone).
- Reading less: `tabs` takes `from_tab`/`to_tab`, `yours`, `query` and
  `window`, and cuts long addresses; `read_text` takes `selector` or `main`,
  and `structured` gives the products a page declares (name, price, stock;
  JSON-LD, microdata, meta tags) or, failing that, a guess from the cards that
  show a price. `open` and `navigate` list the first 15 controls.
- `upload` (you are asked each time, with the files named), `dialog` (a
  page's alert, confirm or prompt, which Claude in Chrome can't get past), `wait`,
  `save_page` (PDF or web archive, into Downloads), `record` (a GIF of the
  tab).
- `drag` (sliders, sortable lists, canvases, text selection: the same real
  events; a page that uses the browser's own drag and drop may not take it),
  `screenshot` with a `region` (enlarged, to read small print), `key` with a
  `repeat`, and `batch` (several tools in one call, stopping at the first
  that fails).
- `resize`: the window's size (a phone's or a tablet's, or any), the light or
  dark look the page is told of, the zoom, and the way the browser introduces
  itself to sites (a phone's or a tablet's, or any user agent given). It changes your window, and `desktop` puts it back; there
  is no touch emulation in WebKit.
- More of the page: `site_info` (whether the connection is secure, the
  certificate's holder, issuer and expiry, what the person allowed the site,
  its cookie count, the zoom, how the tab is set), `selection` (what you have selected), `screenshot` of
  the whole page (`full_page`), `wait` for text, a CSS selector, the address
  or a quiet network, `download` (into Downloads, asked each time), and
  `navigate` with `hard_reload`.
- Each off until you turn it on in Settings › Agents: `arrange` (pin,
  duplicate, sleep, move a tab, take it to a window), `clipboard`,
  `extensions` (list, reload, the problems WebKit reports for them, and with
  the developer tools on, what a background page writes to the console),
  `history`, `bookmarks`, `downloads`.
- For developers, behind "Developer tools": `console`, `network`, `evaluate`,
  `inspect` (an element's styles, box and HTML), `performance` (load timings,
  paints, slowest requests) and `block` (keep a tab from loading requests
  that match), `render` (a tab without its JavaScript, images or styles,
  put back when the agent lets the tab go) and `source` (a page as the site sent
  it, before its scripts ran; password and card fields' values replaced by
  `[hidden]`). Three more switches under it: request and response bodies in
  `network` (passwords, tokens, keys and cookies replaced by `[hidden]`), and
  `storage` (cookies, local and session storage, databases; a value only
  when asked, never an HttpOnly cookie's; clearing is asked first), and
  `features` (WebKit's experimental and debugging features, the same as the
  Develop and Debug menus' ones; a change lasts while an agent is connected and
  is taken back when it goes, and whatever touches privacy or security
  stays the person's alone).

What keeps it yours:

- Off until you turn it on. A private tab is never listed, read or touched.
- Each site is asked about, once to read it and once to click and type
  there; an answer can be remembered, and Settings › Agents lists those.
- What is in a password, card or one-time-code field is never given, and
  nothing is typed into one, a card form in a frame from another site
  included. Signing in and paying stay yours.
- A tab an agent works in is marked in the sidebar and framed while it is the
  one shown, with a Stop button: everything is let go, and nothing more is
  done until you say so.

Settings › Agents says what each part allows, in words, and lets you set a
site (read, read and ask before clicking, read only, read and act, or never),
add one before an agent asks, and see what agents have done since BasicShell
opened.

It has a switch, "Bypass permissions", that turns the asking off, for work
you are watching: every site is then open to the agent, and so is any file on
this Mac, files go to pages, come down from them, and cookies are cleared,
unasked; what a page it works in asks (your location, to show notifications,
to open another app) is answered no, unasked; and every switch above
(clipboard, tabs, extensions, history, developer tools, bodies, storage,
WebKit features) is on while it is. The sites you said no to stay closed,
private tabs and password and card fields stay out of its reach, what
touches privacy or security among WebKit's features stays the person's, and
Stop still stops it.

A page can still try to talk an agent into things with text you don't see.
Asking per site and the Stop button are there for that; Anthropic's own
extension also checks each action with a classifier of theirs, which this
does not have. Keep it to sites you trust.

A frame from another site is reached by the picture and by position only:
its text and fields aren't listed.

### Against Claude in Chrome

Compared by the tools each has (Claude in Chrome's from its own list), this
does more in these ways:

- **The browser itself, not only the page.** `history`, `bookmarks` and
  `downloads`; `clipboard`; `arrange` (pin, copy, sleep, move a tab, take it
  to a window); `extensions` (list, reload); `save_page` (PDF or web
  archive); a whole-page picture; the text you have selected. Claude in
  Chrome has none of these, and reaches only the tabs in the group it opens.
- **A page's own questions.** `dialog` answers an alert, confirm or prompt,
  which stops a page until someone does; Claude in Chrome has no tool for
  them and is advised to steer clear of pages that raise them.
- **Tabs behind the one you look at, and asleep ones.** Clicks, keys and
  typing are AppKit's own events, handed to the page's view: the page takes
  them for real ones, your pointer and your window stay where they are, and
  a frozen tab is woken when an agent reads it.
- **More for developers**, behind their own switches: a request's headers and
  bodies with secrets replaced, `storage` (cookies, local and session
  storage, databases), `inspect` (an element's styles, box and HTML),
  `performance` (load timings, paints, slowest requests), `block` (keep a
  tab from loading requests that match), `render` (a tab without its
  JavaScript, images or styles), `source` (the page as the site sent it),
  `site_info` (connection, certificate, what was allowed), WebKit's own
  experimental and debugging `features`, an extension's problems and
  background console, any user agent, and a hard reload.
- **Finer say over it.** A switch for each part, a setting per site (read,
  read only, read and act, never; added before an agent asks), a list of what
  agents did, one Bypass switch for all of it, and a Stop button on the
  page's frame.
- **Nothing to install** in a browser, no account or key, no extension that
  has to see every page: BasicShell's own program is the server, and the
  plain build has none of it.

Claude in Chrome is still ahead in these:

- It works through Chrome's debugger, so it can emulate devices truly (touch,
  throttled networks, screen metrics); WebKit has no such thing, and
  `resize` changes the window's size, the look the page is told of, the zoom
  and the user agent only.
- Each of its actions is checked by a classifier of Anthropic's; this has
  none.
- It is Chrome: pages built and tested for Chrome, your Chrome profile and
  its sign-ins, and Anthropic keeps it up to date. It has saved shortcuts and
  workflows, and can drive several browsers. This is one person's small
  browser.
- Dragging that uses the browser's own drag and drop (a file or a link
  dragged between things) works there and may not here.

## Network traffic

Besides the pages you open: nothing of BasicShell's own. uBlock Origin Lite's
lists come with its app, which the App Store keeps up to date. An extension you
add from the Chrome Web Store is fetched from Google, once. What an agent reads
of a page, when you let it, goes to that agent, which is to say whoever runs it (Anthropic for
Claude, Google for Antigravity), like
anything else you show it.

The macOS 27 SDK turns SwiftUI's `@State` into a macro whose plugin ships only
with Xcode, so views here store `State` by hand instead of using the attribute.

## Credits

Parts of BasicShell (the address parser, the traffic-light
placement, the Safari user-agent handling and the WebSocket an extension's
worker gets) are adapted from
[Search](https://github.com/driceroland/Search) by Office Commun, under the
MIT license. See [LICENSE](LICENSE).
