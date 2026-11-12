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
}
