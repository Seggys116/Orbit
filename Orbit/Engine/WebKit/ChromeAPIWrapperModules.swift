import Foundation

/// Chrome surfaces the wrapper owns outright, spliced into ChromeAPIWrapperScript.source at
/// `marker` so they share its closure: permissions, lifecycle events, webNavigation main-frame
/// events, blocking onAuthRequired, the storage areas WebKit lacks and declarativeNetRequest regexes.
enum ChromeAPIWrapperModules {
    static let marker = "/* ORBIT-WRAPPER-MODULES */"

    static let source = #"""
      var CONSTANTS = {
        idle: { IdleState: { ACTIVE: "active", IDLE: "idle", LOCKED: "locked" } },
        power: { Level: { SYSTEM: "system", DISPLAY: "display" } },
        offscreen: {
          Reason: {
            TESTING: "TESTING", AUDIO_PLAYBACK: "AUDIO_PLAYBACK", IFRAME_SCRIPTING: "IFRAME_SCRIPTING",
            DOM_SCRAPING: "DOM_SCRAPING", BLOBS: "BLOBS", DOM_PARSER: "DOM_PARSER", USER_MEDIA: "USER_MEDIA",
            DISPLAY_MEDIA: "DISPLAY_MEDIA", WEB_RTC: "WEB_RTC", CLIPBOARD: "CLIPBOARD", LOCAL_STORAGE: "LOCAL_STORAGE",
            WORKERS: "WORKERS", BATTERY_STATUS: "BATTERY_STATUS", MATCH_MEDIA: "MATCH_MEDIA", GEOLOCATION: "GEOLOCATION"
          }
        },
        management: {
          ExtensionDisabledReason: { UNKNOWN: "unknown", PERMISSIONS_INCREASE: "permissions_increase" },
          ExtensionInstallType: { ADMIN: "admin", DEVELOPMENT: "development", NORMAL: "normal", SIDELOAD: "sideload", OTHER: "other" },
          ExtensionType: {
            EXTENSION: "extension", HOSTED_APP: "hosted_app", PACKAGED_APP: "packaged_app",
            LEGACY_PACKAGED_APP: "legacy_packaged_app", THEME: "theme", LOGIN_SCREEN_EXTENSION: "login_screen_extension"
          },
          LaunchType: {
            OPEN_AS_REGULAR_TAB: "OPEN_AS_REGULAR_TAB", OPEN_AS_PINNED_TAB: "OPEN_AS_PINNED_TAB",
            OPEN_AS_WINDOW: "OPEN_AS_WINDOW", OPEN_FULL_SCREEN: "OPEN_FULL_SCREEN"
          }
        },
        sessions: { MAX_SESSION_RESULTS: ORBIT_CONFIG.maxSessionResults || 25 },
        "system.storage": {
          EjectDeviceResultCode: { SUCCESS: "success", IN_USE: "in_use", NO_SUCH_DEVICE: "no_such_device", FAILURE: "failure" },
          StorageUnitType: { FIXED: "fixed", REMOVABLE: "removable", UNKNOWN: "unknown" }
        }
      };

      function resolveNamespace(root, path) {
        var value = root;
        var parts = String(path).split(".");
        for (var i = 0; i < parts.length; i++) {
          if (value === null || value === undefined) { return undefined; }
          try { value = value[parts[i]]; } catch (e) { return undefined; }
        }
        return value;
      }

      function hasGrant(name) { return GRANTED.indexOf(name) !== -1; }

      function errorText(error) { return String((error && error.message) || error); }

      // runtime.lastError can only be set by WebKit, so a wrapper-side failure is
      // routed through a native call that fails and the callback runs inside its reply.
      function raiseLastError(message, callback) {
        if (!hasNativeTransport()) { callback(); return; }
        rawInvoke("orbit", "raise", [message], function () { callback(); });
      }

      function settle(promise, callback) {
        if (typeof callback !== "function") { return promise; }
        promise.then(function (value) { callback(value); }, function (error) {
          raiseLastError(errorText(error), callback);
        });
        return undefined;
      }

      function failCall(message, callback) { return settle(Promise.reject(new Error(message)), callback); }

      function callOrbit(namespace, method, args, callback) {
        if (typeof callback === "function") {
          callNativeCallback(namespace, method, args, callback);
          return undefined;
        }
        return callNative(namespace, method, args);
      }

