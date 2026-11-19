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

        var scripts = [];
        try {
          Array.prototype.forEach.call(document.querySelectorAll("script[src],link[rel~='stylesheet'][href]"), function (el) {
            if (scripts.length >= 200 || isOurs(el)) { return; }
            var url = String(el.src || el.href || "");
            if (!/^https?:/i.test(url)) { return; }
            var cross = false;
            try { cross = new URL(url, location.href).origin !== location.origin; } catch (e) {}
            if (!cross) { return; }
            scripts.push({
              url: url.slice(0, 400), tag: el.tagName.toLowerCase(), sri: !!el.getAttribute("integrity"),
              id: idOf(el), sel: nodeLabel(el)
            });
          });
        } catch (e) {}

        var links = [];
        try {
          Array.prototype.forEach.call(document.querySelectorAll("a[target='_blank'],area[target='_blank']"), function (el) {
            if (links.length >= 200 || isOurs(el)) { return; }
            var href = String(el.href || "");
            var cross = false;
            try {
              var parsed = new URL(href, location.href);
              cross = /^https?:$/.test(parsed.protocol) && parsed.origin !== location.origin;
            } catch (e) {}
            if (!cross) { return; }
            links.push({
              href: href.slice(0, 400), rel: String(el.getAttribute("rel") || "").slice(0, 200),
              id: idOf(el), sel: nodeLabel(el)
            });
          });
        } catch (e) {}

        var libs = [];
        function sec_lib(name, evidence, read) {
          try {
            var version = read();
            if (typeof version === "string" && version) { libs.push({ name: name, version: version.slice(0, 40), ev: evidence }); }
          } catch (e) {}
        }
        sec_lib("jQuery", "window.jQuery.fn.jquery", function () { return window.jQuery && window.jQuery.fn && window.jQuery.fn.jquery; });
        sec_lib("Bootstrap", "window.bootstrap.Tooltip.VERSION", function () { return window.bootstrap && window.bootstrap.Tooltip && window.bootstrap.Tooltip.VERSION; });
        if (!libs.some(function (l) { return l.name === "Bootstrap"; })) {
          sec_lib("Bootstrap", "jQuery.fn.tooltip.Constructor.VERSION", function () {
            return window.jQuery && window.jQuery.fn.tooltip && window.jQuery.fn.tooltip.Constructor && window.jQuery.fn.tooltip.Constructor.VERSION;
          });
        }
        sec_lib("Lodash", "window._.VERSION", function () { return window._ && window._.templateSettings && window._.VERSION; });
        sec_lib("Moment.js", "window.moment.version", function () { return window.moment && window.moment.version; });
        sec_lib("AngularJS", "window.angular.version.full", function () { return window.angular && window.angular.version && window.angular.version.full; });

        post({
          t: "sec.page",
          scripts: scripts,
          links: links,
          libs: libs,
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
