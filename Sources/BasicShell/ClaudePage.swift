import Foundation
import WebKit

// What Claude's tools run inside a page (see Claude.swift).
//
// It all lives in a script world of BasicShell's own, which shares the
// page's document but none of its script: the page can neither see it nor
// change it. It is put there when first needed, not in every page.
//
// Things on the page are handed out by number ("ref"): the number stays
// with its element for as long as the document lives, so what `read_page`
// listed can be clicked later by its number.
enum ClaudePage {
    static let world = WKContentWorld.world(name: "BasicShellClaude")

    /// Defines `__claude` once in a document.
    static let helper = #"""
    if (!globalThis.__claude) globalThis.__claude = (() => {
      const refs = new Map(), ids = new WeakMap();
      let next = 1;
      const refOf = (e) => { let r = ids.get(e); if (!r) { r = next++; ids.set(e, r); refs.set(r, new WeakRef(e)); } return r; };
      const byRef = (r) => { const w = refs.get(Number(r)); const e = w && w.deref(); return e && e.isConnected ? e : null; };
      const clean = (s, n) => { s = String(s == null ? "" : s).replace(/\s+/g, " ").trim(); return n && s.length > n ? s.slice(0, n - 1) + "…" : s; };

      // A field whose contents are nobody's to read or fill but the person's.
      const secret = (e) => {
        if (!e || e.tagName !== "INPUT") return false;
        if (e.type === "password") return true;
        const hint = [e.getAttribute("autocomplete"), e.name, e.id].join(" ").toLowerCase();
        return /cc-|one-time-code|password|card.?number|cvv|cvc|security.?code/.test(hint);
      };

      const inputRole = { checkbox: "checkbox", radio: "radio", range: "slider", button: "button", submit: "button", reset: "button", image: "button", search: "searchbox", file: "file" };
      const tagRole = { BUTTON: "button", TEXTAREA: "textbox", SELECT: "combobox", SUMMARY: "button", IMG: "img", NAV: "navigation", MAIN: "main",
        HEADER: "banner", FOOTER: "contentinfo", ASIDE: "complementary", FORM: "form", DIALOG: "dialog", IFRAME: "frame", VIDEO: "video", AUDIO: "audio" };
      const role = (e) => {
        const given = e.getAttribute("role");
        if (given) return given.trim().split(/\s+/)[0];
        const tag = e.tagName;
        if (tag === "INPUT") return inputRole[e.type] || "textbox";
        if (tag === "A" || tag === "AREA") return e.hasAttribute("href") ? "link" : "";
        if (/^H[1-6]$/.test(tag)) return "heading";
        if (e.isContentEditable && !(e.parentElement && e.parentElement.isContentEditable)) return "textbox";
        return tagRole[tag] || "";
      };
      const acting = new Set(["link", "button", "checkbox", "radio", "slider", "searchbox", "textbox", "combobox", "file", "tab", "menuitem",
        "menuitemcheckbox", "menuitemradio", "option", "switch", "treeitem", "spinbutton", "listbox", "video", "audio"]);
      // What is named by what it holds, and so isn't looked into.
      const leaf = new Set(["link", "button", "checkbox", "radio", "slider", "searchbox", "textbox", "combobox", "file", "tab", "menuitem",
        "menuitemcheckbox", "menuitemradio", "option", "switch", "spinbutton", "img", "heading", "video", "audio"]);
      const landmark = new Set(["navigation", "main", "banner", "contentinfo", "complementary", "form", "dialog", "alertdialog", "search", "region", "menu", "tablist", "alert"]);
      const skipped = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "HEAD", "META", "LINK", "TITLE", "BASE", "SVG", "svg", "PATH", "BR", "HR", "WBR", "SOURCE", "TRACK", "PARAM"]);