      // WebKit's event attributes are read-only, so a replacement takes over the
      // existing object's methods; listeners then never reach WebKit's own dispatcher.
      function adoptEvent(owner, name, ours) {
        var existing = null;
        try { existing = owner[name]; } catch (e) {}
        if (existing && typeof existing === "object") {
          try {
            existing.addListener = ours.addListener;
            existing.removeListener = ours.removeListener;
            existing.hasListener = ours.hasListener;
            existing.hasListeners = ours.hasListeners;
            existing.__orbitDispatch = ours.__orbitDispatch;
          } catch (e) {}
          if (typeof existing.__orbitDispatch !== "function") {
            try {
              Object.defineProperty(existing, "__orbitDispatch", {
                configurable: true,
                value: function () { return ours.__orbitDispatch.apply(ours, arguments); }
              });
            } catch (e) {}
          }
          if (existing.addListener === ours.addListener || typeof existing.__orbitDispatch === "function") {
            return existing;
          }
        }
        try { owner[name] = ours; } catch (e) {}
        return ours;
      }

      function filteredEvent(matches) {
        var entries = [];
        return {
          addListener: function (listener, filter) {
            if (typeof listener !== "function") { throw new TypeError("listener must be a function"); }
            entries.push({ listener: listener, filter: filter });
          },
          removeListener: function (listener) {
            entries = entries.filter(function (entry) { return entry.listener !== listener; });
          },
          hasListener: function (listener) {
            return entries.some(function (entry) { return entry.listener === listener; });
          },
          hasListeners: function () { return entries.length > 0; },
          __orbitDispatch: function () {
            var args = Array.prototype.slice.call(arguments);
            entries.slice().forEach(function (entry) {
              if (entry.filter && !matches(entry.filter, args[0])) { return; }
              try { entry.listener.apply(null, args); } catch (e) { reportListenerError(e); }
            });
          }
        };
      }

      function reportListenerError(error) {
        setTimeout(function () { throw error; }, 0);
      }

      // MARK: event delivery bookkeeping

      var seenEventIDs = {};
      var seenEventOrder = [];
      function firstDelivery(seq) {
        if (typeof seq !== "number") { return true; }
        if (seenEventIDs[seq]) { return false; }
        seenEventIDs[seq] = true;
        seenEventOrder.push(seq);
        if (seenEventOrder.length > 1024) { delete seenEventIDs[seenEventOrder.shift()]; }
        return true;
      }

      function handleInternalEvent(message) {
        var args = message.args || [];
        if (message.event === "grants") {
          applyGrants(args[0] || []);
          return;
        }
        if (message.event === "authRequired") {
          resolveTabReferences(args[1] || {}).then(function (details) {
            handleAuthRequired(args[0], details);
          });
        }
      }

      function eachRoot(body) {
        var chromeRoot = globalThis.chrome;
        var browserRoot = globalThis.browser;
        if (chromeRoot) { body(chromeRoot); }
        if (browserRoot && browserRoot !== chromeRoot) { body(browserRoot); }
      }

      function applyGrants(granted) {
        var previous = GRANTED;
        GRANTED = granted.slice();
        eachRoot(function (root) {
          Object.keys(NAMESPACES).concat(["privacy"]).forEach(function (namespace) {
            if (previous.indexOf(namespace) !== -1 && GRANTED.indexOf(namespace) === -1) {
              withdrawNamespace(root, namespace);
            }
          });
          install(root);
          fillExtensionSurface(root);
        });
      }

      var orbitEventPort = null;
      function sendPortHello(role) {
        if (!orbitEventPort) { return; }
        try { orbitEventPort.postMessage({ orbitPortHello: true, role: role }); } catch (e) {}
      }

      // MARK: permissions

      var permissionEvents = {};
      function permissionEvent(name) {
        if (!permissionEvents[name]) { permissionEvents[name] = event(); }
        return permissionEvents[name];
      }
      function ensurePermissions(root) {
        var api = root.permissions;
        if (!api) { return; }
        adoptEvent(api, "onAdded", permissionEvent("onAdded"));
        adoptEvent(api, "onRemoved", permissionEvent("onRemoved"));
        if (api.__orbitPermissions) { return; }
        var nativeRequest = typeof api.request === "function" ? api.request.bind(api) : null;
        api.getAll = function (callback) { return callOrbit("permissions", "getAll", [], callback); };
        api.contains = function (details, callback) { return callOrbit("permissions", "contains", [details || {}], callback); };
        api.remove = function (details, callback) { return callOrbit("permissions", "remove", [details || {}], callback); };
        api.request = function (details, callback) {
          var asked = userGesture(nativeRequest).then(function () {
            return invoke("permissions", "request", [details || {}]);
          });
          return settle(asked, callback);
        };
        api.__orbitPermissions = true;
      }

      // WebKit's own request() answers an empty set at once, so calling it here
      // borrows WebKit's real user-gesture check without granting anything.
      function userGesture(nativeRequest) {
        if (!nativeRequest) { return Promise.resolve(); }
        return new Promise(function (resolve, reject) {
          try {
            nativeRequest({ permissions: [], origins: [] }, function () {
              var rt = runtime();
              if (rt && rt.lastError) {
                reject(new Error("This function must be called during a user gesture"));
              } else {
                resolve();
              }
            });
          } catch (error) { reject(error); }
        });
      }

