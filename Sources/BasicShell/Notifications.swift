import AppKit
import UserNotifications
import WebKit

// Notifications from the sites you allow (a message on WhatsApp Web, a mail
// in Gmail), in macOS's Notification Center.
//
// WebKit hands an app its pages' notifications only through interfaces it
// keeps to itself, and asked nothing of this one: every page saw permission
// "default" and nothing came of asking. So, as for location (Permissions),
// the page's Notification is replaced before any page script runs: asking
// comes here, you answer (remembered for the site, never for a private tab),
// and what the page shows goes to macOS. A click on one brings its tab
// forward and tells the page, as browsers do. Which site is asking comes
// from WebKit (the frame's security origin), never from the page.
enum WebNotifications {
    static let handlerName = "basicShellNotify"

    /// At launch: macOS tells this delegate about clicks, also on a
    /// notification that launched the app.
    static func start() {
        UNUserNotificationCenter.current().delegate = Center.shared
    }

    static func attach(to config: WKWebViewConfiguration) {
        let known = (try? JSONSerialization.data(withJSONObject: Permissions.shared.notifications)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        config.userContentController.addUserScript(WKUserScript(source: script.replacingOccurrences(of: "__KNOWN__", with: known),
                                                                injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        config.userContentController.addScriptMessageHandler(Handler.shared, contentWorld: .page, name: handlerName)
    }

    /// A site's answer changed: every page of it hears at once.
    static func tell(_ site: String, _ state: String) {
        for window in Windows.all {
            for tab in window.shell.tabs where tab.webView?.url?.host() == site {
                tab.webView?.evaluateJavaScript("window.__basicShellNotify && __basicShellNotify('state', 0, '\(state)')") { _, _ in }
            }
        }
    }

    private static let script = """
    (() => {
      const bridge = window.webkit && webkit.messageHandlers && webkit.messageHandlers.\(handlerName);
      if (!bridge || !window.isSecureContext) return;
      const known = __KNOWN__;
      let state = known[location.hostname] === true ? "granted" : known[location.hostname] === false ? "denied" : "default";
      const live = new Map();
      let next = 1;
      class Notification extends EventTarget {
        constructor(title, options = {}) {
          super();
          if (arguments.length === 0) throw new TypeError("Failed to construct 'Notification': 1 argument required, but only 0 present.");
          options = options || {};
          this.title = String(title);
          this.body = options.body ? String(options.body) : "";
          this.tag = options.tag ? String(options.tag) : "";
          this.icon = options.icon ? new URL(options.icon, location.href).href : "";
          this.image = options.image ? new URL(options.image, location.href).href : "";
          this.badge = options.badge ? new URL(options.badge, location.href).href : "";
          this.data = options.data === undefined ? null : options.data;
          this.dir = options.dir || "auto";
          this.lang = options.lang || "";
          this.silent = !!options.silent;
          this.renotify = !!options.renotify;
          this.requireInteraction = !!options.requireInteraction;
          this.timestamp = options.timestamp || Date.now();
          this.actions = [];
          this.onclick = this.onshow = this.onclose = this.onerror = null;
          Object.defineProperty(this, "__id", { value: next++ });
          if (state !== "granted") { setTimeout(() => this.__fire("error")); return; }
          live.set(this.__id, this);
          bridge.postMessage({ op: "show", id: this.__id, title: this.title, body: this.body, tag: this.tag, icon: this.icon, silent: this.silent })
            .then((shown) => { if (shown) this.__fire("show"); else { live.delete(this.__id); this.__fire("error"); } }, () => { live.delete(this.__id); this.__fire("error"); });
        }
        close() {
          if (!live.has(this.__id)) return;
          live.delete(this.__id);
          bridge.postMessage({ op: "close", id: this.__id, tag: this.tag }).catch(() => {});
          this.__fire("close");
        }
        __fire(type) {
          const event = new Event(type, { cancelable: type === "click" });
          const handler = this["on" + type];
          if (typeof handler === "function") { try { handler.call(this, event); } catch (x) { setTimeout(() => { throw x; }); } }
          this.dispatchEvent(event);
        }
        static get permission() { return state; }
        static get maxActions() { return 0; }
        static requestPermission(callback) {
          const answer = state !== "default" ? Promise.resolve(state)
            : bridge.postMessage({ op: "permit" }).then((given) => { state = given; return state; }, () => state);
          if (typeof callback === "function") answer.then(callback);
          return answer;
        }
      }
      Object.defineProperty(window, "Notification", { value: Notification, configurable: true, writable: true });
      Object.defineProperty(window, "__basicShellNotify", { value: (op, id, value) => {
        if (op === "state") { state = value; return; }
        const shown = live.get(id);
        if (!shown) return;
        if (op === "click") shown.__fire("click");
        if (op === "closed") { live.delete(id); shown.__fire("close"); }
      } });
      if (window.ServiceWorkerRegistration) {
        ServiceWorkerRegistration.prototype.showNotification = function (title, options) {
          return new Promise((resolve, reject) => {
            if (state !== "granted") return reject(new TypeError("No permission to show notifications"));
            const shown = new Notification(title, options);
            shown.addEventListener("show", () => resolve(), { once: true });
            shown.addEventListener("error", () => reject(new TypeError("The notification couldn't be shown")), { once: true });
          });
        };
        ServiceWorkerRegistration.prototype.getNotifications = function () { return Promise.resolve([...live.values()]); };
      }
      if (navigator.permissions && navigator.permissions.query) {
        const query = navigator.permissions.query.bind(navigator.permissions);
        navigator.permissions.query = (about) => about && about.name === "notifications"
          ? Promise.resolve(Object.assign(new EventTarget(), { name: "notifications", state: state === "default" ? "prompt" : state, onchange: null }))
          : query(about);
      }
    })();
    """

    final class Handler: NSObject, WKScriptMessageHandlerWithReply {
        static let shared = Handler()

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
            guard let web = message.webView, let tab = web.navigationDelegate as? Tab,
                  let body = message.body as? [String: Any], let op = body["op"] as? String
            else { return replyHandler(nil, "unavailable") }
            let site = message.frameInfo.securityOrigin.host
            guard !site.isEmpty else { return replyHandler(nil, "unavailable") }
            switch op {
            case "permit":
                tab.decideNotifications(site: site, in: web) { replyHandler($0 ? "granted" : "denied", nil) }
            case "show":
                guard tab.notificationsAllowed(site) else { return replyHandler(false, nil) }
                Center.shared.show(body, site: site, tab: tab)
                replyHandler(true, nil)
            case "close":
                Center.shared.close(site: site, tab: tab, id: body["id"] as? Int, tag: body["tag"] as? String)
                replyHandler(true, nil)
            default:
                replyHandler(nil, "unknown")
            }
        }
    }

    /// macOS's side: what is shown, and the clicks on it.
    final class Center: NSObject, UNUserNotificationCenterDelegate {
        static let shared = Center()
        /// A shown notification to the tab and page notification it came from.
        private var shown: [String: (tab: Tab, id: Int)] = [:]

        func show(_ body: [String: Any], site: String, tab: Tab) {
            let id = body["id"] as? Int ?? 0
            let tag = body["tag"] as? String ?? ""
            // A tag replaces the one before it with the same tag, as on the web.
            let identifier = tag.isEmpty ? "\(site)|\(UUID().uuidString)" : "\(site)|tag|\(tag)"
            let content = UNMutableNotificationContent()
            content.title = body["title"] as? String ?? site
            content.body = body["body"] as? String ?? ""
            content.subtitle = site
            content.threadIdentifier = site
            if body["silent"] as? Bool != true { content.sound = .default }
            shown[identifier] = (tab, id)
            let deliver = { (attachment: UNNotificationAttachment?) in
                if let attachment { content.attachments = [attachment] }
                let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
                Task {
                    do { try await UNUserNotificationCenter.current().add(request) }
                    catch { Debug.log("notify", "\(site): not shown: \(error.localizedDescription)") }
                }
            }
            Debug.log("notify", "\(site): \(content.title)")
            guard let icon = (body["icon"] as? String).flatMap(URL.init(string:)), ["http", "https"].contains(icon.scheme ?? "") else {
                return deliver(nil)
            }
            // The site's picture beside it, if it comes within two seconds.
            var request = URLRequest(url: icon)
            request.timeoutInterval = 2
            Task {
                var attachment: UNNotificationAttachment?
                if let (data, response) = try? await URLSession.shared.data(for: request),
                   (response as? HTTPURLResponse)?.statusCode == 200, NSImage(data: data) != nil {
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
                    if (try? data.write(to: file)) != nil {
                        attachment = try? UNNotificationAttachment(identifier: "icon", url: file, options: [UNNotificationAttachmentOptionsTypeHintKey: "public.image"])
                    }
                }
                deliver(attachment)
            }
        }

        func close(site: String, tab: Tab, id: Int?, tag: String?) {
            var identifiers = shown.filter { $0.value.tab === tab && $0.value.id == id }.map(\.key)
            if let tag, !tag.isEmpty { identifiers.append("\(site)|tag|\(tag)") }
            identifiers.forEach { shown[$0] = nil }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
        }

        /// Shown while BasicShell is in front too: the page may be in another tab.
        nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler([.banner, .list, .sound])
        }

        /// A click: its tab in front, and the page told.
        nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
            let identifier = response.notification.request.identifier
            let clicked = response.actionIdentifier == UNNotificationDefaultActionIdentifier
            completionHandler()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let (tab, id) = self.shown[identifier] else { return NSApp.activate() }
                    if clicked {
                        (tab.host as? BrowserWindow)?.show(tab)
                        tab.webView?.evaluateJavaScript("window.__basicShellNotify && __basicShellNotify('click', \(id))") { _, _ in }
                    }
                    self.shown[identifier] = nil
                    tab.webView?.evaluateJavaScript("window.__basicShellNotify && __basicShellNotify('closed', \(id))") { _, _ in }
                }
            }
        }
    }
}