      const shown = (e) => e.checkVisibility
        ? e.checkVisibility({ visibilityProperty: true, contentVisibilityAuto: true })
        : !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length);

      const clickable = (e, r, style) => {
        if (acting.has(r)) return true;
        if (e.hasAttribute("onclick")) return true;
        const t = e.getAttribute("tabindex");
        if (t !== null && Number(t) >= 0) return true;
        // Made to look clickable, and not only because what holds it is.
        if (style.cursor !== "pointer") return false;
        const up = e.parentElement;
        return !up || getComputedStyle(up).cursor !== "pointer";
      };

      // A label's own words, without those of the field it holds.
      const said = (label) => {
        let out = "";
        const walk = (n) => {
          for (const c of n.childNodes) {
            if (c.nodeType === 3) out += c.nodeValue;
            else if (c.nodeType === 1 && !/^(INPUT|SELECT|TEXTAREA|BUTTON)$/.test(c.tagName)) walk(c);
          }
        };
        walk(label);
        return out;
      };

      const name = (e, r) => {
        const by = e.getAttribute("aria-labelledby");
        if (by) {
          const t = clean(by.split(/\s+/).map((i) => { const x = e.ownerDocument.getElementById(i); return x ? x.textContent : ""; }).join(" "), 100);
          if (t) return t;
        }
        const label = clean(e.getAttribute("aria-label"), 100);
        if (label) return label;
        if (e.labels && e.labels.length) { const t = clean(said(e.labels[0]), 100); if (t) return t; }
        const tag = e.tagName;
        if (tag === "IMG" || (tag === "INPUT" && e.type === "image")) return clean(e.alt || e.title, 100);
        if (tag === "INPUT") return clean(["submit", "button", "reset"].includes(e.type) ? e.value : (e.placeholder || e.title || e.name), 100);
        if (tag === "TEXTAREA") return clean(e.placeholder || e.title || e.name, 100);
        if (tag === "SELECT") return clean(e.title || e.name, 100);
        if (tag === "IFRAME") return clean(e.title || e.name || e.src, 100);
        if (r === "textbox") return clean(e.getAttribute("aria-placeholder") || e.getAttribute("data-placeholder") || e.title, 100);
        const inside = e.querySelector ? e.querySelector("img[alt]") : null;
        return clean(e.innerText || e.textContent, 100) || clean(e.title, 100) || (inside ? clean(inside.alt, 100) : "");
      };

      const state = (e, r) => {
        const out = [], tag = e.tagName;
        if (tag === "A" && e.hasAttribute("href")) out.push("href=" + clean(e.getAttribute("href"), 80));
        if (tag === "INPUT" || tag === "TEXTAREA") {
          if (r === "checkbox" || r === "radio") out.push(e.checked ? "checked" : "unchecked");
          else if (r !== "button" && r !== "file") out.push("value=" + JSON.stringify(secret(e) ? (e.value ? "(hidden)" : "") : clean(e.value, 80)));
          if (tag === "INPUT" && !["text", "checkbox", "radio", "submit", "button", "search", "image", "reset", "file"].includes(e.type)) out.push("type=" + e.type);
        } else if (tag === "SELECT") {
          const picked = e.selectedOptions[0];
          out.push("value=" + JSON.stringify(picked ? clean(picked.textContent, 60) : ""));
          const options = [...e.options].slice(0, 15).map((o) => clean(o.textContent, 30));
          out.push("options=" + JSON.stringify(options) + (e.options.length > 15 ? "+" + (e.options.length - 15) : ""));
        } else if (r === "textbox" && e.isContentEditable) {
          out.push("value=" + JSON.stringify(clean(e.innerText, 80)));
        }
        for (const [attribute, word] of [["aria-checked", "checked"], ["aria-expanded", "expanded"], ["aria-selected", "selected"], ["aria-pressed", "pressed"]]) {
          const v = e.getAttribute(attribute);
          if (v === "true") out.push(word); else if (v === "false" && attribute !== "aria-selected") out.push("not " + word);
        }
        if (e.getAttribute("aria-current") && e.getAttribute("aria-current") !== "false") out.push("current");
        if (e.disabled || e.getAttribute("aria-disabled") === "true") out.push("disabled");
        if (secret(e)) out.push("secret");
        return out;
      };

      // What is inside an element: its shadow tree, a frame's document when
      // it is this site's own, its children.
      function* kids(e) {
        if (e.shadowRoot) yield* e.shadowRoot.childNodes;
        if (e.tagName === "IFRAME") {
          let inner = null;
          try { inner = e.contentDocument; } catch (error) {}
          if (inner && inner.body) yield inner.body;
          return;
        }
        yield* e.childNodes;
      }

      // Where an element is in the window's own view, frames counted in.
      const box = (e) => {
        const b = e.getBoundingClientRect();
        let x = b.left, y = b.top, w = e.ownerDocument.defaultView;
        while (w && w !== window && w.frameElement) {
          const f = w.frameElement, fb = f.getBoundingClientRect();
          x += fb.left + f.clientLeft; y += fb.top + f.clientTop;
          w = f.ownerDocument.defaultView;
        }
        return { x, y, w: b.width, h: b.height };
      };
      const onScreen = (b) => b.y + b.h > 0 && b.y < innerHeight && b.x + b.w > 0 && b.x < innerWidth;

      const line = (e, r) => {
        const parts = ["[" + refOf(e) + "]", r || "clickable"];
        const n = name(e, r);
        if (n) parts.push(JSON.stringify(n));
        parts.push(...state(e, r));
        return parts;
      };

      const header = () => {
        const d = document.scrollingElement || document.documentElement;
        return "Page: " + clean(document.title, 120) + " — " + location.href + "\n" +
          "View: " + innerWidth + "×" + innerHeight + ", scrolled to " + Math.round(scrollY) + " of " + Math.max(0, Math.round(d.scrollHeight - innerHeight));
      };

      const tree = (options) => {
        const all = options.filter === "all", max = options.max || 20000, lines = [];
        let total = 0, cut = 0;
        const emit = (depth, text) => {
          const s = "  ".repeat(Math.min(depth, 8)) + text;
          if (cut || total + s.length + 1 > max) { cut++; return; }
          total += s.length + 1; lines.push(s);
        };
        // `said`: what this holds has been said already, as something's name.
        const walk = (node, depth, said) => {
          for (const c of kids(node)) {
            if (c.nodeType === 3) {
              if (all && !said) { const t = clean(c.nodeValue, 300); if (t) emit(depth, t); }
              continue;
            }
            if (c.nodeType !== 1 || skipped.has(c.tagName)) continue;
            if (c.getAttribute("aria-hidden") === "true") continue;
            const file = c.tagName === "INPUT" && c.type === "file";
            if (c.tagName === "INPUT" && c.type === "hidden") continue;
            if (!file && !shown(c)) continue;
            const r = role(c);
            let deeper = depth, inner = said;
            if (file || clickable(c, r, getComputedStyle(c))) {
              const parts = line(c, r);
              if (!file && !onScreen(box(c))) parts.push("(off screen)");
              emit(depth, parts.join(" "));
              if (leaf.has(r)) continue;
              deeper = depth + 1;
            } else if (r === "heading") {
              if (all) emit(depth, "heading " + JSON.stringify(clean(c.innerText || c.textContent, 160)));
              inner = true;
            } else if (r === "img") {
              if (all) { const n = name(c, r); if (n) emit(depth, "img " + JSON.stringify(n)); }
              continue;
            } else if (r === "frame") {
              let own = false;
              try { own = !!c.contentDocument; } catch (error) {}
              emit(depth, "[" + refOf(c) + "] frame " + JSON.stringify(name(c, r)) + (own ? "" : " (another site's: only the picture, and clicks and typing by position, reach inside)"));
              deeper = depth + 1;
            } else if (landmark.has(r) && (all || r === "dialog" || r === "alertdialog" || r === "alert")) {
              const n = clean(c.getAttribute("aria-label"), 60);
              emit(depth, r + (n ? " " + JSON.stringify(n) : ""));
              deeper = depth + 1;
            }
            walk(c, deeper, inner);
          }
        };
        const start = options.ref ? byRef(options.ref) : document.documentElement;
        if (!start) return "That ref is no longer on the page; read the page again.";
        walk(start, 0, false);
        if (cut) lines.push("… " + cut + " more lines not shown: ask for more with max_chars, or for one part of the page with ref.");
        if (!lines.length) lines.push(all ? "(nothing to show)" : "(nothing to click or fill; filter \"all\" shows the text too)");
        return header() + "\n\n" + lines.join("\n");
      };

      const text = (offset, max) => {
        const whole = document.body ? document.body.innerText : "";
        const part = whole.slice(offset, offset + max);
        const more = whole.length - offset - part.length;
        return header() + "\n\n" + part + (more > 0 ? "\n\n… " + more + " more characters: ask again with offset " + (offset + part.length) + "." : "");
      };

      const find = (query, limit) => {
        const q = query.toLowerCase(), out = [];
        const walk = (node) => {
          for (const c of kids(node)) {
            if (out.length >= limit) return;
            if (c.nodeType !== 1 || skipped.has(c.tagName) || c.getAttribute("aria-hidden") === "true") continue;
            const file = c.tagName === "INPUT" && c.type === "file";
            if ((c.tagName === "INPUT" && c.type === "hidden") || (!file && !shown(c))) continue;
            const r = role(c);
            if (file || clickable(c, r, getComputedStyle(c))) {
              const parts = line(c, r);
              if (parts.join(" ").toLowerCase().includes(q) || (c.id && c.id.toLowerCase().includes(q))) {
                if (!file && !onScreen(box(c))) parts.push("(off screen)");
                out.push(parts.join(" "));
              }
              if (leaf.has(r)) continue;
            } else {
              // Text of its own, not its children's.
              const own = clean([...c.childNodes].filter((n) => n.nodeType === 3).map((n) => n.nodeValue).join(" "), 200);
              if (own && own.toLowerCase().includes(q)) out.push("[" + refOf(c) + "] text " + JSON.stringify(own) + (onScreen(box(c)) ? "" : " (off screen)"));
            }
            walk(c);
          }
        };
        walk(document.documentElement);
        return out.length ? out.join("\n") : "Nothing on the page matches " + JSON.stringify(query) + ".";
      };

      // The element at a point, through shadow trees and this site's own frames.
      const at = (x, y) => {
        let d = document, e = d.elementFromPoint(x, y);
        for (let i = 0; e && i < 12; i++) {
          if (e.shadowRoot) { const inner = e.shadowRoot.elementFromPoint(x, y); if (inner && inner !== e) { e = inner; continue; } }
          if (e.tagName === "IFRAME") {
            let inner = null;
            try { inner = e.contentDocument; } catch (error) {}
            if (!inner) break;
            const fb = e.getBoundingClientRect();
            x -= fb.left + e.clientLeft; y -= fb.top + e.clientTop;
            const hit = inner.elementFromPoint(x, y);
            if (!hit) break;
            e = hit; continue;
          }
          break;
        }
        return e;
      };
      const holds = (outer, inner) => {
        for (let n = inner, i = 0; n && i < 200; i++) {
          if (n === outer) return true;
          n = n.parentNode || n.host || (n.defaultView && n.defaultView.frameElement) || null;
        }
        return false;
      };
      const describe = (e) => {
        if (!e) return "nothing";
        const r = role(e);
        return line(e, r || e.tagName.toLowerCase()).join(" ");
      };

      // A point on the element that is the element's, brought into view first.
      const spot = (r) => {
        const e = byRef(r);
        if (!e) return { gone: true };
        if (!onScreen(box(e)) || box(e).y < 0 || box(e).y + Math.min(box(e).h, 40) > innerHeight) {
          e.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
        }
        const b = box(e);
        const what = { what: describe(e), secret: secret(e), disabled: !!e.disabled, file: e.tagName === "INPUT" && e.type === "file" };
        if (b.w < 1 || b.h < 1) return { ...what, hidden: true };
        const own = () => {
          const b = box(e);
          for (const [fx, fy] of [[0.5, 0.5], [0.25, 0.5], [0.75, 0.5], [0.5, 0.25], [0.5, 0.75], [0.1, 0.5], [0.9, 0.5]]) {
            const x = Math.min(Math.max(b.x + b.w * fx, 1), innerWidth - 1), y = Math.min(Math.max(b.y + b.h * fy, 1), innerHeight - 1);
            const hit = at(x, y);
            if (hit && (holds(e, hit) || holds(hit, e))) return { ...what, x, y };
          }
          return null;
        };
        let found = own();
        if (!found) {
          // Out of sight inside something that scrolls, perhaps.
          e.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
          found = own();
        }
        if (found) return found;
        const last = box(e), x = last.x + last.w / 2, y = last.y + last.h / 2;
        return { ...what, x, y, under: describe(at(x, y)) };
      };

      // What has the keyboard, through shadow trees and this site's own frames.
      const focused = () => {
        let e = document.activeElement;
        for (let i = 0; e && i < 12; i++) {
          if (e.shadowRoot && e.shadowRoot.activeElement) { e = e.shadowRoot.activeElement; continue; }
          if (e.tagName === "IFRAME") { let d = null; try { d = e.contentDocument; } catch (error) {} if (d && d.activeElement) { e = d.activeElement; continue; } }
          break;
        }
        return e;
      };
      const typable = (e) => !!e && (e.isContentEditable || e.tagName === "TEXTAREA" ||
        (e.tagName === "INPUT" && !["checkbox", "radio", "button", "submit", "reset", "file", "image", "range", "color"].includes(e.type)));

      const events = (e) => {
        e.dispatchEvent(new Event("input", { bubbles: true }));
        e.dispatchEvent(new Event("change", { bubbles: true }));
      };
      const fill = (r, value) => {
        const e = byRef(r);
        if (!e) return "That ref is no longer on the page; read the page again.";
        if (secret(e)) return "refused";
        if (e.disabled) return "It is disabled.";
        const tag = e.tagName;
        if (tag === "SELECT") {
          const want = String(value).toLowerCase();
          const option = [...e.options].find((o) => o.value === String(value)) || [...e.options].find((o) => clean(o.textContent).toLowerCase() === want)
            || [...e.options].find((o) => clean(o.textContent).toLowerCase().includes(want));
          if (!option) return "It has no such choice. It has: " + [...e.options].slice(0, 30).map((o) => clean(o.textContent, 40)).join(" | ");
          e.value = option.value; events(e);
          return "Chose " + JSON.stringify(clean(option.textContent, 60)) + ".";
        }
        if (tag === "INPUT" && (e.type === "checkbox" || e.type === "radio")) {
          const want = value === true || /^(true|on|yes|1|checked)$/i.test(String(value));
          if (e.checked !== want) e.click();
          return e.checked === want ? (want ? "Checked." : "Unchecked.") : "The page didn't let it change.";
        }
        if (tag === "INPUT" && e.type === "file") return "A file field takes files with the upload tool.";
        if (tag === "INPUT" || tag === "TEXTAREA") {
          e.focus();
          e.value = String(value); events(e);
          return "Now holds " + JSON.stringify(clean(e.value, 80)) + ".";
        }
        if (e.isContentEditable) {
          e.focus();
          const s = e.ownerDocument.getSelection(); s.selectAllChildren(e);
          e.ownerDocument.execCommand("insertText", false, String(value));
          return "Now holds " + JSON.stringify(clean(e.innerText, 80)) + ".";
        }
        return "That isn't a field. Click it instead.";
      };

      // Text put where the keyboard is, as typing would.
      const insert = (value) => {
        const e = focused();
        if (!typable(e)) return "nowhere";
        if (secret(e)) return "refused";
        const d = e.ownerDocument;
        if (d.execCommand("insertText", false, value)) return "typed";
        if ("value" in e) {
          const from = e.selectionStart ?? e.value.length, to = e.selectionEnd ?? e.value.length;
          e.value = e.value.slice(0, from) + value + e.value.slice(to); events(e);
          return "typed";
        }
        return "nowhere";
      };

      const scrollable = (e, dx, dy) => {
        const s = getComputedStyle(e);
        const can = (overflow, size, client, amount) => amount !== 0 && /auto|scroll|overlay/.test(overflow) && size > client + 1;
        return can(s.overflowY, e.scrollHeight, e.clientHeight, dy) || can(s.overflowX, e.scrollWidth, e.clientWidth, dx);
      };
      const scroll = (x, y, dx, dy) => {
        let e = at(x, y);
        while (e && e !== document.body && e !== document.documentElement && !scrollable(e, dx, dy)) e = e.parentElement || (e.getRootNode() && e.getRootNode().host) || null;
        const target = e && e !== document.body && e !== document.documentElement ? e : (document.scrollingElement || document.documentElement);
        const before = [target.scrollLeft, target.scrollTop];
        target.scrollBy({ left: dx, top: dy, behavior: "instant" });
        return { moved: target.scrollLeft !== before[0] || target.scrollTop !== before[1], page: target === (document.scrollingElement || document.documentElement) };
      };

      return { tree, text, find, spot, fill, insert, scroll, header, byRef,
        focus: () => { const e = focused(); return { typable: typable(e), secret: secret(e), frame: !!e && e.tagName === "IFRAME", what: e && e !== document.body ? describe(e) : "" }; },
        boxOf: (r) => { const e = byRef(r); return e ? box(e) : null; },
        show: (r) => { const e = byRef(r); if (!e) return false; e.scrollIntoView({ block: "center", inline: "center", behavior: "instant" }); return true; } };
    })();
    """#

    // MARK: - frames from other sites

    static let frameHandler = "basicShellClaudeFrame"

    /// The page's own script can't look into a frame from another site, so
    /// each such frame says it is there, and BasicShell, which may run
    /// script in it, asks it itself where its keyboard is: whether in a
    /// password or card field (a card form is nearly always such a frame).
    static let frames = WKUserScript(source: """
    if (window !== top) { try { webkit.messageHandlers.\(frameHandler).postMessage(1); } catch (e) {} }
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world)

    final class Frames: NSObject, WKScriptMessageHandler {
        static let shared = Frames()

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let tab = message.webView?.navigationDelegate as? Tab, !message.frameInfo.isMainFrame else { return }
            tab.frames.append(message.frameInfo)
            if tab.frames.count > 80 { tab.frames.removeFirst(tab.frames.count - 80) }
        }
    }

    // MARK: - what a page logs and loads (the developer tools)

    static let logHandler = "basicShellClaudeLog"

    /// In every page while the developer tools are on: what goes to the
    /// console, errors nobody caught, and what is asked of the network,
    /// told to BasicShell, which keeps the last of them for each tab.
    static let watch = WKUserScript(source: #"""
    (() => {
      const bridge = window.webkit && webkit.messageHandlers && webkit.messageHandlers.basicShellClaudeLog;
      if (!bridge) return;
      const post = (kind, text) => { try { bridge.postMessage({ kind, text: String(text).slice(0, 2000), frame: window === top ? "" : location.host }); } catch (e) {} };
      const show = (x) => {
        if (x instanceof Error) return (x.name || "Error") + ": " + x.message;
        if (typeof x === "object" && x !== null) { try { return JSON.stringify(x); } catch (e) { return String(x); } }
        return String(x);
      };
      for (const level of ["log", "info", "warn", "error", "debug"]) {
        const original = console[level];
        if (typeof original !== "function") continue;
        console[level] = function (...parts) { post(level, parts.map(show).join(" ")); return original.apply(this, parts); };
      }
      addEventListener("error", (e) => {
        const t = e.target;
        if (t && t !== window && (t.src || t.href)) return post("error", "couldn't load " + (t.tagName || "").toLowerCase() + " " + (t.src || t.href));
        post("error", (e.message || "error") + " @" + (e.filename || "") + ":" + e.lineno);
      }, true);
      addEventListener("unhandledrejection", (e) => post("error", "unhandled rejection: " + show(e.reason)));
      const sent = (method, url, status, started) => post("network", method + " " + url + " → " + status + " (" + Math.round(performance.now() - started) + " ms)");
      const realFetch = window.fetch;
      if (realFetch) window.fetch = function (input, init) {
        const started = performance.now();
        const method = ((init && init.method) || (input && input.method) || "GET").toUpperCase();
        let url = ""; try { url = new URL(typeof input === "string" ? input : input.url, location.href).href; } catch (e) {}
        const result = realFetch.apply(this, arguments);
        result.then((r) => sent(method, url, r.status, started), (e) => sent(method, url, "failed: " + (e && e.message), started));
        return result;
      };
      const open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (method, url) {
        try { this.__claude = [String(method).toUpperCase(), new URL(url, location.href).href]; } catch (e) {}
        return open.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function () {
        const started = performance.now(), note = this.__claude;
        if (note) this.addEventListener("loadend", () => sent(note[0], note[1], this.status || "failed", started));
        return send.apply(this, arguments);
      };
      // Everything else the page loads (scripts, styles, images, frames).
      try {
        new PerformanceObserver((list) => {
          for (const entry of list.getEntries()) {
            if (entry.initiatorType === "fetch" || entry.initiatorType === "xmlhttprequest") continue;
            post("network", "GET " + entry.name + " → " + (entry.responseStatus || "loaded") + " (" + Math.round(entry.duration) + " ms, " + entry.initiatorType + ")");
          }
        }).observe({ type: "resource", buffered: true });
      } catch (e) {}
    })();
    """#, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)

    final class Log: NSObject, WKScriptMessageHandler {
        static let shared = Log()

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let tab = message.webView?.navigationDelegate as? Tab, let body = message.body as? [String: Any],
                  let kind = body["kind"] as? String, let text = body["text"] as? String else { return }
            let frame = body["frame"] as? String ?? ""
            tab.logged.append(Tab.Logged(date: Date(), kind: kind, text: frame.isEmpty ? text : "[\(frame)] \(text)"))
            if tab.logged.count > 600 { tab.logged.removeFirst(tab.logged.count - 600) }
        }
    }

    /// What pages made from now on are given while Claude is let in: the
    /// frames' script, and the watching one while the developer tools are on.
    static func attach(to config: WKWebViewConfiguration) {
        guard ClaudeAccess.enabled else { return }
        config.userContentController.addUserScript(frames)
        config.userContentController.add(Frames.shared, contentWorld: world, name: frameHandler)
        guard ClaudeAccess.developer else { return }
        config.userContentController.addUserScript(watch)
        config.userContentController.add(Log.shared, contentWorld: .page, name: logHandler)
    }
}