      // MARK: runtime lifecycle

      var runtimeEvents = {};
      function runtimeEvent(name) {
        if (!runtimeEvents[name]) { runtimeEvents[name] = event(); }
        return runtimeEvents[name];
      }

      function ensureLifecycle(root) {
        var api = root.runtime;
        if (!api) { return; }
        adoptEvent(api, "onInstalled", runtimeEvent("onInstalled"));
        adoptEvent(api, "onStartup", runtimeEvent("onStartup"));
        api.__orbitLifecycle = true;
      }

      function isBackgroundContext() {
        if (typeof ServiceWorkerGlobalScope !== "undefined" && globalThis instanceof ServiceWorkerGlobalScope) { return true; }
        if (typeof location === "undefined") { return false; }
        try {
          var manifest = runtime().getManifest();
          var background = manifest && manifest.background;
          if (!background) { return false; }
          if (typeof background.page === "string") {
            return new URL(background.page, location.origin + "/").pathname === location.pathname;
          }
          if (Array.isArray(background.scripts)) {
            return location.pathname === "/_generated_background_page.html";
          }
        } catch (e) {}
        return false;
      }

      var backgroundAnnounced = false;
      function drainLifecycle() {
        invoke("runtime", "takeLifecycleEvents", []).then(function (events) {
          (events || []).forEach(function (entry) {
            var ev = runtimeEvents[entry.event];
            if (ev && typeof ev.__orbitDispatch === "function") { ev.__orbitDispatch.apply(ev, entry.args || []); }
          });
        }, function () {});
      }
      // Runs after the extension's own top-level code, so its listeners exist.
      function scheduleBackgroundReady() {
        if (backgroundAnnounced || !isBackgroundContext()) { return; }
        backgroundAnnounced = true;
        var announce = function () {
          sendPortHello("background");
          drainLifecycle();
        };
        if (typeof document === "undefined" || document.readyState === "complete") {
          setTimeout(announce, 0);
        } else {
          globalThis.addEventListener("load", function () { setTimeout(announce, 0); }, { once: true });
        }
      }

      // MARK: webNavigation

      var NAVIGATION_EVENTS = [
        "onBeforeNavigate", "onCommitted", "onDOMContentLoaded", "onCompleted",
        "onErrorOccurred", "onCreatedNavigationTarget", "onReferenceFragmentUpdated",
        "onTabReplaced", "onHistoryStateUpdated"
      ];

      var navigationEvents = {};
      function ensureNavigation(root) {
        if (!root) { return; }
        var api = root.webNavigation;
        if (!api || api.__orbitNavigation) { return; }
        NAVIGATION_EVENTS.forEach(function (name) {
          var ours = navigationEvents[name];
          if (!ours) {
            ours = filteredEvent(navigationFilterMatches);
            navigationEvents[name] = ours;
            var native = null;
            try { native = api[name]; } catch (e) {}
            if (native && native !== ours && typeof native.addListener === "function") {
              try {
                native.addListener(function (details) {
                  if (details && typeof details.frameId === "number" && details.frameId !== 0) {
                    ours.__orbitDispatch(subframeDetails(name, details));
                  }
                });
              } catch (e) {}
            }
          }
          adoptEvent(api, name, ours);
        });
        api.__orbitNavigation = true;
      }

      function subframeDetails(name, details) {
        var copy = {};
        Object.keys(details).forEach(function (key) { copy[key] = details[key]; });
        if (name === "onCommitted") {
          if (copy.transitionType == null) { copy.transitionType = "auto_subframe"; }
          if (!Array.isArray(copy.transitionQualifiers)) { copy.transitionQualifiers = []; }
        }
        if (name === "onErrorOccurred" && typeof copy.error !== "string") { copy.error = "net::ERR_FAILED"; }
        return copy;
      }

      function navigationFilterMatches(filter, details) {
        var filters = filter && filter.url;
        if (!Array.isArray(filters) || filters.length === 0) { return true; }
        var url;
        try { url = new URL(details && details.url); } catch (e) { return false; }
        return filters.some(function (criteria) { return urlFilterMatches(criteria || {}, url); });
      }

