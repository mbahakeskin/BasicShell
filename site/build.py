#!/usr/bin/env python3
"""Builds the single-file site: site/index.html from site/src/*.

    python3 site/build.py            # writes site/index.html
    FONT=/path/to/latin.woff2 python3 site/build.py

The font (Google Sans Flex, SIL Open Font License, the latin subset with the
width, weight and roundness axes) is embedded as base64, so the file works
offline and nothing is fetched when it is opened."""
import base64, html, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "src")
NAME = "Backlight"   # one place to change the name
VERSION = "0.9.1"
SIZE = "2.0 MB"      # the release zip

def esc(s): return html.escape(s, quote=False)

# ---- Features -------------------------------------------------------------
FEATURES = [
 ("edges", "Windows and edges", "", [
  ("The page takes the whole window", "", "Tabs sit in a sidebar and the address in a top bar. Both slide in when the pointer reaches their edge, and either can be pinned open."),
  ("Sidebar only", "", "Settings can drop the top bar. The sidebar then holds back, forward, the site and its buttons. A new install starts this way."),
  ("Full screen", "", "On a Mac with a notch the top bar runs around it. The menu bar and the Dock stay hidden until you press against the edge."),
  ("A new tab is a field", "", "It opens over the page you are on, and the tab exists once you enter something. It suggests tabs, bookmarks and history, and matches letters in order (“gthub”) or two initials (“gh bl”)."),
  ("Keywords and commands", "", "Type a site's keyword and a space (“yt lofi”) to search it. Start with > to run any menu command."),
 ]),
 ("tabs", "Tabs, groups and profiles", "", [
  ("Pinned tabs", "", "Three to a row, as tiles above the rest."),
  ("Tab groups", "", "A coloured name that folds, with a line of that colour down its tabs. Right-click a tab to add it."),
  ("Tabs stay under their parent", "", "A tab opened from a link sits under its source, and closing it takes you back there."),
  ("Profiles", "", "Coloured dots above the pinned tabs. Each profile has its own cookies, sign-ins, tabs, history and bookmarks. Extensions, zoom and site permissions are shared."),
  ("Split view", "", "Right-click a tab or link and choose Open Side by Side. Drag the divider; the framed half has the keyboard."),
  ("Private tabs", "", "They share one cookie jar kept in memory, which goes when the app quits. They are never saved and never shown to an agent."),
  ("Quiet tabs", "", "A tab off screen is frozen, and unloaded after six hours or when memory runs short. A tab with unsent typing, sound or a call is left alone."),
 ]),
 ("reading", "Reading and looking", "", [
  ("Reader", "⌥⌘R", "Just the article, in light, sepia or dark, serif or sans, in five sizes."),
  ("Dark pages", "⇧⌘D", "A page that stays white while macOS is dark gets dark colours, pictures untouched. Off until you turn it on."),
  ("Peek", "⇧ click", "A link's page in a panel over the one you are reading; Esc puts it away. Hold ⌘ over a link for a smaller preview."),
  ("Translate Page", "", "The system's own translation, done on this Mac."),
  ("Zoom, by site", "⌘+ ⌘−", "Set once and remembered for the site, except in private tabs."),
  ("Picture in picture", "⇧⌘P", "Just the video, in a window you can resize. A playing video goes there by itself when you leave its tab."),
  ("The page as one picture", "⇧⌘R", "Copies the whole page, top to bottom, as a single image."),
  ("Pick Color from Screen", "", "In the View menu: macOS's eyedropper, with the color's code copied to the clipboard."),
 ]),
 ("saving", "Saving", "", [
  ("A download button for photos and videos", "", "On the sites you list, a small button appears over a large photo or video. The list starts empty."),
  ("Videos sent in pieces", "", "A video the page loads in pieces is joined into one mp4: an HLS playlist (AES-128 included), or a picture file and a sound file."),
  ("Downloads you can steer", "", "Pause, resume, cancel and restart, with speed and time left. Paused ones and the last hundred finished survive quitting."),
  ("Copy address without the tracking", "⇧⌘C", "Removes utm_, fbclid, gclid and share codes, but never a video's t or a search's q. ⌥⇧⌘C copies the address as it is."),
  ("Import", "", "Bookmarks and history from Chrome and its kin, Safari and Firefox, and a password file (CSV) from Chrome and its kin."),
 ]),
 ("privacy", "Privacy and the network", "", [
  ("No telemetry, no account", "", "Only the pages you open, plus a daily check for a newer version that Settings turns off."),
  ("Ads and trackers", "", "Blocked by uBlock Origin Lite, the Safari extension from the App Store, YouTube's ads included."),
  ("Tracking parameters", "", "Links you follow lose fbclid, gclid and the like, using the list macOS keeps for Safari."),
  ("What a site may do", "", "The lock shows how the page was fetched, what it may do (location, notifications), what it stores here and its zoom."),
  ("Google keeps your region", "", "Searches carry the Mac's language and region, so a VPN doesn't switch the results."),
 ]),
 ("ext", "Extensions", "", [
  ("Chrome Web Store, folders, Safari", "", "Install from the Chrome Web Store (signature checked), an unpacked folder, or a Safari extension inside its app. One set serves every profile."),
  ("Talks to Mac apps", "", "Bitwarden's Touch ID through its desktop app works."),
 ]),
 ("dev", "For developers", "", [
  ("Develop and Debug menus", "", "As in Safari: Web Inspector, console, page source, timelines and WebKit's experimental features."),
  ("Settings kept per site", "", "A site's user agent, color scheme and switches (JavaScript, images, styles) are saved and applied when you visit it."),
  ("Any user agent, any size", "", "iPhone, iPad, Chrome, Firefox or your own, at phone, tablet or typed-in sizes."),
  ("Pick Element for the Agent", "", "Point at an element and the agent gets its selector, text, HTML, styles, framework components and the page's recent errors."),
 ]),
]