extension Tab {
    /// This site may show notifications: answered for good, or in this tab.
    func notificationsAllowed(_ site: String) -> Bool {
        notificationAnswers[site] ?? (isPrivate ? nil : Permissions.shared.notifications[site]) ?? false
    }

    /// Asked once per site: remembered (not for a private tab), and then
    /// macOS's own permission for BasicShell, the first time.
    func decideNotifications(site: String, in webView: WKWebView, _ done: @escaping (Bool) -> Void) {
        let then: (Bool) -> Void = { allowed in
            guard allowed else { return done(false) }
            Task {
                let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
                Debug.log("notify", "\(site): allowed; macOS \(granted ? "allows" : "doesn't allow") BasicShell's")
                done(true)
            }
        }
        if !isPrivate, let known = Permissions.shared.notifications[site] { return then(known) }
        if let answered = notificationAnswers[site] { return then(answered) }
        let alert = NSAlert()
        alert.messageText = "Allow \(site) to show notifications?"
        alert.informativeText = "They appear in Notification Center. Settings › Privacy takes the answer back."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        Dialogs.show(alert, over: webView) { [weak self] answer in
            guard let self else { return }
            let allowed = answer == .alertFirstButtonReturn
            Debug.log("notify", "\(site): you said \(allowed ? "allow" : "don't allow")")
            self.notificationAnswers[site] = allowed
            if !self.isPrivate {
                Permissions.shared.setNotifications(site, allowed)
                WebNotifications.tell(site, allowed ? "granted" : "denied")
            }
            then(allowed)
        }
    }
}