      function urlFilterMatches(criteria, url) {
        var withoutFragment = url.href.split("#")[0];
        var originAndPath = url.origin + url.pathname;
        var host = url.hostname.toLowerCase();
        var query = url.search.replace(/^\?/, "");
        var port = url.port ? Number(url.port) : ({ "http:": 80, "https:": 443, "ws:": 80, "wss:": 443, "ftp:": 21 }[url.protocol] || 0);
        function has(key) { return criteria[key] !== undefined && criteria[key] !== null; }
        if (has("hostContains") && host.indexOf(String(criteria.hostContains).toLowerCase()) === -1) { return false; }
        if (has("hostEquals") && host !== String(criteria.hostEquals).toLowerCase()) { return false; }
        if (has("hostPrefix") && host.indexOf(String(criteria.hostPrefix).toLowerCase()) !== 0) { return false; }
        if (has("hostSuffix") && !endsWith(host, String(criteria.hostSuffix).toLowerCase())) { return false; }
        if (has("pathContains") && url.pathname.indexOf(criteria.pathContains) === -1) { return false; }
        if (has("pathEquals") && url.pathname !== criteria.pathEquals) { return false; }
        if (has("pathPrefix") && url.pathname.indexOf(criteria.pathPrefix) !== 0) { return false; }
        if (has("pathSuffix") && !endsWith(url.pathname, criteria.pathSuffix)) { return false; }
        if (has("queryContains") && query.indexOf(criteria.queryContains) === -1) { return false; }
        if (has("queryEquals") && query !== criteria.queryEquals) { return false; }
        if (has("queryPrefix") && query.indexOf(criteria.queryPrefix) !== 0) { return false; }
        if (has("querySuffix") && !endsWith(query, criteria.querySuffix)) { return false; }
        if (has("urlContains") && withoutFragment.indexOf(criteria.urlContains) === -1) { return false; }
        if (has("urlEquals") && withoutFragment !== criteria.urlEquals) { return false; }
        if (has("urlPrefix") && withoutFragment.indexOf(criteria.urlPrefix) !== 0) { return false; }
        if (has("urlSuffix") && !endsWith(withoutFragment, criteria.urlSuffix)) { return false; }
        if (has("urlMatches")) {
          try { if (!new RegExp(criteria.urlMatches).test(withoutFragment)) { return false; } } catch (e) { return false; }
        }
        if (has("originAndPathMatches")) {
          try { if (!new RegExp(criteria.originAndPathMatches).test(originAndPath)) { return false; } } catch (e) { return false; }
        }
        if (Array.isArray(criteria.schemes) && criteria.schemes.indexOf(url.protocol.replace(/:$/, "")) === -1) { return false; }
        if (Array.isArray(criteria.ports)) {
          var portMatches = criteria.ports.some(function (entry) {
            if (Array.isArray(entry)) { return port >= entry[0] && port <= entry[1]; }
            return port === entry;
          });
          if (!portMatches) { return false; }
        }
        return true;
      }

      function endsWith(text, suffix) {
        return text.length >= suffix.length && text.slice(text.length - suffix.length) === suffix;
      }

      // MARK: webRequest.onAuthRequired

      var authListeners = [];

      function ensureAuthRequired(root) {
        var api = root.webRequest;
        var ev = api && api.onAuthRequired;
        if (!ev || typeof ev.addListener !== "function" || ev.__orbitAuth) { return; }
        var passAdd = ev.addListener.bind(ev);
        var passRemove = typeof ev.removeListener === "function" ? ev.removeListener.bind(ev) : null;
        var passHas = typeof ev.hasListener === "function" ? ev.hasListener.bind(ev) : null;
        ev.addListener = function (listener, filter, extraInfoSpec) {
          var spec = Array.isArray(extraInfoSpec) ? extraInfoSpec : [];
          var blocking = spec.indexOf("asyncBlocking") !== -1 || spec.indexOf("blocking") !== -1;
          if (!blocking) { return passAdd(listener, filter, extraInfoSpec); }
          if (!hasGrant("webRequestAuthProvider")) {
            throw new Error("You do not have permission to use blocking webRequest listeners. Be sure to declare the webRequestAuthProvider permission in your manifest.");
          }
          authListeners.push({ listener: listener, filter: filter || {}, async: spec.indexOf("asyncBlocking") !== -1, spec: spec });
          invoke("webRequest", "registerAuthListener", [filter || {}, spec]).catch(function () {});
        };
        ev.removeListener = function (listener) {
          var before = authListeners.length;
          authListeners = authListeners.filter(function (entry) { return entry.listener !== listener; });
          if (authListeners.length !== before) {
            invoke("webRequest", "unregisterAuthListener", [authListeners.length]).catch(function () {});
            return;
          }
          if (passRemove) { passRemove(listener); }
        };
        ev.hasListener = function (listener) {
          if (authListeners.some(function (entry) { return entry.listener === listener; })) { return true; }
          return passHas ? passHas(listener) : false;
        };
        ev.__orbitAuth = true;
      }