def feature_html():
    out = []
    for gid, title, sub, rows in FEATURES:
        out.append(f'      <div class="fgroup reveal" id="f-{gid}" data-group="{gid}" data-title="{esc(title)}">')
        out.append(f'        <h3>{esc(title)}' + (f'<small>{esc(sub)}</small>' if sub else '') + '</h3>')
        out.append('        <div class="frows">')
        for name, keys, text in rows:
            k = f' <kbd>{esc(keys)}</kbd>' if keys else ''
            out.append(f'          <div class="frow"><h4>{esc(name)}{k}</h4><p>{esc(text)}</p></div>')
        out.append('        </div>')
        out.append('      </div>')
    return "\n".join(out)

# ---- FAQ ------------------------------------------------------------------
FAQ = [
 ("Why WebKit and not Chromium?", "WebKit already ships with every Mac and macOS keeps it up to date, so the browser can be a few megabytes of Swift. A few pages built only for Chrome will misbehave, as they do in Safari."),
 ("Does it run Chrome extensions?", "Many. WebKit's extension engine loads them from the Chrome Web Store, a folder or a Safari app, and one set serves every profile. An extension that needs Chrome's debugger won't work."),
 ("Does it support passkeys?", "Not yet. Apple grants browsers that entitlement on request, tied to a paid Developer ID. Password managers that work as extensions, such as Bitwarden, do work."),
 ("What does it send, and to whom?", "Only the pages you open and a daily check for a newer version, which Settings turns off. What an agent reads, when you let it, goes to that agent."),
 ("Why does the download button start with an empty list?", "A button over every picture on every site gets in the way. You add the sites you want it on, in Settings."),
 ("Why Backlight?", "A backlight is the light behind a screen. The page is lit, and the tabs and address stay out of the way until you reach for them. It was called @@OLD@@ until 0.9.0."),
]
def faq_html():
    out = []
    for q, a in FAQ:
        out.append(f'        <details><summary>{esc(q)}</summary><div class="a"><div><p>{esc(a)}</p></div></div></details>')
    return "\n".join(out)

# ---- Numbers (filled from measure/results.json when it exists) ------------
import json
RES = {"cpu_visible": 72.2, "cpu_hidden_frozen": 0.9, "cpu_hidden_unfrozen": 2.5, "first_window_ms": 74}
rp = os.path.join(HERE, "src", "results.json")
if os.path.exists(rp): RES.update(json.load(open(rp)))

