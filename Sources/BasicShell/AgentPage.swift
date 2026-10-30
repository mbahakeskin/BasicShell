#if AGENT
import Foundation
import WebKit

// What the agent tools run inside a page (see Agent.swift).
//
// It all lives in a script world of BasicShell's own, which shares the
// page's document but none of its script: the page can neither see it nor
// change it. It is put there when first needed, not in every page.
//
// Things on the page are handed out by number ("ref"): the number stays
// with its element for as long as the document lives, so what `read_page`
// listed can be clicked later by its number.
enum AgentPage {
    static let world = WKContentWorld.world(name: "BasicShellAgent")

    /// Defines `__agent` once in a document.
    static let helper = #"""
    if (!globalThis.__agent) globalThis.__agent = (() => {
      const refs = new Map(), ids = new WeakMap();
      let next = 1;
      const refOf = (e) => { let r = ids.get(e); if (!r) { r = next++; ids.set(e, r); refs.set(r, new WeakRef(e)); } return r; };
      // A number whose element the page replaced by another of the same kind
      // and name (a search box rebuilt as you type) leads on to the new one.
      const aliases = new Map();
      const byRef = (r) => {
        r = Number(r);
        const first = r;
        for (let i = 0; i < 4; i++) {
          const w = refs.get(r), e = w && w.deref();
          if (e && e.isConnected) return e;
          if (!aliases.has(r)) break;
          r = aliases.get(r);
        }
        return reresolve(first);
      };
      const clean = (s, n) => { s = String(s == null ? "" : s).replace(/\s+/g, " ").trim(); return n && s.length > n ? s.slice(0, n - 1) + "…" : s; };
      // An address cut in the middle, not at the end: what tells one page from
      // another (a product's number) is mostly at the end.
      const elide = (s, n) => { s = clean(s); return s.length > n ? s.slice(0, n - 30) + "…" + s.slice(-29) : s; };

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
      // What is named by what it holds, and so isn't looked into. Not a heading: a shop's card title is often
      // a heading that can be clicked itself (tabindex, a pointer) with the real link inside it, and a heading
      // taken as a leaf hid that link from every list, `find` and label.
      const leaf = new Set(["link", "button", "checkbox", "radio", "slider", "searchbox", "textbox", "combobox", "file", "tab", "menuitem",
        "menuitemcheckbox", "menuitemradio", "option", "switch", "spinbutton", "img", "video", "audio"]);
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
        if (tag === "A" && e.hasAttribute("href")) out.push("href=" + elide(e.getAttribute("href"), 90));
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

      // What each number was said to be when it was handed out, to find the element again if the page
      // rebuilds it before anything has noted that (a site that swaps a field as it is focused).
      const prints = new Map();
      // The dialog that is open over the page and takes it (a <dialog> shown as a modal, or one that says aria-modal),
      // if there is one; looked for again only after a moment, for the many lines of one answer.
      let modalSeen = null;
      const modalNow = () => {
        const now = performance.now();
        if (modalSeen && now - modalSeen.at < 50) return modalSeen.dialog;
        let dialog = null;
        for (const d of document.querySelectorAll('dialog[open], [aria-modal="true"]')) {
          let modal = d.getAttribute("aria-modal") === "true";
          try { modal = modal || d.matches(":modal"); } catch (error) {}
          if (modal && shown(d)) { dialog = d; break; }
        }
        modalSeen = { at: now, dialog };
        return dialog;
      };

      const line = (e, r) => {
        const ref = refOf(e);
        const parts = ["[" + ref + "]", r || "clickable"];
        const n = name(e, r);
        if (n) parts.push(JSON.stringify(n));
        prints.set(ref, { key: (r || "clickable") + "|" + n, href: e.tagName === "A" ? e.getAttribute("href") : "" });
        parts.push(...state(e, r));
        // Under an open dialog the page cannot be reached: said, so that it is not tried.
        const dialog = modalNow();
        if (dialog && !dialog.contains(e) && !e.contains(dialog)) parts.push("(behind the open dialog)");
        return parts;
      };

      // A number whose element is gone and was never aliased: the one element now that says the same
      // (same kind, same name, same address for a link). Only when there is exactly one.
      const reresolve = (r) => {
        const p = prints.get(r);
        if (!p) return null;
        const hits = [];
        const walk = (node) => {
          for (const c of kids(node)) {
            if (c.nodeType !== 1 || skipped.has(c.tagName) || c.getAttribute("aria-hidden") === "true") continue;
            if (c.tagName === "INPUT" && c.type === "hidden") continue;
            if (!shown(c)) continue;
            const rl = role(c);
            if (clickable(c, rl, getComputedStyle(c))) {
              if ((rl || "clickable") + "|" + name(c, rl) === p.key && (!p.href || (c.tagName === "A" && c.getAttribute("href") === p.href))) hits.push(c);
              if (leaf.has(rl)) continue;
            }
            walk(c);
          }
        };
        walk(document.documentElement);
        if (hits.length !== 1) return null;
        aliases.set(r, refOf(hits[0]));
        return hits[0];
      };

      const header = () => {
        const d = document.scrollingElement || document.documentElement;
        return "Page: " + clean(document.title, 120) + " — " + location.href + "\n" +
          "View: " + innerWidth + "×" + innerHeight + ", scrolled to " + Math.round(scrollY) + " of " + Math.max(0, Math.round(d.scrollHeight - innerHeight));
      };

      // The language the page is in: what it says itself (<html lang>). Where that is missing, or says English over text
      // full of accented letters, a sample of its text too, for the recognizer to read (see Call.language); the rest of
      // the pages are not looked into.
      const language = () => {
        const base = (document.documentElement.getAttribute("lang") || "").trim().toLowerCase().split(/[-_]/)[0];
        let sample = "";
        if (!base || base === "en") {
          const t = (document.body ? document.body.innerText : "").replace(/\s+/g, " ").trim().slice(0, 700);
          const accented = (t.match(/[^\x00-\x7F]/g) || []).length;
          if (t.length > 40 && (!base || accented / t.length > 0.04)) sample = t;
        }
        return { base, sample };
      };

      // When a search finds nothing: what the page has, by the names its controls carry (what is in view first, then the
      // rest of the page), so that the next ask can use them. Short names only: a long one is a sentence, not a word to ask for.
      const vocabulary = () => {
        const found = [], seen = new Set();
        const walk = (node) => {
          for (const c of kids(node)) {
            if (c.nodeType !== 1 || skipped.has(c.tagName) || c.getAttribute("aria-hidden") === "true") continue;
            if (c.tagName === "INPUT" && c.type === "hidden") continue;
            if (!shown(c)) continue;
            const r = role(c);
            if (clickable(c, r, getComputedStyle(c))) {
              const n = clean(name(c, r), 40);
              const g = ["textbox", "searchbox", "combobox"].includes(r) ? "fields" : r === "link" ? "links" : "buttons";
              // "24 comments", "155 comments": one kind of label, said once.
              const kind = g + n.toLowerCase().replace(/\d+/g, "#");
              if (n && !n.endsWith("…") && !seen.has(kind)) { seen.add(kind); found.push({ n, g, on: onScreen(box(c)), at: found.length }); }
              if (leaf.has(r)) continue;
            }
            walk(c);
          }
        };
        walk(document.documentElement);
        // Labels first (short names: what a button or a menu says), then what is in view, then the page's own order:
        // a page's long names are its content, which are asked for by their words, not by their kind.
        found.sort((a, b) => ((a.n.length > 24) - (b.n.length > 24)) || (b.on - a.on) || a.at - b.at);
        const cap = { buttons: 15, fields: 6, links: 30 }, taken = { buttons: [], links: [], fields: [] };
        for (const f of found) if (taken[f.g].length < cap[f.g]) taken[f.g].push(f.n);
        return Object.keys(taken).filter((k) => taken[k].length).map((k) => k + ": " + taken[k].map((n) => JSON.stringify(n)).join(", ")).join("; ");
      };

      const tree = (options) => {
        const all = options.filter === "all", max = options.max || 20000, lines = [];
        const offset = Math.max(0, Math.floor(options.offset || 0));
        if (!options.ref && !all) noteRead();
        // Every line is made, and the answer is a window of them (from `offset`, as many as `max` characters hold),
        // so nothing is dropped without saying where the rest is and how to get it.
        const emit = (depth, text) => { lines.push("  ".repeat(Math.min(depth, 8)) + text); };
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
            // A part of the page that scrolls by itself (a cart panel, a menu, a list): said where it is, with a point inside it
            // to scroll from, so that what is below its edge is not taken for all there is.
            let level = depth;
            const own = getComputedStyle(c);
            if (c !== document.body && c !== document.documentElement && /auto|scroll/.test(own.overflowY) && !leaf.has(r) && c.clientHeight > 80 && c.scrollHeight > c.clientHeight + 40) {
              const b = c.getBoundingClientRect(), label = clean(c.getAttribute("aria-label"), 40);
              emit(depth, "scrolling area" + (label ? " " + JSON.stringify(label) : "") + " at " + Math.round(b.x + b.width / 2) + "," + Math.round(b.y + b.height / 2) +
                " (scrolled " + Math.round(c.scrollTop) + " of " + Math.round(c.scrollHeight - c.clientHeight) + " px; `scroll` with x, y there)");
              level = depth + 1;
            }
            let deeper = level, inner = said;
            if (file || clickable(c, r, getComputedStyle(c))) {
              const parts = line(c, r);
              if (!file && !onScreen(box(c))) parts.push("(off screen)");
              emit(level, parts.join(" "));
              if (leaf.has(r)) continue;
              deeper = level + 1;
            } else if (r === "heading") {
              if (all) emit(level, "heading " + JSON.stringify(clean(c.innerText || c.textContent, 160)));
              inner = true;
            } else if (r === "img") {
              if (all) { const n = name(c, r); if (n) emit(level, "img " + JSON.stringify(n)); }
              continue;
            } else if (r === "frame") {
              let own = false;
              try { own = !!c.contentDocument; } catch (error) {}
              emit(level, "[" + refOf(c) + "] frame " + JSON.stringify(name(c, r)) + (own ? "" : " (another site's: only the picture, and clicks and typing by position, reach inside)"));
              deeper = level + 1;
            } else if (landmark.has(r) && (all || r === "dialog" || r === "alertdialog" || r === "alert")) {
              const n = clean(c.getAttribute("aria-label"), 60);
              emit(level, r + (n ? " " + JSON.stringify(n) : ""));
              deeper = level + 1;
            }
            walk(c, deeper, inner);
          }
        };
        const start = options.ref ? byRef(options.ref) : document.documentElement;
        if (!start) return "That ref is no longer on the page; read the page again.";
        walk(start, 0, false);
        if (!lines.length) lines.push(all ? "(nothing to show)" : "(nothing to click or fill; filter \"all\" shows the text too)");
        let end = Math.min(offset, lines.length), size = 0;
        const from = end;
        while (end < lines.length && (end === from || size + lines[end].length + 1 <= max)) { size += lines[end].length + 1; end++; }
        const body = lines.slice(from, end), more = lines.length - end;
        // Said at the top, where it is read first, and again at the end: which lines these are, how many are left, and how to get them.
        const how = "`offset: " + end + "` continues from here; `find` reaches one thing by its words from anywhere on the page; `ref` reads one part.";
        const summary = (from > 0 || more > 0)
          ? "Lines " + (body.length ? (from + 1) + "–" + end : "none") + " of " + lines.length + (more > 0 ? "; " + more + " more below: " + how : (from >= lines.length ? " (offset " + offset + " is past the end)" : "")) + "\n"
          : "";
        const open = options.ref ? null : modalNow();
        const modalNote = open ? "A dialog is open (" + (clean(open.getAttribute("aria-label") || (open.querySelector("h1,h2,h3") || {}).textContent, 60) || "untitled") + "): what is behind it is marked.\n" : "";
        return header() + "\n" + modalNote + summary + "\n" + body.join("\n") + (more > 0 ? "\n… " + more + " more lines: " + how : "");
      };