      function handleAuthRequired(token, details) {
        var candidates = authListeners.filter(function (entry) { return requestFilterMatches(entry.filter, details); });
        var index = 0;
        function respond(response) {
          invoke("webRequest", "authResponse", [token, response || {}]).catch(function () {});
        }
        function next() {
          if (index >= candidates.length) { respond({}); return; }
          var entry = candidates[index];
          index += 1;
          var answered = false;
          function answer(response) {
            if (answered) { return; }
            answered = true;
            if (response && (response.authCredentials || response.cancel)) { respond(response); } else { next(); }
          }
          // Response headers only for a listener that asked for them, as Chrome does.
          var payload = details;
          if (entry.spec.indexOf("responseHeaders") === -1 && details && details.responseHeaders !== undefined) {
            payload = shallowCopy(details);
            delete payload.responseHeaders;
          }
          try {
            var value = entry.listener(payload, entry.async ? answer : undefined);
            if (!entry.async) { answer(value); }
          } catch (error) {
            reportListenerError(error);
            answer({});
          }
        }
        next();
      }

      function requestFilterMatches(filter, details) {
        if (!filter) { return true; }
        if (Array.isArray(filter.urls) && filter.urls.length && !filter.urls.some(function (pattern) {
          return matchPatternMatches(pattern, details.url);
        })) { return false; }
        if (Array.isArray(filter.types) && filter.types.length && filter.types.indexOf(details.type) === -1) { return false; }
        if (typeof filter.tabId === "number" && filter.tabId !== details.tabId) { return false; }
        if (typeof filter.windowId === "number" && filter.windowId !== details.windowId) { return false; }
        return true;
      }