def cpu_html():
    rows = [("Shown", RES["cpu_visible"], False), ("Hidden", RES["cpu_hidden_unfrozen"], False), ("Hidden, frozen", RES["cpu_hidden_frozen"], True)]
    top = max(r[1] for r in rows)
    out = []
    for name, v, me in rows:
        w = max(0.4, v / top * 100)
        out.append(f'            <div class="bar-row{" me" if me else ""}"><span class="name">{name}</span><div class="bar-track" style="--w:{w:.1f}"><span class="bar-fill"></span><span class="bar-val{" in-bar" if w > 75 else ""}">{v:.1f}%</span></div></div>')
    return "\n".join(out)

def ledger_html():
    rows = [
     ("2.0 MB", "The download.", "A zip with the agent tools in it."),
     ("4.6 MB", "Installed.", "The app in /Applications, 4.4 MB of it the program."),
     ("0", "Dependencies.", "Swift, AppKit, SwiftUI and WebKit."),
     (f'{RES["first_window_ms"] / 1000:.2f} s'.replace("0.0", "0.0"), "To its first window.", "From opening the app, once it is in cache."),
     ("26,864", "Lines of Swift.", "In 73 files, all in the repository."),
    ]
    out = []
    for big, label, small in rows:
        out.append(f'        <div style="display:grid;grid-template-columns:minmax(150px,300px) 1fr;gap:8px 32px;align-items:baseline;padding:22px 0;border-top:1px solid oklch(.985 .012 var(--h) / .2)"><dt style="font-size:clamp(2.2rem,5vw,4rem);font-weight:700;letter-spacing:-.035em;font-stretch:88%;font-variant-numeric:tabular-nums;line-height:1">{esc(big)}</dt><dd style="font-size:1.0625rem;max-width:62ch"><b style="font-weight:650">{esc(label)}</b> <span style="color:var(--on-brand-dim)">{esc(small)}</span></dd></div>')
    return "\n".join(out)


def ram_html():
    mp = os.path.join(HERE, "src", "memory.json")
    if not os.path.exists(mp): return ""
    m = json.load(open(mp))
    def bar(name, mb, note, me, top):
        w = max(.5, mb / top * 100)
        cls = "bar-row me" if me else "bar-row"
        inb = " in-bar" if w > 75 else ""
        return ('            <div class="%s"><span class="name">%s</span><div class="bar-track" style="--w:%.1f"><span class="bar-fill"></span>'
                '<span class="bar-val%s">%s MB<small> &middot; %s</small></span></div></div>') % (cls, name, w, inb, format(round(mb), ","), note)
    def block(title, sub, rows):
        top = max(r[1] for r in rows)
        body = "\n".join(bar(n, mb, note, me, top) for n, mb, note, me in rows)
        return ('        <div class="bar-block reveal" data-bars>\n          <h3>%s<small>%s</small></h3>\n          <div class="bar-list">\n%s\n          </div>\n        </div>' % (title, sub, body))
    out = []
    e = m["empty"]
    out.append(block("Memory with one empty window", "The app and its helper processes, 25 seconds after it opens.",
        [("Chrome", e["Chrome"]["mb"], "%d processes" % e["Chrome"]["procs"], False), ("BasicShell", e["BasicShell"]["mb"], "%d processes" % e["BasicShell"]["procs"], True)]))
    f = m["five"]
    LABEL = {"BasicShell": ("BasicShell", "uBlock Origin Lite"), "BasicShell, blocker off": ("BasicShell", "no blocker"),
             "BasicShell, tabs unloaded": ("BasicShell, unloaded", "uBlock Origin Lite"), "Chrome": ("Chrome", "no blocker"),
             "Safari": ("Safari", "no blocker"), "Search": ("Search", "its short list")}
    rows = []
    for n, v in f.items():
        nm, sub = LABEL.get(n, (n, ""))
        rows.append(('%s<small>%s</small>' % (nm, sub), v["mb"], "%d processes" % round(v["procs"]), n.startswith("BasicShell")))
    rows.sort(key=lambda r: -r[1])
    out.append(block("Memory with five pages open", "The same five pages, one shown, after a minute and a half. Chrome and Safari ran with no blocker, Search with its short built-in list, Backlight with uBlock Origin Lite's 110,000 rules (and with none in the row that says so). The unloaded row is the same pages after it unloaded the four you were not looking at, which it does after six hours or when memory runs short; here the timer was two minutes.", rows))
    s = m.get("split")
    if s:
        def seg(label, v, tot, cls): return '<span class="seg-%s" style="--w:%.2f" title="%s, %d MB"><i>%s</i></span>' % (cls, v / tot * 100, label, round(v), label)
        lines = []
        for name, d in s.items():
            tot = d["pages"] + d["shell"] + d["rest"]
            lines.append('            <div class="split-row"><span class="name">%s</span><div class="split">%s%s%s</div><span class="tot">%d MB</span></div>' % (
                name, seg("Pages", d["pages"], tot, "p"), seg("The browser itself", d["shell"], tot, "s"), seg("Graphics, network, helpers", d["rest"], tot, "r"), round(tot)))
        out.append('        <div class="bar-block reveal" data-bars>\n          <h3>Where that memory goes<small>%s</small></h3>\n          <div class="bar-list">\n%s\n            <p class="legend"><span class="k-p"></span>Pages <span class="k-s"></span>The browser itself <span class="k-r"></span>Graphics, network, helpers</p>\n          </div>\n        </div>' % (m.get("split_note", ""), "\n".join(lines)))
    return "\n".join(out)

