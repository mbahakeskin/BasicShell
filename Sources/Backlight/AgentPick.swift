#if AGENT
import AppKit
import WebKit

// Pick Element: the person points at an element of the page, and the agent is
// told what it is: where it is in the page (a selector), what it is (tag, role,
// name, text, its HTML), how it is drawn (the styles that aren't the default's),
// which React or Vue components it belongs to and, where a development build
// says, the file they come from, and the errors the page has had.
//
// Either the agent asks (the `pick` tool: the tab comes to the front, a
// banner says to click, the call waits up to a minute), or the person does,
// from a page's right-click menu (Pick Element for the Agent), and the agent
// has it the next time it calls `selection`. Esc, or the time running out,
// picks nothing. Never an element holding a password or a card's number.
// The script runs in the agent's own world: the page's scripts can't see it
// or answer it.
enum AgentPick {
    static let source = #"""
    const TIMEOUT = 60000;
    if (window.__bsPick) window.__bsPick.cancel();
    const describe = (el) => {
      const tag = el.tagName.toLowerCase();
      const type = (el.getAttribute('type') || '').toLowerCase();
      const auto = (el.getAttribute('autocomplete') || '').toLowerCase();
      if (type === 'password' || /cc-|one-time-code/.test(auto)) return { secret: true };
      const esc = (s) => (window.CSS && CSS.escape) ? CSS.escape(s) : s.replace(/[^\w-]/g, '\\$&');
      const part = (e) => {
        if (e.id && document.querySelectorAll('#' + esc(e.id)).length === 1) return '#' + esc(e.id);
        let s = e.tagName.toLowerCase();
        const classes = [...e.classList].filter((c) => c.length < 30 && !/\d{3,}|^css-|^sc-|^_|^[a-z]{1,2}[A-Z0-9_-]{5,}$/.test(c)).slice(0, 2);
        if (classes.length) s += '.' + classes.map(esc).join('.');
        const parent = e.parentElement;
        if (parent) {
          const same = [...parent.children].filter((c) => c.tagName === e.tagName);
          if (same.length > 1) s += ':nth-of-type(' + (same.indexOf(e) + 1) + ')';
        }
        return s;
      };
      const path = [];
      for (let e = el; e && e.nodeType === 1 && path.length < 8; e = e.parentElement) {
        const p = part(e);
        path.unshift(p);
        if (p[0] === '#' || e === document.body) break;
      }
      const roles = { a: 'link', button: 'button', select: 'combobox', textarea: 'textbox', img: 'img', nav: 'navigation', main: 'main', header: 'banner',
        footer: 'contentinfo', aside: 'complementary', ul: 'list', ol: 'list', li: 'listitem', table: 'table', form: 'form', dialog: 'dialog',
        h1: 'heading', h2: 'heading', h3: 'heading', h4: 'heading', h5: 'heading', h6: 'heading', summary: 'button', label: 'label' };
      const inputRoles = { checkbox: 'checkbox', radio: 'radio', button: 'button', submit: 'button', range: 'slider', search: 'searchbox', number: 'spinbutton' };
      const role = el.getAttribute('role') || (tag === 'input' ? (inputRoles[type] || 'textbox') : roles[tag] || '');
      const label = el.getAttribute('aria-label') || el.getAttribute('alt') || el.getAttribute('title') || el.getAttribute('placeholder') || '';
      const text = (el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim();
      const keep = ['id', 'class', 'href', 'src', 'type', 'name', 'role', 'for', 'data-testid', 'data-test', 'data-cy', 'aria-label', 'aria-expanded', 'aria-selected', 'aria-checked', 'aria-disabled', 'disabled', 'placeholder'];
      const attrs = {};
      for (const k of keep) { const v = el.getAttribute(k); if (v !== null) attrs[k] = v.length > 160 ? v.slice(0, 159) + '…' : v; }
      const cs = getComputedStyle(el);
      const plain = new Set(['', 'auto', 'normal', 'none', '0px', 'static', 'visible', 'start', 'stretch', 'rgba(0, 0, 0, 0)', '0', '1', 'baseline', 'row', 'nowrap', 'repeat', 'scroll', 'medium', 'currentcolor']);
      const names = ['display', 'position', 'width', 'height', 'margin', 'padding', 'border', 'border-radius', 'color', 'background-color', 'background-image', 'font-family',
        'font-size', 'font-weight', 'line-height', 'text-align', 'opacity', 'z-index', 'overflow', 'flex-direction', 'justify-content', 'align-items', 'gap', 'grid-template-columns',
        'transform', 'box-shadow', 'cursor', 'visibility'];
      const styles = {};
      for (const n of names) {
        const v = cs.getPropertyValue(n);
        if (plain.has(v.trim()) || (n === 'border' && /^0px/.test(v))) continue;
        styles[n] = v.length > 120 ? v.slice(0, 119) + '…' : v;
      }
      const components = [];
      let source = '';
      const reactKey = Object.keys(el).find((k) => k.startsWith('__reactFiber$') || k.startsWith('__reactInternalInstance$'));
      if (reactKey) {
        for (let f = el[reactKey], n = 0; f && n < 40 && components.length < 5; f = f.return, n++) {
          if (typeof f.type === 'function') {
            components.push('React ' + (f.type.displayName || f.type.name || 'Anonymous'));
            if (!source && f._debugSource) source = f._debugSource.fileName + ':' + f._debugSource.lineNumber;
          }
        }
      }
      if (el.__vueParentComponent) {
        for (let c = el.__vueParentComponent, n = 0; c && n < 40 && components.length < 5; c = c.parent, n++) {
          const t = c.type || {};
          components.push('Vue ' + (t.name || t.__name || 'Anonymous'));
          if (!source && t.__file) source = t.__file;
        }
      } else if (el.__vue__) {
        for (let c = el.__vue__, n = 0; c && n < 40 && components.length < 5; c = c.$parent, n++) {
          components.push('Vue ' + ((c.$options && (c.$options.name || c.$options._componentTag)) || 'Anonymous'));
        }
      }
      const rect = el.getBoundingClientRect();
      const html = el.outerHTML || '';
      return {
        selector: path.join(' > '), tag, role, name: label || (text.length < 80 ? text : ''), text: text.length > 240 ? text.slice(0, 239) + '…' : text,
        html: html.length > 1600 ? html.slice(0, 1599) + '…' : html, attrs, styles, components, source,
        rect: { x: Math.round(rect.x), y: Math.round(rect.y), w: Math.round(rect.width), h: Math.round(rect.height) },
        page: location.href, scroll: { x: Math.round(scrollX), y: Math.round(scrollY) },
      };
    };
    return await new Promise((resolve) => {
      const host = document.createElement('div');
      host.setAttribute('style', 'all:initial;position:fixed;left:0;top:0;width:100vw;height:100vh;z-index:2147483647;cursor:crosshair;');
      const root = host.attachShadow({ mode: 'closed' });
      root.innerHTML = '<style>.box{position:fixed;border:2px solid #4da3ff;background:rgba(77,163,255,.18);border-radius:2px;pointer-events:none}' +
        '.tip{position:fixed;left:50%;top:12px;transform:translateX(-50%);font:13px -apple-system,system-ui,sans-serif;background:#111;color:#fff;padding:7px 12px;border-radius:8px;pointer-events:none}</style>' +
        '<div class="box" hidden></div><div class="tip">Click the element you mean · Esc cancels</div>';
      const box = root.querySelector('.box');
      let target = null, done = false, timer = null;
      const under = (x, y) => { host.style.pointerEvents = 'none'; const el = document.elementFromPoint(x, y); host.style.pointerEvents = ''; return el; };
      const finish = (value) => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        window.removeEventListener('keydown', key, true);
        host.remove();
        window.__bsPick = null;
        resolve(value);
      };
      const key = (e) => { if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); finish({ cancelled: true }); } };
      host.addEventListener('mousemove', (e) => {
        const el = under(e.clientX, e.clientY);
        if (!el || el === document.documentElement) return;
        target = el;
        const r = el.getBoundingClientRect();
        box.hidden = false;
        box.style.left = r.left + 'px'; box.style.top = r.top + 'px'; box.style.width = r.width + 'px'; box.style.height = r.height + 'px';
      });
      host.addEventListener('mousedown', (e) => { e.preventDefault(); e.stopPropagation(); });
      host.addEventListener('click', (e) => {
        e.preventDefault(); e.stopPropagation();
        const el = under(e.clientX, e.clientY) || target;
        finish(el ? describe(el) : { cancelled: true });
      });
      window.addEventListener('keydown', key, true);
      document.documentElement.appendChild(host);
      timer = setTimeout(() => finish({ cancelled: true, timeout: true }), TIMEOUT);
      window.__bsPick = { cancel: () => finish({ cancelled: true }) };
    });
    """#

    /// What the agent is told of a pick, in words.
    @MainActor
    static func describe(_ found: [String: Any], in tab: Tab) -> String {
        var lines: [String] = []
        let tag = found["tag"] as? String ?? "element"
        let role = (found["role"] as? String).flatMap { $0.isEmpty ? nil : " (role \($0))" } ?? ""
        let name = (found["name"] as? String).flatMap { $0.isEmpty ? nil : " “\($0)”" } ?? ""
        lines.append("The person picked a <\(tag)>\(role)\(name) on \(found["page"] as? String ?? tab.url?.absoluteString ?? "the page").")
        if let selector = found["selector"] as? String { lines.append("Selector: \(selector)") }
        if let rect = found["rect"] as? [String: Any] {
            lines.append("Box in the view: x \(rect["x"] ?? 0), y \(rect["y"] ?? 0), \(rect["w"] ?? 0) × \(rect["h"] ?? 0) (page scrolled to \((found["scroll"] as? [String: Any])?["y"] ?? 0)).")
        }
        if let components = found["components"] as? [String], !components.isEmpty { lines.append("Components, innermost first: " + components.joined(separator: " ‹ ")) }
        if let source = found["source"] as? String, !source.isEmpty { lines.append("Source: \(source)") }
        if let attrs = found["attrs"] as? [String: String], !attrs.isEmpty {
            lines.append("Attributes: " + attrs.sorted { $0.key < $1.key }.map { "\($0.key)=\"\($0.value)\"" }.joined(separator: " "))
        }
        if let text = found["text"] as? String, !text.isEmpty { lines.append("Text: \(text)") }
        if let styles = found["styles"] as? [String: String], !styles.isEmpty {
            lines.append("Styles that aren't the default's:")
            lines += styles.sorted { $0.key < $1.key }.map { "  \($0.key): \($0.value)" }
        }
        if let html = found["html"] as? String { lines.append("HTML:\n\(html)") }
        // What went wrong lately in the page, when the developer tools are on.
        if AgentPower.developer.isOn {
            let trouble = tab.logged.suffix(80).filter { $0.kind == "error" || ($0.kind == "network" && ($0.text.contains("→ 4") || $0.text.contains("→ 5") || $0.text.contains("failed"))) }.suffix(5)
            if !trouble.isEmpty { lines.append("Recent errors in the page:\n" + trouble.map { "  [\($0.kind)] \($0.text.prefix(200))" }.joined(separator: "\n")) }
        }
        return lines.joined(separator: "\n")
    }

    /// The person's own: from the menu, what is picked waits for the agent's next `selection`.
    @MainActor
    static func ask(_ tab: Tab) {
        guard let web = tab.webView, let window = tab.host as? BrowserWindow else { return }
        web.callAsyncJavaScript(source, arguments: [:], in: nil, in: AgentPage.world) { result in
            Task { @MainActor in
                guard case .success(let value) = result, let found = value as? [String: Any], found["cancelled"] == nil else { return window.say("Nothing picked") }
                if found["secret"] as? Bool == true { return window.say("That holds a secret: the agent can't have it") }
                tab.picked = describe(found, in: tab)
                window.say("Picked. Ask the agent to look at it (it has it from selection).")
            }
        }
    }
}
#endif