      function matchPatternMatches(pattern, href) {
        var url;
        try { url = new URL(href); } catch (e) { return false; }
        var scheme = url.protocol.replace(/:$/, "");
        if (pattern === "<all_urls>") {
          return ["http", "https", "ws", "wss", "ftp", "file", "data"].indexOf(scheme) !== -1;
        }
        var parts = /^(\*|[a-zA-Z][a-zA-Z0-9+.\-]*):\/\/([^\/]*)(\/.*)?$/.exec(String(pattern));
        if (!parts) { return false; }
        if (parts[1] === "*") {
          if (["http", "https", "ws", "wss"].indexOf(scheme) === -1) { return false; }
        } else if (parts[1].toLowerCase() !== scheme) { return false; }
        var host = parts[2].replace(/:(\d+|\*)$/, "").toLowerCase();
        var hostname = url.hostname.toLowerCase();
        if (host !== "*" && host !== "") {
          if (host.indexOf("*.") === 0) {
            var base = host.slice(2);
            if (hostname !== base && !endsWith(hostname, "." + base)) { return false; }
          } else if (hostname !== host) { return false; }
        }
        var glob = parts[3] || "/*";
        var expression = new RegExp("^" + glob.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*") + "$");
        return expression.test(url.pathname + url.search);
      }

      // MARK: storage areas

      var SYNC_QUOTA = {
        QUOTA_BYTES: 102400, QUOTA_BYTES_PER_ITEM: 8192, MAX_ITEMS: 512,
        MAX_WRITE_OPERATIONS_PER_HOUR: 1800, MAX_WRITE_OPERATIONS_PER_MINUTE: 120
      };

      function utf8Length(text) {
        if (typeof TextEncoder === "function") { return new TextEncoder().encode(text).length; }
        return unescape(encodeURIComponent(text)).length;
      }

      // Chrome sizes an item as its key plus its JSON serialisation.
      function oversizedItem(items, limit) {
        if (!items || typeof items !== "object") { return null; }
        var keys = Object.keys(items);
        for (var i = 0; i < keys.length; i++) {
          var value = items[keys[i]];
          if (value === undefined) { continue; }
          var serialized;
          try { serialized = JSON.stringify(value); } catch (e) { return null; }
          if (serialized === undefined) { continue; }
          if (utf8Length(keys[i]) + utf8Length(serialized) > limit) { return keys[i]; }
        }
        return null;
      }

      // WebKit can invoke a storage callback while it still holds the area lock.
      // A listener that writes from that callback then deadlocks the next read.
      function deferStorageCallbacks(area) {
        if (!area || area.__orbitDeferred) { return; }
        ["get", "set", "remove", "clear"].forEach(function (name) {
          if (typeof area[name] !== "function" || area[name].__orbitDeferred) { return; }
          var original = area[name].bind(area);
          var wrapped = function () {
            var args = Array.prototype.slice.call(arguments);
            var callback = typeof args[args.length - 1] === "function" ? args.pop() : null;
            if (!callback) { return original.apply(null, args); }
            var settled = false;
            var timer = setTimeout(function () {
              if (settled) { return; }
              settled = true;
              callback(name === "get" ? {} : undefined);
            }, 1000);
            return original.apply(null, args.concat([function (value) {
              if (settled) { return; }
              settled = true;
              clearTimeout(timer);
              queueMicrotask(function () { callback(value); });
            }]));
          };
          wrapped.__orbitDeferred = true;
          area[name] = wrapped;
        });
        area.__orbitDeferred = true;
      }
      function ensureStorage(root) {
        var storage = root.storage;
        if (!storage) { return; }
        deferStorageCallbacks(storage.local);
        deferStorageCallbacks(storage.sync);
        var sync = storage.sync;
        if (sync && !sync.__orbitQuota && typeof sync.set === "function") {
          Object.keys(SYNC_QUOTA).forEach(function (name) {
            if (sync[name] === undefined || sync[name] === null) {
              try { sync[name] = SYNC_QUOTA[name]; } catch (e) {}
            }
          });
          var originalSet = sync.set.bind(sync);
          sync.set = function (items, callback) {
            var limit = sync.QUOTA_BYTES_PER_ITEM || SYNC_QUOTA.QUOTA_BYTES_PER_ITEM;
            if (oversizedItem(items, limit) !== null) { return failCall("QUOTA_BYTES_PER_ITEM quota exceeded", callback); }
            try {
              return typeof callback === "function" ? originalSet(items, callback) : originalSet(items);
            } catch (error) {
              return failCall(errorText(error), callback);
            }
          };
          sync.__orbitQuota = true;
        }
        if (!storage.managed) {
          try { storage.managed = managedArea(); } catch (e) {}
        }
      }

      // Orbit has no policy source, so the managed area is Chrome's unmanaged-profile answer: empty and read-only.
      function managedArea() {
        var readOnly = "This is a read-only store.";
        function trailing(args) {
          var last = args[args.length - 1];
          return typeof last === "function" ? last : null;
        }
        return {
          get: function () { return settle(Promise.resolve({}), trailing(arguments)); },
          getBytesInUse: function () { return settle(Promise.resolve(0), trailing(arguments)); },
          getKeys: function () { return settle(Promise.resolve([]), trailing(arguments)); },
          set: function () { return failCall(readOnly, trailing(arguments)); },
          remove: function () { return failCall(readOnly, trailing(arguments)); },
          clear: function () { return failCall(readOnly, trailing(arguments)); },
          onChanged: event()
        };
      }

      // MARK: declarativeNetRequest

      function shallowCopy(value) {
        var copy = {};
        Object.keys(value || {}).forEach(function (key) { copy[key] = value[key]; });
        return copy;
      }

      function compileRuleRegex(rule) {
        var condition = rule && rule.condition;
        var filter = condition && condition.regexFilter;
        if (typeof filter !== "string") { return { rule: rule }; }
        var keepsCaptures = !!(rule.action && rule.action.redirect && rule.action.redirect.regexSubstitution);
        var compiled = compileRegex(filter, keepsCaptures);
        if (compiled.error) {
          return { rule: rule, error: "Rule with id " + rule.id + " specified an unsupported regexFilter: " + compiled.error + "." };
        }
        if (compiled.source === filter) { return { rule: rule }; }
        var copy = shallowCopy(rule);
        copy.condition = shallowCopy(condition);
        copy.condition.regexFilter = compiled.source;
        return { rule: copy, original: filter };
      }

      // Rewrites RE2 syntax WebKit's content blockers lack into the subset they accept, keeping the same
      // language; anything that cannot be rewritten (general alternation, lookaround) is reported, not dropped.
      function compileRegex(source, keepsCaptures) {
        var index = 0;
        function fail(reason) { throw new Error(reason); }
        function parseAlternation(depth) {
          var branches = [[]];
          while (index < source.length) {
            var ch = source[index];
            if (ch === ")") {
              if (depth === 0) { fail("unbalanced parenthesis"); }
              break;
            }
            if (ch === "|") {
              index += 1;
              branches.push([]);
              continue;
            }
            var atom = parseAtom(depth);
            branches[branches.length - 1].push({ atom: atom, quant: parseQuantifier(atom) });
          }
          return branches;
        }
        function parseAtom(depth) {
          var ch = source[index];
          if (ch === "(") {
            index += 1;
            var capturing = true;
            if (source[index] === "?") {
              if (source[index + 1] !== ":") { fail("lookaround and named groups are not supported"); }
              capturing = false;
              index += 2;
            }
            var branches = parseAlternation(depth + 1);
            if (source[index] !== ")") { fail("unbalanced parenthesis"); }
            index += 1;
            return { kind: "group", branches: branches, capturing: capturing };
          }
          if (ch === "[") {
            var end = index + 1;
            if (source[end] === "^") { end += 1; }
            if (source[end] === "]") { end += 1; }
            while (end < source.length && source[end] !== "]") {
              if (source[end] === "\\") { end += 1; }
              end += 1;
            }
            if (end >= source.length) { fail("unterminated character class"); }
            var body = source.slice(index + 1, end);
            index = end + 1;
            return { kind: "class", text: "[" + expandClassEscapes(body) + "]", negated: body.charAt(0) === "^", body: expandClassEscapes(body) };
          }
          if (ch === "\\") {
            var next = source[index + 1];
            if (next === undefined) { fail("trailing backslash"); }
            index += 2;
            var shorthand = {
              d: "0-9", w: "A-Za-z0-9_", s: " \\t\\n\\r\\f\\v"
            }[next];
            if (shorthand) { return { kind: "class", text: "[" + shorthand + "]", negated: false, body: shorthand }; }
            var negatedShorthand = { D: "0-9", W: "A-Za-z0-9_", S: " \\t\\n\\r\\f\\v" }[next];
            if (negatedShorthand) { return { kind: "class", text: "[^" + negatedShorthand + "]", negated: true, body: "^" + negatedShorthand }; }
            if (/[0-9bBAzZ]/.test(next)) { fail("backreferences, word boundaries and \\A/\\z anchors are not supported"); }
            return { kind: "char", text: "\\" + next, literal: next };
          }
          if (ch === "^" || ch === "$") {
            index += 1;
            return { kind: "anchor", text: ch };
          }
          if (ch === ".") {
            index += 1;
            return { kind: "any", text: "." };
          }
          if (ch === "*" || ch === "+" || ch === "?") { fail("nothing to repeat"); }
          index += 1;
          if (ch === "{" || ch === "}") { return { kind: "char", text: "\\" + ch, literal: ch }; }
          return { kind: "char", text: ch, literal: ch };
        }
        function parseQuantifier(atom) {
          var ch = source[index];
          var quant = null;
          if (ch === "*" || ch === "+" || ch === "?") {
            quant = { text: ch };
            index += 1;
          } else if (ch === "{") {
            var bounds = /^\{(\d+)(,(\d*))?\}/.exec(source.slice(index));
            if (!bounds) { return null; }
            index += bounds[0].length;
            var min = Number(bounds[1]);
            var max = bounds[2] ? (bounds[3] === "" ? Infinity : Number(bounds[3])) : min;
            if (max < min) { fail("invalid repetition bounds"); }
            if (max !== Infinity && max > 64) { fail("repetition bound is too large"); }
            quant = { min: min, max: max };
            if (atom.kind === "group" && atom.capturing && keepsCaptures) { fail("repeating a capturing group would renumber regexSubstitution groups"); }
          }
          if (quant && source[index] === "?") {
            if (keepsCaptures) { fail("lazy quantifiers change regexSubstitution captures"); }
            index += 1;
          }
          if (quant && source[index] === "+") { fail("possessive quantifiers are not supported"); }
          if (quant && atom.kind === "anchor") { fail("an anchor cannot be repeated"); }
          return quant;
        }
        function expandClassEscapes(body) {
          return body.replace(/\\d/g, "0-9").replace(/\\w/g, "A-Za-z0-9_").replace(/\\s/g, " \\t\\n\\r\\f\\v");
        }
        function classMember(atom) {
          if (atom.kind === "char") {
            return /[\\\]\^\-]/.test(atom.literal) ? "\\" + atom.literal : atom.literal;
          }
          if (atom.kind === "class" && !atom.negated) { return atom.body; }
          return null;
        }
        function singleCharacterSet(branches) {
          var members = "";
          for (var i = 0; i < branches.length; i++) {
            var branch = branches[i];
            if (branch.length !== 1 || branch[0].quant) { return null; }
            var member = classMember(branch[0].atom);
            if (member === null) { return null; }
            members += member;
          }
          return members;
        }
        // "(?:\?.*|#.*|$)" and its kin: each branch one character then ".*", or the end of input.
        function tailSet(group) {
          if (group.kind !== "group" || group.branches.length < 2) { return null; }
          var members = "";
          var allowsEnd = false;
          for (var i = 0; i < group.branches.length; i++) {
            var branch = group.branches[i];
            if (branch.length === 1 && branch[0].atom.kind === "anchor" && branch[0].atom.text === "$" && !branch[0].quant) {
              allowsEnd = true;
              continue;
            }
            if (branch.length !== 2 || branch[0].quant || branch[1].atom.kind !== "any" || !branch[1].quant || branch[1].quant.text !== "*") { return null; }
            var member = classMember(branch[0].atom);
            if (member === null) { return null; }
            members += member;
          }
          if (!members) { return null; }
          return allowsEnd ? "([" + members + "].*)?$" : "[" + members + "].*";
        }
        function repeat(text, quant) {
          if (!quant) { return text; }
          if (quant.text) { return text + quant.text; }
          var out = "";
          for (var i = 0; i < quant.min; i++) { out += text; }
          if (quant.max === Infinity) { return out + text + "*"; }
          for (var j = quant.min; j < quant.max; j++) { out += text + "?"; }
          return out;
        }
        function emitAtom(atom, quant) {
          if (atom.kind !== "group") { return atom.text; }
          if (atom.branches.length === 1) {
            var inner = emitSequence(atom.branches[0], false);
            if (!atom.capturing && !quant) { return inner; }
            if (!atom.capturing && keepsCaptures) { fail("a repeated non-capturing group would renumber regexSubstitution groups"); }
            return "(" + inner + ")";
          }
          var members = singleCharacterSet(atom.branches);
          if (members !== null) {
            if (atom.capturing && keepsCaptures) { fail("alternation inside a capturing group used by regexSubstitution is not supported"); }
            return "[" + members + "]";
          }
          fail("alternation is not supported by WebKit content blockers");
        }
        function emitSequence(items, isTail) {
          var out = "";
          for (var i = 0; i < items.length; i++) {
            var item = items[i];
            if (isTail && i === items.length - 1 && !item.quant && !(item.atom.capturing && keepsCaptures)) {
              var tail = tailSet(item.atom);
              if (tail !== null) {
                out += tail;
                continue;
              }
            }
            out += repeat(emitAtom(item.atom, item.quant), item.quant);
          }
          return out;
        }
        try {
          var branches = parseAlternation(0);
          if (index < source.length) { fail("unbalanced parenthesis"); }
          if (branches.length > 1) {
            var members = singleCharacterSet(branches);
            if (members === null) { fail("alternation is not supported by WebKit content blockers"); }
            return { source: "[" + members + "]" };
          }
          return { source: emitSequence(branches[0], true) };
        } catch (error) {
          return { error: errorText(error) };
        }
      }