# ---- Assemble -------------------------------------------------------------
def read(p): return open(os.path.join(SRC, p), encoding="utf-8").read()

font_path = os.environ.get("FONT") or os.path.join(SRC, "GoogleSansFlex-latin.woff2")
font_b64 = base64.b64encode(open(font_path, "rb").read()).decode()

body = read("body.html").replace("<!--FEATURES-->", feature_html()).replace("<!--FAQ-->", faq_html()).replace("<!--CPU-->", cpu_html()).replace("<!--LEDGER-->", ledger_html()).replace("<!--RAM-->", ram_html())
css = read("site.css").replace("__FONT_LATIN__", font_b64) + "\n" + read("stage.css")
js = read("app.js")

page = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>{NAME}, a quiet web browser for Mac</title>
<meta name="description" content="A small web browser for macOS, written in Swift on WebKit. The page gets the whole window; tabs and the address wait at the edges. No telemetry, no account, a 2 MB download.">
<meta name="color-scheme" content="light dark">
<meta name="theme-color" content="#14172b">
<link rel="canonical" href="https://mbahakeskin.github.io/Backlight/">
<meta property="og:type" content="website">
<meta property="og:title" content="{NAME}, a quiet web browser for Mac">
<meta property="og:description" content="A small web browser for macOS. The page gets the whole window; tabs and the address wait at the edges.">
<meta property="og:url" content="https://mbahakeskin.github.io/Backlight/">
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 28 28'%3E%3Cdefs%3E%3ClinearGradient id='g' x1='.2' y1='0' x2='.8' y2='1'%3E%3Cstop offset='0' stop-color='%232d3568'/%3E%3Cstop offset='1' stop-color='%2312162f'/%3E%3C/linearGradient%3E%3Cmask id='m'%3E%3Crect width='28' height='28' fill='white'/%3E%3Ccircle cx='16.2' cy='14.4' r='7.1'/%3E%3C/mask%3E%3C/defs%3E%3Crect x='1' y='1' width='26' height='26' rx='8.5' fill='url(%23g)'/%3E%3Ccircle cx='12.6' cy='14' r='7.6' fill='%23ffc981' mask='url(%23m)'/%3E%3Ccircle cx='16.2' cy='14.4' r='7.1' fill='%23171b3a'/%3E%3C/svg%3E">
<style>
{css}
</style>
</head>
<body>
{body}
<script>
{js}
</script>
</body>
</html>
"""
page = page.replace("@@VERSION@@", VERSION).replace("@@SIZE@@", SIZE)
page = page.replace("BasicShell", NAME) if NAME != "BasicShell" else page
page = page.replace("@@OLD@@", "BasicShell")
# site/index.html is the copy for the server, docs/index.html the one GitHub Pages serves (Settings > Pages > main, /docs)
out = os.path.join(HERE, "index.html")
open(out, "w", encoding="utf-8").write(page)
docs = os.path.join(HERE, "..", "docs")
os.makedirs(docs, exist_ok=True)
open(os.path.join(docs, "index.html"), "w", encoding="utf-8").write(page)
print(f"{out}: {len(page)/1024:.0f} KB")