      // The page's text; `options.selector` takes only what matches it, `options.main`
      // only the page's main area.
      const text = (offset, max, options) => {
        options = options || {};
        let whole = document.body ? document.body.innerText : "", note = "";
        if (options.selector) {
          let found = [];
          try { found = [...document.querySelectorAll(options.selector)].filter(shown); } catch (error) { return "That isn't a CSS selector: " + options.selector; }
          if (!found.length) return header() + "\n\nNothing on the page matches " + options.selector + ".";
          whole = found.slice(0, 30).map((e) => e.innerText || e.textContent || "").join("\n---\n");
          note = found.length + " match" + (found.length > 1 ? "es" : "") + " of " + options.selector + (found.length > 30 ? " (first 30 read)" : "") + "\n\n";
        } else if (options.main) {
          const area = ["main", "[role=main]", "article", "#main-content", "#content", "#main", ".main-content", ".content"]
            .map((s) => { try { return document.querySelector(s); } catch (error) { return null; } })
            .find((e) => e && shown(e) && (e.innerText || "").length >= 200);
          if (area) { whole = area.innerText; note = "The page's main area only.\n\n"; }
          else note = "No main area found: the whole page.\n\n";
        }
        const part = whole.slice(offset, offset + max);
        const more = whole.length - offset - part.length;
        return header() + "\n\n" + note + part + (more > 0 ? "\n\n… " + more + " more characters: ask again with offset " + (offset + part.length) + "." : "");
      };