      function tolerateDeclarativeNetRequest(root) {
        var api = root && root.declarativeNetRequest;
        if (!api) { return; }
        [["updateDynamicRules", "dynamic"], ["updateSessionRules", "session"]].forEach(function (pair) {
          var name = pair[0];
          if (typeof api[name] !== "function" || api[name].__orbitWrapped) { return; }
          var original = api[name].bind(api);
          var wrapped = function (options, callback) {
            var next = options;
            var remembered = {};
            if (options && Array.isArray(options.addRules)) {
              var failure = null;
              var rules = options.addRules.map(function (rule) {
                var compiled = compileRuleRegex(rule);
                if (compiled.error && failure === null) { failure = compiled.error; }
                if (compiled.original !== undefined) { remembered[String(rule.id)] = compiled.original; }
                return compiled.rule;
              });
              if (failure !== null) { return failCall(failure, callback); }
              next = shallowCopy(options);
              next.addRules = rules;
            }
            var removed = options && Array.isArray(options.removeRuleIds) ? options.removeRuleIds : [];
            var added = options && Array.isArray(options.addRules) ? options.addRules.map(function (rule) { return rule && rule.id; }) : [];
            function record() {
              return invoke("declarativeNetRequest", "rememberRegexFilters", [pair[1], remembered, removed.concat(added)])
                .catch(function () {});
            }
            try {
              if (typeof callback === "function") {
                return original(next, function () {
                  var rt = runtime();
                  if (rt && rt.lastError) { callback(); return; }
                  record().then(function () { callback(); });
                });
              }
              return Promise.resolve(original(next)).then(function (value) {
                return record().then(function () { return value; });
              });
            } catch (error) {
              return failCall(errorText(error), callback);
            }
          };
          wrapped.__orbitWrapped = true;
          api[name] = wrapped;
        });
        [["getDynamicRules", "dynamic"], ["getSessionRules", "session"]].forEach(function (pair) {
          var name = pair[0];
          if (typeof api[name] !== "function" || api[name].__orbitWrapped) { return; }
          var original = api[name].bind(api);
          var wrapped = function (filter, callback) {
            if (typeof filter === "function") {
              callback = filter;
              filter = undefined;
            }
            var fetched = new Promise(function (resolve, reject) {
              try {
                var args = filter === undefined ? [] : [filter];
                original.apply(null, args.concat([function (rules) {
                  var rt = runtime();
                  if (rt && rt.lastError) { reject(new Error(rt.lastError.message)); } else { resolve(rules || []); }
                }]));
              } catch (error) { reject(error); }
            }).then(function (rules) {
              return invoke("declarativeNetRequest", "regexFilters", [pair[1]]).then(function (originals) {
                return rules.map(function (rule) {
                  var original = originals && originals[String(rule.id)];
                  if (original === undefined || !rule.condition) { return rule; }
                  var copy = shallowCopy(rule);
                  copy.condition = shallowCopy(rule.condition);
                  copy.condition.regexFilter = original;
                  return copy;
                });
              }, function () { return rules; });
            });
            return settle(fetched, callback);
          };
          wrapped.__orbitWrapped = true;
          api[name] = wrapped;
        });
      }
    """#
}
