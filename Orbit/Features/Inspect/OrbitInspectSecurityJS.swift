extension OrbitInspectAgent {
    // Only the DOM-side half lives here (meta policies, forms, frames, subresource URLs); headers and the TLS chain come from native hooks.
    static let securitySource = ##"""

      var sec_timer = null;

      function sec_collect() {
        var secure = location.protocol === "https:";
        var metaCSP = [];
        try {
          Array.prototype.forEach.call(document.querySelectorAll("meta[http-equiv]"), function (el) {
            if ((el.getAttribute("http-equiv") || "").toLowerCase() === "content-security-policy") {
              metaCSP.push((el.getAttribute("content") || "").slice(0, 4000));
            }
          });
        } catch (e) {}

        var referrerMeta = document.querySelector("meta[name='referrer']");

        var forms = [];
        try {
          Array.prototype.forEach.call(document.forms, function (form) {
            if (forms.length >= 100 || isOurs(form)) { return; }
            forms.push({
              action: String(form.action || "").slice(0, 400),
              method: String(form.method || "get").toLowerCase(),
              pw: !!form.querySelector("input[type='password']"),
              id: idOf(form), sel: nodeLabel(form)
            });
          });
        } catch (e) {}

        var frames = [];
        try {
          Array.prototype.forEach.call(document.querySelectorAll("iframe"), function (el) {
            if (frames.length >= 100 || isOurs(el)) { return; }
            var src = String(el.src || el.getAttribute("src") || "");
            var cross = false;
            try { cross = !!src && new URL(src, location.href).origin !== location.origin; } catch (e) {}
            frames.push({
              src: src.slice(0, 400), sandbox: el.hasAttribute("sandbox"), cross: cross,
              id: idOf(el), sel: nodeLabel(el)
            });
          });
        } catch (e) {}

        // Subresource URLs written in the page, which can name an HTTP load the network log has not seen yet.
        var refs = [];
        if (secure) {
          try {
            Array.prototype.forEach.call(
              document.querySelectorAll("script[src],link[href],img[src],audio[src],video[src],source[src],embed[src],object[data]"),
              function (el) {
                if (refs.length >= 100 || isOurs(el)) { return; }
                var url = String(el.src || el.href || el.data || "");
                if (url.indexOf("http:") === 0 || url.indexOf("ws:") === 0) {
                  refs.push({ url: url.slice(0, 400), type: el.tagName.toLowerCase(), id: idOf(el), sel: nodeLabel(el) });
                }
              }
            );
          } catch (e) {}
        }

        post({
          t: "sec.page",
          href: String(location.href),
          secureContext: !!window.isSecureContext,
          metaCSP: metaCSP,
          metaReferrer: referrerMeta ? String(referrerMeta.getAttribute("content") || "") : null,
          forms: forms,
          frames: frames,
          refs: refs
        });
      }

      function sec_schedule() {
        if (sec_timer) { clearTimeout(sec_timer); }
        sec_timer = setTimeout(function () { sec_timer = null; try { sec_collect(); } catch (e) {} }, 400);
      }

      var sec_listening = false;

      inits.push(function () {
        if (document.readyState === "complete") { sec_schedule(); }
        // The listeners cost nothing and are never disposed, so a re-run only collects again.
        if (sec_listening) { return; }
        sec_listening = true;
        window.addEventListener("load", sec_schedule);
        document.addEventListener("DOMContentLoaded", sec_schedule);
      });
      navHooks.push(sec_schedule);

      ops["sec.collect"] = function () { sec_collect(); };
    """##
}