      // What a page says about what it sells: the product data it declares
      // (JSON-LD, microdata, meta tags), or else cards that show a price.
      const structured = (limit) => {
        const lines = [], seen = new Set();
        const one = (v) => (Array.isArray(v) ? v[0] : v);
        const str = (v) => { v = one(v); return v == null ? "" : typeof v === "object" ? clean(v.name || v["@id"] || "", 60) : clean(v, 80); };
        const has = (o, t) => [].concat(o["@type"] || []).some((x) => String(x).toLowerCase() === t);
        // A column with nothing in it is "-", so the columns stay where they are.
        const add = (name, parts) => {
          const line = [clean(name, 120), ...parts.map((p) => p || "-")].join(" | ").replace(/( \| -)+$/, "");
          if (name && !seen.has(line) && lines.length < limit) { seen.add(line); lines.push(line); }
        };
        const offerOf = (o) => {
          const offers = [].concat(o.offers || []);
          const f = offers[0] || {};
          const price = f.price != null ? f.price : f.lowPrice != null ? f.lowPrice : o.price;
          const high = f.highPrice != null && f.highPrice !== price ? "–" + f.highPrice : "";
          const stock = str(f.availability).replace(/^.*\//, "");
          return [price != null ? price + high + " " + str(f.priceCurrency || o.priceCurrency) : "", stock];
        };
        const take = (o, depth) => {
          if (!o || typeof o !== "object" || depth > 6) return;
          if (Array.isArray(o)) { o.forEach((x) => take(x, depth + 1)); return; }
          if (has(o, "product") || has(o, "productgroup") || o.offers) {
            const [price, stock] = offerOf(o);
            const rating = o.aggregateRating ? str(o.aggregateRating.ratingValue) + "★" + (o.aggregateRating.reviewCount || o.aggregateRating.ratingCount ? " (" + (o.aggregateRating.reviewCount || o.aggregateRating.ratingCount) + ")" : "") : "";
            add(str(o.name), [str(o.brand), price, stock, rating, str(o.sku || o.mpn || o.gtin13), str(o.url)]);
          } else if (o.item && typeof o.item === "object") {
            take(o.item, depth + 1);
          } else if (has(o, "listitem") && o.name) {
            add(str(o.name), [str(o.url)]);
          }
          for (const k of ["@graph", "itemListElement", "mainEntity", "hasVariant", "isRelatedTo"]) if (o[k]) take(o[k], depth + 1);
        };
        for (const s of document.querySelectorAll('script[type="application/ld+json"]')) {
          try { take(JSON.parse(s.textContent), 0); } catch (error) {}
        }
        for (const e of document.querySelectorAll('[itemscope][itemtype*="schema.org/Product" i]')) {
          const p = (n) => { const x = e.querySelector('[itemprop="' + n + '"]'); return x ? clean(x.getAttribute("content") || x.getAttribute("href") || x.textContent, 80) : ""; };
          add(p("name"), [p("brand"), p("price") ? p("price") + " " + p("priceCurrency") : "", p("availability").replace(/^.*\//, ""), p("url")]);
        }
        const meta = (n) => { const m = document.querySelector('meta[property="' + n + '"], meta[name="' + n + '"]'); return m ? clean(m.content, 100) : ""; };
        const metaPrice = meta("product:price:amount") || meta("og:price:amount");
        const metaLine = metaPrice ? [meta("og:title"), metaPrice + " " + (meta("product:price:currency") || meta("og:price:currency")), (meta("product:availability") || meta("og:availability")), meta("og:url")].filter(Boolean).join(" | ") : "";
        let how = "declared by the page (JSON-LD, microdata)", cols = "name | brand | price | stock | rating | id | address";
        if (!lines.length && metaLine) { lines.push(metaLine); how = "declared by the page (meta tags)"; cols = "title | price | stock | address"; }
        if (!lines.length) {
          // Cards that show a price: a guess from how the page looks.
          const price = /(?:₺|\bTL\b|\bTRY\b|\$|€|£|\bUSD\b|\bEUR\b)\s?\d[\d.,]*|\d[\d.,]*\s?(?:₺|\bTL\b|\bTRY\b|\$|€|£|\bUSD\b|\bEUR\b)/gi;
          const cards = new Map();
          for (const a of document.querySelectorAll("a[href]")) {
            if (cards.size >= 400 || !/^https?:/i.test(a.href) || !shown(a)) continue;
            const title = clean(a.innerText || (a.querySelector("img") || {}).alt || a.title || a.getAttribute("aria-label"), 160);
            if (title.length < 3) continue;
            let card = a;
            for (let i = 0; i < 7 && card && !((card.innerText || "").match(price)); i++) card = card.parentElement;
            if (!card || card === document.body) continue;
            const found = (card.innerText || "").match(price) || [];
            if (found.length > 4) continue;
            const was = cards.get(card);
            if (!was || (!/^[\d.,\s₺$€£TLtl]+$/.test(title) && title.length > was.title.length)) cards.set(card, { title, href: a.href, prices: [...new Set(found.map((x) => clean(x, 24)))].slice(0, 2) });
          }
          for (const { title, href, prices } of cards.values()) add(title, [prices.join(" / "), href]);
          how = "a guess from the cards that show a price (the page declares no product data)"; cols = "name | price | address";
        }
        if (!lines.length) return header() + "\n\nNo product data: the page declares none and no card shows a price. `read_text` with `main` reads it as text.";
        return header() + "\n\n" + lines.length + " found, " + how + ". " + cols + ":\n" + lines.join("\n");
      };

      // The one thing a call means by `label` (what it says), `selector` (CSS),
      // `role` and `nth`, instead of a ref: the page is searched when the call
      // is made, so a number that has died with a page change is not needed.
      const resolve = (q) => {
        const want = q.label ? String(q.label).toLowerCase().replace(/\s+/g, " ").trim() : "";
        const role_ = q.role ? String(q.role).toLowerCase() : "";
        const found = [];
        let bad = false;
        const rank = (text) => {
          if (!want) return 1;
          const t = String(text || "").toLowerCase().replace(/\s+/g, " ").trim();
          return t === want ? 4 : t.startsWith(want) ? 3 : t.includes(want) ? 2 : 0;
        };
        const walk = (node, text) => {
          for (const c of kids(node)) {
            if (found.length >= 500) return;
            if (c.nodeType !== 1 || skipped.has(c.tagName) || c.getAttribute("aria-hidden") === "true") continue;
            const file = c.tagName === "INPUT" && c.type === "file";
            if (c.tagName === "INPUT" && c.type === "hidden") continue;
            if (!file && !shown(c)) continue;
            const r = role(c);
            let matches = true;
            if (q.selector) { try { matches = c.matches(q.selector); } catch (error) { bad = true; return; } }
            // To fill or type into: only what takes text, a choice or a tick.
            if (q.fields && !(["INPUT", "TEXTAREA", "SELECT"].includes(c.tagName) || c.isContentEditable || ["textbox", "searchbox", "combobox", "checkbox", "radio", "switch", "slider", "spinbutton", "listbox"].includes(r))) matches = false;
            const interactive = file || clickable(c, r, getComputedStyle(c));
            if (matches && (q.selector || interactive || text) && (!role_ || r === role_)) {
              const own = text ? clean([...c.childNodes].filter((n) => n.nodeType === 3).map((n) => n.nodeValue).join(" "), 200) : "";
              const rk = text ? rank(own) : rank(name(c, r)) || (q.selector ? rank(c.innerText) : 0);
              if (rk && (text ? own : true)) found.push({ c, rk, on: file || onScreen(box(c)) });
            }
            if (!q.selector && !text && interactive && leaf.has(r)) continue;
            walk(c, text);
          }
        };
        walk(document.documentElement, false);
        // Words that are only text, with a click handler the page added itself.
        if (!bad && !found.length && want && !q.selector && !q.fields) walk(document.documentElement, true);
        if (bad) return { bad: true };
        if (!found.length) return { none: true };
        const best = Math.max(...found.map((f) => f.rk));
        const tier = found.filter((f) => f.rk === best);
        const index = q.nth ? Math.min(Math.max(q.nth, 1), tier.length) - 1 : Math.max(0, tier.findIndex((f) => f.on));
        const pick = tier[index];
        return { ref: refOf(pick.c), what: describe(pick.c), count: tier.length, nth: index + 1,
          others: tier.filter((f, i) => i !== index).slice(0, 4).map((f) => describe(f.c)) };
      };

      // A link's address as words: what a shop's product card has instead of a name on its link ("Delivery:
      // today"), the product's own name being in the address only (…/havit-gamenote-fuxi-h7-…), whole and not cut.
      // (Accents and the dotless i are dropped, as addresses are written without them.)
      const words = (s) => String(s).toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/ı/g, "i").replace(/[-_.\/+%?&=]+/g, " ").replace(/\s+/g, " ").trim();
      const addressWords = (c) => {
        if (c.tagName !== "A" || !c.hasAttribute("href")) return "";
        let h = c.getAttribute("href") || "";
        try { h = decodeURIComponent(h); } catch (error) {}
        return words(h.split("?")[0]);
      };

      // Where a control is: the text of the nearest thing around it that holds something besides its own name (the card a
      // button is on, the row), for telling apart controls that are called the same.
      const scopeOf = (c, own) => {
        let p = c.parentElement;
        for (let i = 0; p && i < 7 && p !== document.body; i++, p = p.parentElement) {
          const t = clean(p.innerText || "", 400);
          if (t.length > 300) return "";
          if (t.length > own.length + 15) {
            const rest = clean(t.split(own).join(" "), 90);
            return rest ? " — in: " + JSON.stringify(rest) : "";
          }
        }
        return "";
      };

      const find = (query, limit, offset, regex) => {
        let re = null;
        if (regex) { try { re = new RegExp(query, "i"); } catch (error) { return "That isn't a regular expression: " + query; } }
        const q = query.toLowerCase().trim(), out = [];
        const hit = (said) => re ? re.test(said) : said.toLowerCase().includes(q);
        // The closest words first: a control that is called what was asked for, then one that starts with it, then one
        // that has it among its words, then the rest; what is in view before what is not; the page's own order otherwise.
        const closeness = (said) => {
          if (re) return 3;
          const n = clean(said, 200).toLowerCase();
          if (n === q) return 0;
          if (n.startsWith(q)) return 1;
          return new RegExp("(^|[^\\p{L}\\p{N}])" + q.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "($|[^\\p{L}\\p{N}])", "u").test(n) ? 2 : 3;
        };
        // Only a phrase (two words or more) is also looked for in addresses: one word would match too many of them.
        const need = words(query).split(" ").filter((w) => w.length > 1), inAddress = !re && need.length >= 2;
        const inAddr = (c) => { const a = " " + addressWords(c); return a.length > 1 && need.every((w) => a.includes(" " + w)); };
        const walk = (node) => {
          for (const c of kids(node)) {
            if (c.nodeType !== 1 || skipped.has(c.tagName) || c.getAttribute("aria-hidden") === "true") continue;
            const file = c.tagName === "INPUT" && c.type === "file";
            if ((c.tagName === "INPUT" && c.type === "hidden") || (!file && !shown(c))) continue;
            const r = role(c);
            if (file || clickable(c, r, getComputedStyle(c))) {
              const parts = line(c, r);
              if (hit(parts.join(" ")) || (re && hit(name(c, r))) || (c.id && hit(c.id)) || (inAddress && inAddr(c))) {
                const seen = file || onScreen(box(c));
                if (!seen) parts.push("(off screen)");
                out.push({ text: parts.join(" "), rank: closeness(name(c, r)), seen, at: out.length, c, name: name(c, r).toLowerCase() });
              }
              if (leaf.has(r)) continue;
            } else {
              // Text of its own, not its children's.
              const own = clean([...c.childNodes].filter((n) => n.nodeType === 3).map((n) => n.nodeValue).join(" "), 200);
              if (own && hit(own)) {
                const seen = onScreen(box(c));
                out.push({ text: "[" + refOf(c) + "] text " + JSON.stringify(own) + (seen ? "" : " (off screen)"), rank: closeness(own), seen, at: out.length });
              }
            }
            walk(c);
          }
        };
        walk(document.documentElement);
        if (!out.length) return "Nothing on the page matches " + JSON.stringify(query) + ".";
        // All of them are counted: a list that stops at `limit` says how many are left and where to go on.
        out.sort((a, b) => a.rank - b.rank || (b.seen - a.seen) || a.at - b.at);
        // Controls that are called the same (a shop's "Add to cart" for each product) say where they are.
        const called = new Map();
        for (const m of out) if (m.name) called.set(m.name, (called.get(m.name) || 0) + 1);
        const start = Math.max(0, Math.floor(offset || 0));
        const page = out.slice(start, start + limit).map((m) => m.text + (m.c && called.get(m.name) > 1 ? scopeOf(m.c, clean(name(m.c, role(m.c)), 100)) : ""));
        if (!page.length) return "Only " + out.length + " match" + (out.length === 1 ? "" : "es") + " for " + JSON.stringify(query) + "; offset " + start + " is past the end.";
        const left = out.length - start - page.length;
        return page.join("\n") + (left > 0 ? "\n… " + left + " more matches (" + out.length + " in all): `offset: " + (start + page.length) + "` gives the next ones, or use more words." : "");
      };
      // Several things at once, each under its own heading: what a page offers for a task is mostly looked up together.
      const findMany = (queries, limit, regex) => queries.map((q) => JSON.stringify(q) + ":\n" + find(q, limit, 0, regex)).join("\n\n");

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

      // What is selected: in a field, what is selected in it, unless the field is a secret one.
      const selection = () => {
        const e = focused();
        if (e && secret(e)) return { secret: true };
        if (e && "value" in e && typeof e.selectionStart === "number" && e.selectionEnd > e.selectionStart) {
          return { text: String(e.value).slice(e.selectionStart, e.selectionEnd), where: describe(e) };
        }
        const s = document.getSelection();
        return { text: s ? String(s) : "" };
      };

      // An element looked over: where it is, how it is styled, what it is made of.
      const inspect = (r, props, wantHtml) => {
        const e = byRef(r);
        if (!e) return null;
        const style = getComputedStyle(e), b = box(e);
        const names = props && props.length ? props : ["display", "position", "width", "height", "margin", "padding", "border", "box-sizing", "overflow",
          "z-index", "opacity", "visibility", "color", "background-color", "font-family", "font-size", "font-weight", "line-height", "flex", "grid-template-columns", "transform"];
        const styles = {};
        for (const n of names) styles[n] = style.getPropertyValue(n) || style[n] || "";
        const attributes = {};
        for (const a of e.attributes) attributes[a.name] = a.name === "value" && secret(e) ? "[hidden]" : clean(a.value, 200);
        const out = { tag: e.tagName.toLowerCase(), what: describe(e), box: b, attributes, styles,
          children: e.children.length, text: clean(e.textContent, 160) };
        if (wantHtml) {
          // A secret field's value is not in what is given.
          const copy = e.cloneNode(true);
          const original = [e, ...e.querySelectorAll("input")], cloned = [copy, ...copy.querySelectorAll("input")];
          original.forEach((o, i) => { if (o.tagName === "INPUT" && secret(o) && cloned[i]) cloned[i].removeAttribute("value"); });
          const html = copy.outerHTML;
          out.html = html.length > 6000 ? html.slice(0, 6000) + "… cut at 6000 characters." : html;
        }
        return out;
      };

      // Until nothing on the page has changed for `idle` milliseconds (or `cap`
      // have gone): what a click set going has come to rest. Answers how long.
      // No looking again and again: each change sets one timer again, and when it runs out
      // nothing has changed for `idle` (the page is quiet); `cap` is only the watchdog.
      const quiet = (idle, cap) => new Promise((resolve) => {
        const start = performance.now();
        let timer = 0;
        const finish = () => { watcher.disconnect(); clearTimeout(timer); clearTimeout(deadline); resolve(Math.round(performance.now() - start)); };
        const arm = () => { clearTimeout(timer); timer = setTimeout(finish, idle); };
        const watcher = new MutationObserver(arm);
        // Pictures loading late, animations and the like only touch a few
        // attributes (src, style…): those say nothing of the page having changed.
        watcher.observe(document.documentElement, { subtree: true, childList: true, characterData: true, attributes: true,
          attributeFilter: ["class", "hidden", "open", "disabled", "value", "checked", "aria-expanded", "aria-hidden", "aria-selected", "aria-checked", "aria-pressed", "aria-busy"] });
        const deadline = setTimeout(finish, cap);
        arm();
      });

      // What a call that gives the page input waits for: the page says itself that it has taken
      // the events (the first `types` event it sees, `count` times); `ms` is the watchdog.
      let armedWith = null;
      const arm = (types, count, ms) => {
        armedWith = new Promise((resolve) => {
          let left = count, timer = 0;
          const handlers = types.map((t) => { const h = () => { if (--left <= 0) finish(t); }; document.addEventListener(t, h, true); return [t, h]; });
          const finish = (why) => { for (const [t, h] of handlers) document.removeEventListener(t, h, true); clearTimeout(timer); resolve(why); };
          timer = setTimeout(() => finish("time"), ms);
        });
        return true;
      };
      const armed = () => armedWith || Promise.resolve("none");

      // After `n` frames have been drawn (for what was just put on the page to be on the picture); `ms` is the watchdog.
      const frames = (n, ms) => new Promise((resolve) => {
        let left = n;
        const timer = setTimeout(() => resolve("time"), ms);
        const step = () => { if (--left <= 0) { clearTimeout(timer); resolve("frames"); } else requestAnimationFrame(step); };
        requestAnimationFrame(step);
      });

      // What a wait is woken by, instead of looking again and again: the first change to the
      // page, a request that finished or the page loading; or `ms` (when something is due then).
      const changed = (ms) => new Promise((resolve) => {
        const off = [];
        let timer = 0, done = false;
        const finish = (why) => { if (done) return; done = true; off.forEach((f) => f()); clearTimeout(timer); resolve(why); };
        const watcher = new MutationObserver(() => finish("changed"));
        watcher.observe(document, { subtree: true, childList: true, characterData: true, attributes: true });
        off.push(() => watcher.disconnect());
        try { const seen = new PerformanceObserver(() => finish("resource")); seen.observe({ type: "resource" }); off.push(() => seen.disconnect()); } catch (e) {}
        for (const t of ["load", "popstate", "hashchange"]) { const h = () => finish(t); addEventListener(t, h, { once: true }); off.push(() => removeEventListener(t, h)); }
        timer = setTimeout(() => finish("time"), Math.max(0, ms));
      });

      // Everything on the page that can be clicked or filled, by ref: what it
      // says, and whether it is in the view.
      const inventory = () => {
        const out = new Map();
        const walk = (node) => {
          for (const c of kids(node)) {
            if (c.nodeType !== 1 || skipped.has(c.tagName) || c.getAttribute("aria-hidden") === "true") continue;
            const file = c.tagName === "INPUT" && c.type === "file";
            if (c.tagName === "INPUT" && c.type === "hidden") continue;
            if (!file && !shown(c)) continue;
            const r = role(c);
            if (file || clickable(c, r, getComputedStyle(c))) {
              const parts = line(c, r);
              out.set(Number(parts[0].slice(1, -1)), { text: parts.slice(1).join(" "), on: file || onScreen(box(c)), key: (r || "clickable") + "|" + name(c, r) });
              if (leaf.has(r)) continue;
            } else if (r === "dialog" || r === "alertdialog" || r === "alert") {
              const n = clean(c.getAttribute("aria-label"), 60);
              out.set(refOf(c), { text: r + (n ? " " + JSON.stringify(n) : ""), on: true });
            }
            walk(c);
          }
        };
        walk(document.documentElement);
        return out;
      };

      // What was there before an action, and what is there after: refs stay
      // with their elements, so a change is the same ref saying something else.
      let before = null;
      const mark = () => { before = inventory(); return before.size; };
      const diff = (limit) => {
        const now = inventory(), old = before;
        before = now;
        const shownAs = (r, e) => "[" + r + "] " + e.text;
        if (!old) {
          const first = [...now].filter(([, e]) => e.on).slice(0, limit).map(([r, e]) => shownAs(r, e));
          return { fresh: true, count: now.size, lines: first, header: header() };
        }
        return compare(old, now, limit);
      };

      // What is new, gone or different between two inventories, as lines.
      const compare = (old, now, limit) => {
        const shownAs = (r, e) => "[" + r + "] " + e.text;
        const lines = [];
        let added = 0, removed = 0, changed = 0;
        // Gone and come again, one of each of the same kind and name: the page
        // rebuilt it. The old number leads to the new one from now on.
        const gone = new Map(), came = new Map();
        const push = (m, k, r) => { if (!m.has(k)) m.set(k, []); m.get(k).push(r); };
        for (const [r, e] of old) if (!now.has(r)) push(gone, e.key, r);
        for (const [r, e] of now) if (!old.has(r)) push(came, e.key, r);
        const rebuilt = new Map();
        for (const [k, from] of gone) {
          const to = came.get(k);
          if (to && from.length === 1 && to.length === 1) { aliases.set(from[0], to[0]); rebuilt.set(to[0], from[0]); }
        }
        const replaced = new Set(rebuilt.values());
        for (const [r, e] of now) {
          const was = old.get(r);
          if (rebuilt.has(r)) { changed++; if (lines.length < limit) lines.push("~ [" + rebuilt.get(r) + "] is now [" + r + "] " + e.text); }
          else if (!was) { added++; if (lines.length < limit) lines.push("+ " + shownAs(r, e)); }
          else if (was.text !== e.text) { changed++; if (lines.length < limit) lines.push("~ " + shownAs(r, e)); }
        }
        for (const [r, e] of old) if (!now.has(r) && !replaced.has(r)) { removed++; if (lines.length < limit) lines.push("- " + shownAs(r, e)); }
        return { fresh: false, count: now.size, added, removed, changed, lines, rebuilt: rebuilt.size };
      };

      // What `read_page` saw last, to say only what is different the next time.
      let readBase = null;
      const noteRead = () => { readBase = inventory(); };
      const since = (limit) => {
        const now = inventory(), old = readBase;
        readBase = now;
        return old ? compare(old, now, limit) : null;
      };

      // The page's search field, or the icon that opens it.
      const searchField = () => {
        const hint = /search|ara(ma)?\b|find|query|buscar|recherche|suche|cerca|поиск|搜索|検索/i;
        const found = [], buttons = [];
        const walk = (node) => {
          for (const c of kids(node)) {
            if (c.nodeType !== 1 || skipped.has(c.tagName) || c.getAttribute("aria-hidden") === "true") continue;
            if (c.tagName === "INPUT" && c.type === "hidden") continue;
            if (!shown(c)) continue;
            const r = role(c);
            if (!secret(c) && c.tagName !== "SELECT" && !c.disabled && !c.readOnly && (r === "searchbox" || r === "textbox" || r === "combobox")) {
              const texts = [c.type, c.name, c.id, c.getAttribute("aria-label"), c.placeholder, c.getAttribute("autocomplete")].join(" ");
              let score = 0;
              if (r === "searchbox" || c.type === "search") score += 6;
              if (hint.test(texts)) score += 4;
              if (c.closest && c.closest('[role="search"], form[action*="search"]')) score += 3;
              if (onScreen(box(c))) score += 2;
              if (c.closest && c.closest("header, [role=banner], nav")) score += 1;
              if (score >= 4) found.push({ score, c });
            } else if ((r === "button" || r === "link") && hint.test(name(c, r) + " " + (c.id || ""))) {
              buttons.push(c);
            }
            if (!leaf.has(r)) walk(c);
          }
        };
        walk(document.documentElement);
        found.sort((a, b) => b.score - a.score);
        if (found.length) return { ref: refOf(found[0].c), what: describe(found[0].c) };
        if (buttons.length) return { button: refOf(buttons[0]), what: describe(buttons[0]) };
        return null;
      };

      // The refs, drawn on the page where they are, for a picture to be taken.
      const markDown = () => { const host = document.getElementById("__agent_marks"); if (host) host.remove(); };
      // `region` ({x, y, w, h} in the view's own pixels) draws only what is in it, so the
      // limit goes to what a picture of that part shows.
      const markUp = (limit, region) => {
        markDown();
        const boxes = [];
        const inside = (b) => !region || (b.x + b.w > region.x && b.x < region.x + region.w && b.y + b.h > region.y && b.y < region.y + region.h);
        const walk = (node) => {
          for (const c of kids(node)) {
            if (boxes.length >= 600) return;
            if (c.nodeType !== 1 || skipped.has(c.tagName) || c.getAttribute("aria-hidden") === "true") continue;
            if (c.tagName === "INPUT" && c.type === "hidden") continue;
            if (!shown(c)) continue;
            const r = role(c);
            if (clickable(c, r, getComputedStyle(c))) {
              const b = box(c);
              if (b.w >= 6 && b.h >= 6 && onScreen(b) && inside(b)) boxes.push({ ref: refOf(c), b });
              if (leaf.has(r)) continue;
            }
            walk(c);
          }
        };
        walk(document.documentElement);
        boxes.sort((p, q) => p.b.y - q.b.y || p.b.x - q.b.x);
        // Two frames on the same spot are one thing to click: the inner one is kept.
        const distinct = boxes.filter((p, i) => !boxes.some((q, j) => j > i && Math.abs(p.b.x - q.b.x) < 3 && Math.abs(p.b.y - q.b.y) < 3 && Math.abs(p.b.w - q.b.w) < 3 && Math.abs(p.b.h - q.b.h) < 3));
        const colors = ["#e11d48", "#2563eb", "#16a34a", "#ea580c", "#9333ea", "#0d9488"];
        const host = document.createElement("div");
        host.id = "__agent_marks";
        host.style.cssText = "position:fixed;left:0;top:0;width:0;height:0;z-index:2147483647;pointer-events:none;";
        const used = distinct.slice(0, limit);
        // Each number goes where it covers no other number: at a corner of its
        // frame, or beside it.
        const placed = [];
        const clash = (r) => placed.some((p) => r.x < p.x + p.w && r.x + r.w > p.x && r.y < p.y + p.h && r.y + r.h > p.y);
        const fits = (r) => r.x >= 0 && r.y >= 0 && r.x + r.w <= innerWidth && r.y + r.h <= innerHeight && !clash(r);
        for (const { ref, b } of used) {
          const color = colors[ref % colors.length];
          const x = Math.max(0, b.x), y = Math.max(0, b.y);
          const w = Math.min(b.w, innerWidth - x), h = Math.min(b.h, innerHeight - y);
          const frame = document.createElement("div");
          frame.style.cssText = "position:fixed;box-sizing:border-box;border:2px solid " + color + ";left:" + x + "px;top:" + y + "px;width:" + w + "px;height:" + h + "px;";
          host.appendChild(frame);
          const tw = 7 * String(ref).length + 8, th = 13;
          const spots = [[x - 2, y - 15], [x - 2, y - 2], [x + w - tw + 2, y - 15], [x + w - tw + 2, y - 2], [x - 2, y + h - th + 2], [x + w - tw + 2, y + h - th + 2],
            [x + w + 1, y], [x - tw - 1, y], [x + w / 2 - tw / 2, y + h / 2 - th / 2]];
          let at = spots.map(([sx, sy]) => ({ x: sx, y: sy, w: tw, h: th })).find(fits);
          if (!at) at = { x: Math.min(Math.max(x - 2, 0), innerWidth - tw), y: Math.min(Math.max(y - 2, 0), innerHeight - th), w: tw, h: th };
          placed.push(at);
          const tag = document.createElement("span");
          tag.textContent = String(ref);
          tag.style.cssText = "position:fixed;left:" + at.x + "px;top:" + at.y + "px;background:" + color + ";color:#fff;font:bold 11px/13px -apple-system,sans-serif;padding:0 3px;border-radius:3px;box-sizing:border-box;min-width:" + tw + "px;text-align:center;";
          host.appendChild(tag);
        }
        document.documentElement.appendChild(host);
        const rest = distinct.slice(limit);
        return { drawn: used.length, more: rest.length, from: rest.length ? Math.round(Math.min(...rest.map((r) => r.b.y))) : 0 };
      };

      // The page's links, as they read and where they go.
      const links = (limit) => {
        const seen = new Set(), out = [];
        for (const a of document.querySelectorAll("a[href]")) {
          if (out.length >= limit) break;
          const href = a.href;
          if (!/^https?:/i.test(href) || seen.has(href) || !shown(a)) continue;
          const t = clean(a.innerText || a.textContent || a.getAttribute("aria-label") || a.title, 80);
          if (!t) continue;
          seen.add(href);
          out.push(t + " → " + href);
        }
        return out;
      };

      // A page with a password or card field on it: the pages that look hardest at what runs in them.
      const guarded = () => [...document.querySelectorAll("input")].some(secret);


      const focusNow = () => { const e = focused(); return { typable: typable(e), secret: secret(e), frame: !!e && e.tagName === "IFRAME", what: e && e !== document.body ? describe(e) : "" }; };
      // Where the keyboard is once the page has finished moving it: a site may hand a clicked field's focus
      // to another element of its own a moment later. Answers at once when it is in a field already; else
      // at the first focus that lands in one, or after `ms` (the watchdog).
      const settleFocus = (ms) => new Promise((resolve) => {
        const first = focusNow();
        if (first.typable || first.frame) { resolve(first); return; }
        let timer = 0;
        const finish = () => { document.removeEventListener("focusin", on, true); clearTimeout(timer); resolve(focusNow()); };
        const on = () => { const f = focusNow(); if (f.typable || f.frame) finish(); };
        document.addEventListener("focusin", on, true);
        timer = setTimeout(finish, ms);
      });

      return { tree, text, structured, resolve, guarded, find, findMany, spot, fill, insert, scroll, header, byRef, selection, inspect, quiet, language, vocabulary, mark, diff, searchField, markUp, markDown, links, since, arm, armed, frames, changed, settleFocus,
        focus: focusNow,
        boxOf: (r) => { const e = byRef(r); return e ? box(e) : null; },
        show: (r) => { const e = byRef(r); if (!e) return false; e.scrollIntoView({ block: "center", inline: "center", behavior: "instant" }); return true; } };
    })();
    """#

    // MARK: - what the page's own server gives (the api tool)

    /// The body of a function run in the page itself, so the request goes as the page's own does
    /// (its cookies, its origin): fetches `url`, and says what JSON came back, as its shape and a
    /// sample, or as the values at `path` (and `fields` of each) one row each.
    static let api = #"""
    const sensitive = /pass(word|wd)?|pwd|secret|token|otp|cvv|cvc|card.?num|credential|authoriz|api.?key|session|jwt|ssn|private/i;
    const scrub = (v, d) => {
      if (d > 6) return "…";
      if (Array.isArray(v)) return v.slice(0, 50).map((x) => scrub(x, d + 1));
      if (v && typeof v === "object") { const o = {}; for (const k of Object.keys(v).slice(0, 80)) o[k] = sensitive.test(k) ? "[hidden]" : scrub(v[k], d + 1); return o; }
      return v;
    };
    if (sensitive.test(path || "") || (fields || []).some((f) => sensitive.test(f))) return "That path names something that looks like a secret (a token, a password…): BasicShell doesn't give those.";
    let r, text;
    try {
      r = await fetch(url, { credentials: "include", headers: { Accept: "application/json, text/plain, */*" } });
      text = await r.text();
    } catch (e) { return "Couldn't get " + url + ": " + (e && e.message || e); }
    const type = r.headers.get("content-type") || "";
    const head = "GET " + url + " → " + r.status + " " + type.split(";")[0] + ", " + (text.length > 1024 ? Math.round(text.length / 1024) + " KB" : text.length + " B");
    let data;
    try { data = JSON.parse(text); } catch (e) { return head + "\nNot JSON. It starts:\n" + text.replace(/\s+/g, " ").slice(0, 400); }
    const kind = (v) => v === null ? "null" : Array.isArray(v) ? "array" : typeof v;
    const shape = (v, d) => {
      if (Array.isArray(v)) return "array(" + v.length + ")" + (v.length ? " of " + shape(v[0], d + 1) : "");
      if (v && typeof v === "object") {
        if (d >= 3) return "{…}";
        const keys = Object.keys(v);
        return "{ " + keys.slice(0, 24).map((k) => k + ": " + shape(v[k], d + 1)).join(", ") + (keys.length > 24 ? ", …+" + (keys.length - 24) : "") + " }";
      }
      return kind(v);
    };
    const walk = (v, p) => {
      let cur = [v];
      for (const part of p.replace(/\[(\d+|\*)\]/g, ".[$1]").split(".").filter(Boolean)) {
        const next = [];
        for (const c of cur) {
          if (part === "[*]") { if (Array.isArray(c)) next.push(...c); }
          else if (/^\[\d+\]$/.test(part)) { if (Array.isArray(c) && c[+part.slice(1, -1)] !== undefined) next.push(c[+part.slice(1, -1)]); }
          else if (c && typeof c === "object" && part in c) next.push(c[part]);
        }
        cur = next;
      }
      return cur;
    };
    const cell = (v) => v === undefined ? "-" : typeof v === "string" ? v.replace(/\s+/g, " ").slice(0, 160) : JSON.stringify(scrub(v, 0)).slice(0, 160);
    if (!path) {
      const lists = [];
      const find = (v, p, d) => {
        if (lists.length >= 6 || d > 3) return;
        if (Array.isArray(v)) { if (v.length > 1) lists.push((p || "[*]") + " (" + v.length + ")"); return; }
        if (v && typeof v === "object") for (const k of Object.keys(v).slice(0, 30)) find(v[k], p ? p + "." + k : k, d + 1);
      };
      find(data, "", 0);
      let sample = data;
      if (Array.isArray(data)) sample = data[0]; else { const first = lists[0]; if (first) { const q = first.replace(/ \(\d+\)$/, ""); sample = (walk(data, q)[0] || [])[0]; } }
      const out = [head, "shape: " + shape(data, 0)];
      if (lists.length) out.push("lists: " + lists.join(", ") + (lists.length ? "  (path \"" + lists[0].replace(/ \(\d+\)$/, "") + "[*]\" with `fields` takes one row each)" : ""));
      out.push("sample: " + JSON.stringify(scrub(sample, 0)).slice(0, 900));
      return out.join("\n");
    }
    const found = walk(data, path);
    if (!found.length) return head + "\nNothing at " + path + ". The shape is: " + shape(data, 0);
    let rows = found;
    // A single list at the path stands for its items.
    if (found.length === 1 && Array.isArray(found[0]) && !/\[\d+\]$/.test(path)) rows = found[0];
    const all = rows.length;
    rows = rows.slice(0, limit);
    const lines = rows.map((row) => fields && fields.length ? fields.map((f) => cell(walk(row, f)[0])).join(" | ") : cell(row));
    let body = lines.join("\n");
    if (body.length > max) body = body.slice(0, max) + "\n… cut at " + max + " characters.";
    return head + "\n" + all + " at " + path + (all > rows.length ? ", first " + rows.length : "") + (fields && fields.length ? " (" + fields.join(" | ") + ")" : "") + ":\n" + body;
    """#

    // MARK: - when an action's effects are over (the tracker)

    /// In the page's own world, because it is the page's timers, frames and requests it has to see. Put
    /// there once per document, the first time an agent acts in it, so a page nobody works in pays nothing.
    /// What is going on when an action begins is background; what is started after it, by it or by
    /// anything it started, is waited for: so a page that reacts after 400 ms is waited for, and a page
    /// that does nothing is not (measured against a 150 ms window of no change: that missed a third of the
    /// reactions it was tried on and waited 107 ms too long on average; this missed none and waited 43).
    /// A page that is never quiet within the cap is noisy: for the rest of the document only the old window.
    static let tracker = #"""
// A page is quiet when nothing the action started is still to happen. Everything that was already
// going on when the action began (timers, frames, requests, animations, images) is background; what is
// started after it, by the action or by anything it started, is not, until it has run.
(() => {
  const KEY = Symbol.for('basicshell.quiet');
  if (window[KEY]) return;
  const st0 = window.setTimeout.bind(window), ct0 = window.clearTimeout.bind(window), ra0 = window.requestAnimationFrame.bind(window);
  const H = 600;                                  // a timer longer than this is not waited for
  const S = { cur: null, active: false, timers: new Map(), raf: new Map(), net: new Map(), seq: 0, bgImages: new WeakSet(), bgAnimations: new WeakSet(),
              watching: new WeakSet(), listeners: new Set(), noisy: false, born: 0, strikes: 0, waste: 0, fast: 0, netStart: new Map() };
  const tell = () => { for (const f of [...S.listeners]) f(); };
  const tag = () => { const t = S.cur === 'bg' ? 'bg' : S.active ? 'fg' : 'bg'; if (t === 'fg') S.born = performance.now(); return t; };
  const st = window.setTimeout, ct = window.clearTimeout, ra = window.requestAnimationFrame, ca = window.cancelAnimationFrame, fe = window.fetch;

  // Proxies around the natives, not functions of our own: a page that asks a function for its source (as
  // detectors of tampering do) is told "[native code]", and `name` and `length` are the native's.
  const wrap = (target, apply) => new Proxy(target, { apply });
  window.setTimeout = wrap(st, (target, self, args) => {
    const fn = args[0], ms = Number(args[1]) || 0;
    if (typeof fn !== 'function') return Reflect.apply(target, self, args);
    const t = tag();
    const rest = args.slice(2);
    const id = Reflect.apply(target, self, [function () {
      const was = S.cur; S.cur = t; S.timers.delete(id);
      try { return fn.apply(this, arguments); } finally { S.cur = was; tell(); }
    }, ms, ...rest]);
    S.timers.set(id, ms <= H ? t : 'bg');
    return id;
  });
  window.clearTimeout = wrap(ct, (target, self, args) => { if (S.timers.delete(args[0])) tell(); return Reflect.apply(target, self, args); });
  window.requestAnimationFrame = wrap(ra, (target, self, args) => {
    const fn = args[0], t = tag();
    const id = Reflect.apply(target, self, [function (ts) {
      const was = S.cur; S.cur = t; S.raf.delete(id);
      try { return fn.call(this, ts); } finally { S.cur = was; tell(); }
    }]);
    S.raf.set(id, t);
    return id;
  });
  window.cancelAnimationFrame = wrap(ca, (target, self, args) => { if (S.raf.delete(args[0])) tell(); return Reflect.apply(target, self, args); });

  const track = (promise, t) => { const id = ++S.seq; S.net.set(id, t); S.netStart.set(id, performance.now()); const end = () => { S.net.delete(id); S.netStart.delete(id); tell(); }; promise.then(end, end); return id; };
  const response = new WeakMap();
  window.fetch = wrap(fe, (target, self, args) => {
    const t = tag();
    const p = Reflect.apply(target, self, args);
    track(p, t);
    p.then((r) => response.set(r, t), () => {});
    return p;
  });
  for (const m of ['json', 'text', 'blob', 'arrayBuffer', 'formData']) {
    const o = Response.prototype[m];
    if (!o) continue;
    Response.prototype[m] = wrap(o, (target, self, args) => { const p = Reflect.apply(target, self, args); track(p, response.get(self) || 'bg'); return p; });
  }
  XMLHttpRequest.prototype.send = wrap(XMLHttpRequest.prototype.send, (target, self, args) => {
    const id = ++S.seq; S.net.set(id, tag()); S.netStart.set(id, performance.now());
    self.addEventListener('loadend', () => { S.net.delete(id); S.netStart.delete(id); tell(); }, { once: true });
    return Reflect.apply(target, self, args);
  });
  document.addEventListener('load', tell, true); document.addEventListener('error', tell, true);

  const animations = () => document.getAnimations().filter((a) => {
    if (a.playState !== 'running' || S.bgAnimations.has(a)) return false;
    const end = a.effect && a.effect.getComputedTiming().endTime;
    return Number.isFinite(end);
  });
  const inView = (i) => { const b = i.getBoundingClientRect(); return b.width > 0 && b.height > 0 && b.bottom > 0 && b.top < innerHeight && b.right > 0 && b.left < innerWidth; };
  // A lazy image far off the page never loads by itself: it counts only when the action is one that brings
  // pictures into view (a scroll), and then once it is in view.
  const images = (lazy) => [...document.images].filter((i) => !i.complete && i.src && !S.bgImages.has(i) && (i.loading !== 'lazy' || (lazy && inView(i))));
  const count = (m) => { let n = 0; for (const t of m.values()) if (t === 'fg') n++; return n; };
  // A request is waited for as long as `budget` from when it began (a reaction fetches and renders within
  // that; a beacon or a long poll goes on much longer and is not one). `S.expiry` is when the next ages out.
  let netBudget = 1e9;
  const liveNet = () => { let n = 0; S.expiry = Infinity; const now = performance.now(); for (const [id, t] of S.net) { if (t !== 'fg') continue; const left = (S.netStart.get(id) || now) + netBudget - now; if (left > 0) { n++; S.expiry = Math.min(S.expiry, left); } } return n; };
  const causes = (lazy) => count(S.timers) + count(S.raf) + liveNet() + animations().length + images(lazy).length;
  const watch = () => { for (const a of animations()) if (!S.watching.has(a)) { S.watching.add(a); a.finished.then(tell, tell); } };
  // Task turns, not frames: a window that is covered or in the background gets no frames, and a page is
  // asked about its animations (document.getAnimations) with its styles brought up to date on the spot.
  const frames = (n) => new Promise((r) => { const go = () => { if (--n <= 0) r(); else st0(go, 0); }; st0(go, 0); });

  // The action is about to begin: all there is now is background.
  const begin = () => {
    S.active = true; S.cur = null;
    for (const m of [S.timers, S.raf, S.net]) for (const k of m.keys()) m.set(k, 'bg');
    for (const a of document.getAnimations()) S.bgAnimations.add(a);
    for (const i of document.images) if (!i.complete) S.bgImages.add(i);
    return true;
  };

  const MUT = { subtree: true, childList: true, characterData: true, attributes: true,
    attributeFilter: ['class', 'hidden', 'open', 'disabled', 'value', 'checked', 'aria-expanded', 'aria-hidden', 'aria-selected', 'aria-checked', 'aria-pressed', 'aria-busy'] };
  // Resolves when nothing the action started is pending for two frames and the page has not changed for
  // `margin` ms (a margin for what cannot be seen: messages between tasks); `cap` is the watchdog. A page
  // that never gets quiet within it is noisy: from then on only the mutation window is used.
  const settled = ({ cap = 500, margin = 30, window: win = 150, lazy = false, netBudget: nb = 1e9 } = {}) => new Promise((resolve) => {
    netBudget = nb;
    const t0 = performance.now();
    let timer = 0, done = false, checking = false, lastChange = 0, busy = false, busyEnd = 0;
    const mo = new MutationObserver(() => { lastChange = performance.now(); if (S.noisy) arm(win); else if (quiet) arm(margin); });
    let quiet = false;
    const arm = (ms) => { ct0(timer); timer = st0(() => finish(S.noisy ? 'window' : 'quiet'), ms); };
    const finish = (why) => {
      if (done) return; done = true; S.listeners.delete(check); mo.disconnect(); ct0(timer); ct0(deadline);
      if (why === 'quiet') S.strikes = 0;
      // A page that goes on being quiet quickly is forgiven its wasted waits, one for every five: a document that
      // lives for hours does not drift into the old window because of a few chance hits.
      if (why === 'quiet' && performance.now() - t0 <= win && ++S.fast >= 5) { S.fast = 0; if (S.waste > 0) S.waste--; }
      // Waiting past the old window for nothing to change is waiting wasted: twice in a document and it is not done again.
      const ms = performance.now() - t0;
      // (only when it was something pending that was waited on, not a stall of the page's own thread)
      if (ms > 300 && (busy || busyEnd > t0 + win) && lastChange < t0 + win && !S.noisy && ++S.waste >= 2) S.noisy = true;
      resolve({ ms: Math.round(performance.now() - t0), why });
    };
    const check = async () => {
      if (done || checking || S.noisy) return;
      checking = true; watch();
      // When something was pending, for how long (a stall of the page's own thread is not that).
      if (causes(lazy) > 0) busy = true; else if (busy) { busy = false; busyEnd = performance.now(); }
      if (causes(lazy) === 0) { await frames(2); watch(); if (!done && causes(lazy) === 0) { quiet = true; arm(margin); } else quiet = false; } else { quiet = false; ct0(timer); if (Number.isFinite(S.expiry) && S.expiry > 0) st0(check, S.expiry + 2); }
      checking = false;
    };
    mo.observe(document.documentElement, MUT);
    // Two in a row, with new work still being started each time, and the page is noisy.
    const deadline = st0(() => {
      if (done) return;
      if (performance.now() - S.born < 300 && ++S.strikes >= 2) S.noisy = true;
      // What was still pending has shown it is long-lived: it is background from now on, and the next action need not wait for it.
      for (const m of [S.timers, S.raf, S.net]) for (const k of m.keys()) m.set(k, 'bg');
      for (const a of document.getAnimations()) S.bgAnimations.add(a);
      for (const i of document.images) if (!i.complete) S.bgImages.add(i);
      finish('cap');
    }, cap);
    if (S.noisy) arm(win); else { S.listeners.add(check); st0(check, 0); }
  });

  const api = { native: { st0, ct0, ra0 }, begin, settled, state: () => ({ timers: count(S.timers), raf: count(S.raf), net: count(S.net), anim: animations().length, imgs: images().length, noisy: S.noisy, waste: S.waste }) };
  Object.defineProperty(window, KEY, { value: api, enumerable: false });
})();
"""#

    // MARK: - frames from other sites

    static let frameHandler = "basicShellAgentFrame"

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

    static let logHandler = "basicShellAgentLog"

    /// In every page while the developer tools are on: what goes to the
    /// console, errors nobody caught, and what is asked of the network,
    /// told to BasicShell, which keeps the last of them for each tab. With
    /// `bodies` the page's own fetch and XHR calls are told in full: headers
    /// and bodies, with what looks like a secret replaced.
    static func watch(bodies: Bool) -> WKUserScript {
        WKUserScript(source: watchSource.replacingOccurrences(of: "__BODIES__", with: bodies ? "true" : "false"),
                     injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    }

    private static let watchSource = #"""
    (() => {
      const bridge = window.webkit && webkit.messageHandlers && webkit.messageHandlers.basicShellAgentLog;
      if (!bridge) return;
      const bodies = __BODIES__;
      const post = (kind, text, detail) => { try { bridge.postMessage({ kind, text: String(text).slice(0, 2000), detail: detail ? String(detail).slice(0, 14000) : "", frame: window === top ? "" : location.host }); } catch (e) {} };
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

      // What is in a body or a header that nobody but the person may have.
      const sensitive = /pass(word|wd)?|pwd|secret|token|otp|cvv|cvc|card.?num|credential|authoriz|api.?key|session|jwt|ssn|private/i;
      const scrub = (v, depth) => {
        if (depth > 6) return "…";
        if (Array.isArray(v)) return v.slice(0, 50).map((x) => scrub(x, depth + 1));
        if (v && typeof v === "object") { const o = {}; for (const k of Object.keys(v).slice(0, 80)) o[k] = sensitive.test(k) ? "[hidden]" : scrub(v[k], depth + 1); return o; }
        return v;
      };
      const textual = (type) => /(json|text|xml|javascript|html|x-www-form-urlencoded|graphql)/i.test(type || "");
      const bodyText = (value, type) => {
        let text = String(value);
        try { if (/json/i.test(type || "") || /^\s*[\[{]/.test(text)) return JSON.stringify(scrub(JSON.parse(text), 0)).slice(0, 6000); } catch (e) {}
        if (/x-www-form-urlencoded/i.test(type || "") || /^[\w.%+\-\[\]]+=/.test(text)) {
          try { const p = new URLSearchParams(text); for (const k of [...p.keys()]) if (sensitive.test(k)) p.set(k, "[hidden]"); return p.toString().slice(0, 6000); } catch (e) {}
        }
        return sensitive.test(text) ? "[hidden: it may hold a secret]" : text.slice(0, 6000);
      };
      const headersOf = (h) => {
        const o = {};
        try { new Headers(h).forEach((v, k) => { o[k] = /^(authorization|cookie|set-cookie|proxy-authorization)$/i.test(k) || sensitive.test(k) ? "[hidden]" : String(v).slice(0, 300); }); } catch (e) {}
        return o;
      };
      const sentBody = (body) => {
        if (body == null) return "";
        if (typeof body === "string" || body instanceof URLSearchParams) return String(body);
        if (typeof FormData !== "undefined" && body instanceof FormData) return "[form data: " + [...body.keys()].map((k) => sensitive.test(k) ? "[hidden]" : k).join(", ") + "]";
        if (body && body.size != null) return "[binary, " + body.size + " bytes]";
        if (body && body.byteLength != null) return "[binary, " + body.byteLength + " bytes]";
        return "[not captured]";
      };
      const detail = (method, url, status, ms, req, res) => {
        const out = [method + " " + url + " → " + status + " (" + ms + " ms)"];
        if (req.headers && Object.keys(req.headers).length) out.push("Request headers: " + JSON.stringify(req.headers));
        if (req.body) out.push("Request body: " + bodyText(req.body, (req.headers && (req.headers["content-type"] || req.headers["Content-Type"])) || ""));
        if (res && res.headers && Object.keys(res.headers).length) out.push("Response headers: " + JSON.stringify(res.headers));
        if (res && res.body != null && res.body !== "") out.push("Response body: " + bodyText(res.body, res.headers && res.headers["content-type"]));
        return out.join("\n");
      };
      const sent = (method, url, status, started, more) => {
        const ms = Math.round(performance.now() - started);
        const line = method + " " + url + " → " + status + " (" + ms + " ms)";
        if (!bodies || !more) return post("network", line);
        Promise.race([Promise.resolve(more), new Promise((r) => setTimeout(() => r(null), 3000))])
          .then((m) => post("network", line, m ? detail(method, url, status, ms, m.req, m.res) : ""), () => post("network", line));
      };

      const realFetch = window.fetch;
      if (realFetch) window.fetch = function (input, init) {
        const started = performance.now();
        const method = ((init && init.method) || (input && input.method) || "GET").toUpperCase();
        let url = ""; try { url = new URL(typeof input === "string" ? input : input.url, location.href).href; } catch (e) {}
        let req = null;
        if (bodies) { try { req = { headers: headersOf((init && init.headers) || (input && input.headers) || {}), body: init && init.body != null ? sentBody(init.body) : "" }; } catch (e) { req = { headers: {}, body: "" }; } }
        const result = realFetch.apply(this, arguments);
        result.then((r) => {
          let more = null;
          if (bodies) {
            const type = r.headers.get("content-type") || "", size = Number(r.headers.get("content-length") || 0);
            const res = { headers: headersOf(r.headers), body: "" };
            more = textual(type) && size < 2e6 ? r.clone().text().then((t) => ({ req, res: { ...res, body: t } }), () => ({ req, res })) : { req, res };
          }
          sent(method, url, r.status, started, more);
        }, (e) => sent(method, url, "failed: " + (e && e.message), started, null));
        return result;
      };
      const open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send, setHeader = XMLHttpRequest.prototype.setRequestHeader;
      XMLHttpRequest.prototype.open = function (method, url) {
        try { this.__agent = [String(method).toUpperCase(), new URL(url, location.href).href]; this.__agentHeaders = {}; } catch (e) {}
        return open.apply(this, arguments);
      };
      XMLHttpRequest.prototype.setRequestHeader = function (name, value) {
        if (this.__agentHeaders) this.__agentHeaders[name] = value;
        return setHeader.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function (body) {
        const started = performance.now(), note = this.__agent;
        if (note) this.addEventListener("loadend", () => {
          let more = null;
          if (bodies) {
            try {
              const raw = this.getAllResponseHeaders().trim().split(/\r?\n/).filter(Boolean).reduce((h, l) => { const i = l.indexOf(":"); if (i > 0) h[l.slice(0, i).trim()] = l.slice(i + 1).trim(); return h; }, {});
              const type = this.getResponseHeader("content-type") || "";
              let text = "";
              if (textual(type)) text = this.responseType === "" || this.responseType === "text" ? this.responseText : this.responseType === "json" ? JSON.stringify(this.response) : "";
              more = { req: { headers: headersOf(this.__agentHeaders || {}), body: sentBody(body) }, res: { headers: headersOf(raw), body: text } };
            } catch (e) { more = null; }
          }
          sent(note[0], note[1], this.status || "failed", started, more);
        });
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
    """#

    final class Log: NSObject, WKScriptMessageHandler {
        static let shared = Log()

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let tab = message.webView?.navigationDelegate as? Tab, let body = message.body as? [String: Any],
                  let kind = body["kind"] as? String, let text = body["text"] as? String else { return }
            let frame = body["frame"] as? String ?? ""
            tab.logSerial += 1
            tab.logged.append(Tab.Logged(id: tab.logSerial, date: Date(), kind: kind, text: frame.isEmpty ? text : "[\(frame)] \(text)", detail: body["detail"] as? String ?? ""))
            if tab.logged.count > 600 { tab.logged.removeFirst(tab.logged.count - 600) }
        }
    }

    /// What pages made from now on are given while the agent is let in: the
    /// frames' script, and the watching one while the developer tools are on.
    static func attach(to config: WKWebViewConfiguration) {
        guard AgentAccess.enabled else { return }
        config.userContentController.addUserScript(frames)
        config.userContentController.add(Frames.shared, contentWorld: world, name: frameHandler)
        guard AgentAccess.developer else { return }
        config.userContentController.addUserScript(watch(bodies: AgentAccess.bodies))
        config.userContentController.add(Log.shared, contentWorld: .page, name: logHandler)
    }
}
#endif
