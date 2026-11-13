import Foundation

/// Injected into every page (and iframe): reports video / audio / stream URLs to the app.
/// Catches <video>/<audio> sources and m3u8/mp4 requests made by players (fetch / XHR).
enum Sniffer {
    static let handlerName = "niledm"

    static let script = #"""
    (function () {
      if (window.__nileDM) return;
      window.__nileDM = true;
      var seen = {};
      var MEDIA = /\.(m3u8|mp4|m4v|mov|webm|mp3|m4a|mpd)(\?|#|$)/i;
      function post(u, tag) {
        try { u = new URL(u, location.href).href; } catch (e) { return; }
        if (!/^https?:/i.test(u) || seen[u]) return;
        seen[u] = 1;
        try {
          window.webkit.messageHandlers.niledm.postMessage({
            url: u, tag: tag || "", page: location.href,
            title: (window.top === window.self ? document.title : "")
          });
        } catch (e) {}
      }
      try {
        var origFetch = window.fetch;
        if (origFetch) {
          window.fetch = function (input, init) {
            try {
              var u = typeof input === "string" ? input : (input && input.url);
              if (u && MEDIA.test(u)) post(u, "fetch");
            } catch (e) {}
            return origFetch.apply(this, arguments);
          };
        }
      } catch (e) {}
      try {
        var origOpen = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function (method, u) {
          try { if (u && MEDIA.test(String(u))) post(String(u), "xhr"); } catch (e) {}
          return origOpen.apply(this, arguments);
        };
      } catch (e) {}
      function scan() {
        var els = document.querySelectorAll("video, audio, source");
        for (var i = 0; i < els.length; i++) {
          var s = els[i].currentSrc || els[i].src;
          if (s && s.indexOf("blob:") !== 0 && s.indexOf("data:") !== 0) post(s, els[i].tagName.toLowerCase());
        }
      }
      document.addEventListener("play", scan, true);
      document.addEventListener("loadedmetadata", scan, true);
      setInterval(scan, 2500);
    })();
    """#

    /// Draws a small round download button on the top corner of every video in the page.
    /// Tapping it sends the video's address to the app (or asks the app to pick the stream it caught).
    static let buttons = #"""
    (function () {
      if (window.__nileDMButtons) return;
      window.__nileDMButtons = true;
      var host = null, root = null, items = [], pending = false;
      var ICON = '<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="white" stroke-width="2.6" ' +
        'stroke-linecap="round" stroke-linejoin="round"><path d="M12 4v11"/><path d="M7 10.5l5 5 5-5"/><path d="M5 20h14"/></svg>';
      var CSS = "button{all:initial;box-sizing:border-box;position:fixed;width:42px;height:42px;border-radius:21px;" +
        "background:rgba(0,0,0,.62);border:2px solid #14b8a6;display:flex;align-items:center;justify-content:center;" +
        "box-shadow:0 2px 10px rgba(0,0,0,.35);-webkit-tap-highlight-color:transparent;cursor:pointer;" +
        "pointer-events:auto;transition:transform .12s,background .2s}" +
        "button:active{transform:scale(.88)}button.done{background:#14b8a6}";
      function on() { return window.__ndmButtonsOn !== false; }
      function ensureHost() {
        if (host && host.isConnected) return;
        host = document.createElement("div");
        host.style.cssText = "all:initial;position:fixed;left:0;top:0;width:0;height:0;z-index:2147483647;";
        root = host.attachShadow({ mode: "closed" });
        var st = document.createElement("style");
        st.textContent = CSS;
        root.appendChild(st);
        (document.documentElement || document.body).appendChild(host);
        items = [];
      }
      function sources(v) {
        var l = [];
        if (v.currentSrc) l.push(v.currentSrc);
        if (v.src) l.push(v.src);
        var s = v.querySelectorAll("source");
        for (var i = 0; i < s.length; i++) if (s[i].src) l.push(s[i].src);
        return l;
      }
      function tap(it) {
        var l = sources(it.v);
        try {
          window.webkit.messageHandlers.niledm.postMessage({
            action: "videoButton", sources: l, page: location.href,
            title: (window.top === window.self ? document.title : "")
          });
        } catch (x) {}
        it.b.className = "done";
        setTimeout(function () { it.b.className = ""; }, 1200);
      }
      function make(v) {
        var it = { v: v, b: document.createElement("button") };
        it.b.setAttribute("aria-label", "Download");
        it.b.innerHTML = ICON;
        ["touchstart", "touchend", "pointerdown", "pointerup", "mousedown", "mouseup"].forEach(function (t) {
          it.b.addEventListener(t, function (e) { e.stopPropagation(); }, true);
        });
        it.b.addEventListener("click", function (e) { e.preventDefault(); e.stopPropagation(); tap(it); }, true);
        root.appendChild(it.b);
        return it;
      }
      function place() {
        var vids = on() ? document.getElementsByTagName("video") : [];
        var shown = [];
        for (var i = 0; i < vids.length; i++) {
          var v = vids[i], r = v.getBoundingClientRect();
          if (r.width < 120 || r.height < 68 || r.bottom < 30 || r.right < 30 ||
              r.top > innerHeight - 30 || r.left > innerWidth - 30) continue;
          var cs = getComputedStyle(v);
          if (cs.visibility === "hidden" || cs.display === "none" || +cs.opacity === 0) continue;
          ensureHost();
          var it = null;
          for (var j = 0; j < items.length; j++) if (items[j].v === v) { it = items[j]; break; }
          if (!it) { it = make(v); items.push(it); }
          it.b.style.top = Math.max(r.top + 8, 8) + "px";
          it.b.style.left = Math.max(r.left + 8, 8) + "px";
          it.b.style.display = "flex";
          shown.push(v);
        }
        for (var k = items.length - 1; k >= 0; k--) {
          if (shown.indexOf(items[k].v) >= 0) continue;
          items[k].b.style.display = "none";
          if (!items[k].v.isConnected) { items[k].b.remove(); items.splice(k, 1); }
        }
      }
      function schedule() {
        if (pending) return;
        pending = true;
        requestAnimationFrame(function () { pending = false; try { place(); } catch (e) {} });
      }
      window.addEventListener("scroll", schedule, true);
      window.addEventListener("resize", schedule);
      document.addEventListener("play", schedule, true);
      document.addEventListener("loadedmetadata", schedule, true);
      setInterval(schedule, 1000);
      window.__ndmRefresh = schedule;
      window.__ndmTapFirst = function () { for (var i = 0; i < items.length; i++) if (items[i].b.style.display !== "none") return tap(items[i]); };
    })();
    """#

    /// Whether the per-video buttons are on (Settings → Video).
    static var buttonsOn: Bool { UserDefaults.standard.object(forKey: "videoButtons") as? Bool ?? true }
}
