import AppKit
import SwiftUI
import WebKit

// What a developer's own server gets: its full address (the port too) in the
// bar, a mark that says it is one, and a JSON document shown as a tree.

enum LocalDev {
    /// A server on this machine or this network: localhost and its
    /// subdomains, `.test`, a private address.
    static func isLocal(_ url: URL?) -> Bool {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host()?.lowercased() else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".test") || host == "[::1]" || host == "::1" || host == "0.0.0.0" { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 127 || parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1]))
    }

    /// A JSON document (the browser shows it as one line of text) turned into
    /// a tree that folds, with the raw text a button away. Only a document
    /// that is JSON and nothing else.
    static let jsonScript = WKUserScript(source: """
    (function () {
      var type = document.contentType || '';
      if (type !== 'application/json' && !/\\+json$/.test(type) && type !== 'text/json') return;
      var pre = document.body && document.body.children.length === 1 && document.body.firstElementChild;
      if (!pre || pre.tagName !== 'PRE') return;
      var raw = pre.textContent;
      if (raw.length > 3000000) return;
      var data;
      try { data = JSON.parse(raw); } catch (e) { return; }
      var style = document.createElement('style');
      style.textContent = ':root{color-scheme:light dark;--k:#7c3aed;--s:#047857;--n:#b45309;--b:#be185d;--m:#6b7280}' +
        '@media(prefers-color-scheme:dark){:root{--k:#a78bfa;--s:#6ee7b7;--n:#fbbf24;--b:#f472b6;--m:#9ca3af}}' +
        'body{margin:0;font:13px/1.55 ui-monospace,SFMono-Regular,Menlo,monospace}' +
        '#bar{position:sticky;top:0;display:flex;gap:8px;padding:8px 16px;background:Canvas;border-bottom:1px solid color-mix(in srgb,CanvasText 12%,transparent)}' +
        '#bar button{font:12px system-ui;padding:3px 10px;border-radius:99px;border:1px solid color-mix(in srgb,CanvasText 20%,transparent);background:transparent;color:inherit}' +
        '#tree,#raw{padding:12px 16px 40px}#raw{white-space:pre-wrap;word-break:break-all;display:none}' +
        'details{margin-left:1.2em}summary{cursor:pointer;margin-left:-1.2em;list-style:none}' +
        'summary::-webkit-details-marker{display:none}summary::before{content:"▸";display:inline-block;width:1.2em;color:var(--m)}' +
        'details[open]>summary::before{content:"▾"}details[open]>summary .hint{display:none}' +
        '.k{color:var(--k)}.s{color:var(--s)}.n{color:var(--n)}.b{color:var(--b)}.m,.hint{color:var(--m)}.row{margin-left:1.2em}';
      function esc(t) { return String(t).replace(/[&<>]/g, function (c) { return {'&': '&amp;', '<': '&lt;', '>': '&gt;'}[c]; }); }
      function leaf(v) {
        if (v === null) return '<span class="b">null</span>';
        if (typeof v === 'string') return '<span class="s">' + esc(JSON.stringify(v)) + '</span>';
        if (typeof v === 'number') return '<span class="n">' + v + '</span>';
        return '<span class="b">' + v + '</span>';
      }
      function node(v, key, last, depth) {
        var name = key === null ? '' : '<span class="k">' + esc(JSON.stringify(key)) + '</span>: ';
        var comma = last ? '' : ',';
        if (v === null || typeof v !== 'object') return '<div class="row">' + name + leaf(v) + comma + '</div>';
        var array = Array.isArray(v), keys = array ? null : Object.keys(v), count = array ? v.length : keys.length;
        var open = array ? '[' : '{', close = array ? ']' : '}';
        if (!count) return '<div class="row">' + name + open + close + comma + '</div>';
        var html = '<details' + (depth < 2 ? ' open' : '') + '><summary>' + name + open +
          '<span class="hint"> ' + count + (array ? (count === 1 ? ' item' : ' items') : (count === 1 ? ' key' : ' keys')) + ' ' + close + comma + '</span></summary>';
        for (var i = 0; i < count; i++) html += node(array ? v[i] : v[keys[i]], array ? null : keys[i], i === count - 1, depth + 1);
        return html + '<div class="row">' + close + comma + '</div></details>';
      }
      document.body.innerHTML = '<div id="bar"><button id="view">Raw</button><button id="copy">Copy</button></div>' +
        '<div id="tree">' + node(data, null, true, 0) + '</div><pre id="raw"></pre>';
      var shown = JSON.stringify(data, null, 2);
      document.getElementById('raw').textContent = shown;
      document.head.appendChild(style);
      var tree = document.getElementById('tree'), rawView = document.getElementById('raw'), view = document.getElementById('view');
      view.onclick = function () {
        var raws = rawView.style.display !== 'block';
        rawView.style.display = raws ? 'block' : 'none';
        tree.style.display = raws ? 'none' : 'block';
        view.textContent = raws ? 'Tree' : 'Raw';
      };
      document.getElementById('copy').onclick = function () { navigator.clipboard && navigator.clipboard.writeText(shown); };
    })();
    """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)
}
