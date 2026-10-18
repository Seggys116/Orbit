import Foundation

/// Script prepended to every loaded extension. It fills chrome.* namespaces
/// WebKit does not implement and forwards them to Orbit through runtime.sendNativeMessage
/// to a reserved application id, which never reaches a real native messaging host.
enum ChromeAPIWrapperScript {
    static let fileName = "orbit-chrome-wrapper.js"
    static let backgroundEntryName = "orbit-background-entry.js"

    static let source = template
        .replacingOccurrences(of: "var NAMESPACES = {};", with: ChromeAPISurfaceInventory.namespacesDeclaration)
        .replacingOccurrences(of: "var UNGATED = {};", with: ChromeAPISurfaceInventory.ungatedDeclaration)
        .replacingOccurrences(of: "var EVENTS = {};", with: ChromeAPISurfaceInventory.eventsDeclaration)

    private static let template = #"""
    (function () {
      try {
      if (globalThis.__orbitChromeWrapperInstalled) { return; }
      globalThis.__orbitChromeWrapperInstalled = true;
      var APP_ID = "com.orbit.chrome";
      var ORBIT_CONFIG = {};
      var NAMESPACES = {};
      var UNGATED = {};

      function runtime() {
        var root = globalThis.browser || globalThis.chrome;
        return root && root.runtime;
      }

      // Captured before the extension's own code runs. WebKit binds these dynamically from the
      // context's grant, so they stay visible; Orbit refuses every real host to an extension that
      // did not declare nativeMessaging.
      var nativeSend = null;
      var nativeConnect = null;
      function captureNativeTransport() {
        var rt = runtime();
        if (!rt) { return; }
        try {
          if (!nativeSend && typeof rt.sendNativeMessage === "function") { nativeSend = rt.sendNativeMessage.bind(rt); }
          if (!nativeConnect && typeof rt.connectNative === "function") { nativeConnect = rt.connectNative.bind(rt); }
        } catch (e) {}
      }
      captureNativeTransport();

      // WebKit fires port.onDisconnect with no runtime.lastError. A host exit is delivered as one
      // private message first; the disconnect listener then runs inside a failed native call.
      function installPortDisconnectError() {
        var rt = runtime();
        var sample = rt && (rt.onConnect || rt.onMessage || rt.onInstalled);
        if (!sample || !sample.addListener) { return; }
        var proto = Object.getPrototypeOf(sample);
        if (!proto || !proto.addListener || proto.addListener.__orbitWrapped) { return; }
        var orig = proto.addListener;
        function wrappedAdd(listener) {
          var wrapped = function (first) {
            if (first && typeof first === "object" && typeof first.__orbitDisconnectError === "string") {
              globalThis.__orbitNativeDisconnectError = first.__orbitDisconnectError;
              return;
            }
            var pending = globalThis.__orbitNativeDisconnectError;
            if (pending && arguments.length === 1) {
              globalThis.__orbitNativeDisconnectError = null;
              var self = this;
              var args = arguments;
              raiseLastError(pending, function () { listener.apply(self, args); });
              return;
            }
            return listener.apply(this, arguments);
          };
          return orig.call(this, wrapped);
        }
        wrappedAdd.__orbitWrapped = true;
        proto.addListener = wrappedAdd;
      }

      function hasNativeTransport() {
        captureNativeTransport();
        return nativeSend !== null;
      }

      // WebKit prefixes a failed native call and adds a period. Orbit's own text does not come through here.
      function cleanNativeError(message) {
        var raw = String(message);
        var prefixed = /^Invalid call to runtime\.sendNativeMessage\(\)\.\s*/;
        if (!prefixed.test(raw)) { return raw; }
        var text = raw.replace(prefixed, "");
        if (text.length > 1 && text.charAt(text.length - 1) === ".") { text = text.slice(0, -1); }
        return text;
      }

      // `done(error, value, live)`: `live` means WebKit's own runtime.lastError is set right now.
      function rawInvoke(namespace, method, args, done) {
        var message = { orbitChromeAPI: true, namespace: namespace, method: method, args: args };
        if (hasNativeTransport()) {
          try {
            nativeSend(APP_ID, message, function (value) {
              var rt = runtime();
              if (value && value.__orbitError) { done(String(value.__orbitError), undefined, false); return; }
              var err = rt && rt.lastError;
              if (err) { done(cleanNativeError(String(err.message || err)), undefined, true); return; }
              done(null, value, false);
            });
          } catch (e) { done(String((e && e.message) || e), undefined, false); }
          return;
        }
        var rt = runtime();
        if (rt && typeof rt.sendMessage === "function") {
          rt.sendMessage({ orbitChromeWrapper: true, namespace: namespace, method: method, args: args }, function (reply) {
            if (reply && reply.__orbitError) { done(String(reply.__orbitError), undefined, false); return; }
            var err = rt.lastError;
            if (err) { done(cleanNativeError(String(err.message || err)), undefined, true); return; }
            done(null, reply, false);
          });
          return;
        }
        done("Orbit chrome wrapper has no runtime port", undefined, false);
      }

      function invoke(namespace, method, args) {
        return new Promise(function (resolve, reject) {
          var settled = false;
          // orbitTabs is a local lookup. A reply that never comes must not freeze later events.
          var timer = namespace === "orbitTabs" ? setTimeout(function () {
            if (settled) { return; }
            settled = true;
            reject(new Error("chrome." + namespace + "." + method + " did not answer"));
          }, 1000) : null;
          rawInvoke(namespace, method, args, function (error, value) {
            if (settled) { return; }
            settled = true;
            if (timer) { clearTimeout(timer); }
            if (error !== null) { reject(new Error(cleanNativeError(error))); return; }
            resolve(value);
          });
        });
      }

      // Orbit's native side names tabs by its own numbers; extensions only ever see
      // the ids WebKit assigned in this context, resolved here through browser.tabs.
      var TAB_RESOLVE_ATTEMPTS = 5;
      var tabIDByNumber = {};
      var tabNumberByID = {};
      // Orbit's window numbers against WebKit's windowIds, learned from tabs resolved so far.
      var windowIDByNumber = {};
      var windowNumberByID = {};
      var lastTabGeneration = -1;

      function tabsAPI() {
        var root = globalThis.browser || globalThis.chrome;
        var api = root && root.tabs;
        return api && typeof api.get === "function" && typeof api.query === "function" ? api : null;
      }

      function callTabs(method, args) {
        var api = tabsAPI();
        if (!api) { return Promise.reject(new Error("chrome.tabs is unavailable here")); }
        var fn = api[method];
        if (fn && fn.__orbitNative) { fn = fn.__orbitNative; }
        var promise;
        try {
          var result = fn.apply(api, args);
          if (result && typeof result.then === "function") {
            promise = Promise.resolve(result);
          }
        } catch (e) { return Promise.reject(e); }
        if (!promise) {
          // Only read-only calls come through here, so repeating one in callback form is safe.
          promise = new Promise(function (resolve, reject) {
            try {
              fn.apply(api, args.concat([function (value) {
                var rt = runtime();
                var err = rt && rt.lastError;
                if (err) { reject(new Error(err.message || String(err))); } else { resolve(value); }
              }]));
            } catch (e) { reject(e); }
          });
        }
        // An unanswered tabs call must not stall every later event. webNavigation still delivers, with tabId -1.
        return new Promise(function (resolve, reject) {
          var settled = false;
          var timer = setTimeout(function () {
            if (settled) { return; }
            settled = true;
            reject(new Error("chrome.tabs." + method + " did not answer"));
          }, 400);
          promise.then(function (value) {
            if (settled) { return; }
            settled = true;
            clearTimeout(timer);
            resolve(value);
          }, function (error) {
            if (settled) { return; }
            settled = true;
            clearTimeout(timer);
            reject(error);
          });
        });
      }

      function rememberTab(number, tabID) {
        if (typeof number !== "number" || typeof tabID !== "number" || tabID < 0) { return; }
        tabIDByNumber[number] = tabID;
        tabNumberByID[tabID] = number;
      }

      function rememberWindow(number, windowID) {
        if (typeof number !== "number" || typeof windowID !== "number" || windowID < 0) { return; }
        windowIDByNumber[number] = windowID;
        windowNumberByID[windowID] = number;
      }

      // Extensions pass Orbit's number. WebKit's own tabs and scripting methods take WebKit's id.
      function nativeTabID(shownID) {
        if (typeof shownID !== "number") { return shownID; }
        if (tabIDByNumber[shownID] != null) { return tabIDByNumber[shownID]; }
        if (tabNumberByID[shownID] != null) { return shownID; }
        return shownID;
      }

      function installNativeTabTargets(root) {
        if (!root) { return; }
        var tabs = root.tabs;
        if (tabs) {
          ["sendMessage", "connect", "update", "remove", "move", "duplicate", "discard", "goBack", "goForward"].forEach(function (method) {
            var original = tabs[method];
            if (typeof original !== "function" || original.__orbitTabID) { return; }
            var native = original.bind(tabs);
            var wrapped = function () {
              var args = Array.prototype.slice.call(arguments);
              var id = args[0];
              if (typeof id === "number") { args[0] = nativeTabID(id); }
              else if (Array.isArray(id)) {
                args[0] = id.map(function (item) { return typeof item === "number" ? nativeTabID(item) : item; });
              }
              return native.apply(null, args);
            };
            wrapped.__orbitTabID = true;
            wrapped.__orbitNative = native;
            tabs[method] = wrapped;
          });
        }
        var scripting = root.scripting;
        if (!scripting) { return; }
        ["executeScript", "insertCSS", "removeCSS"].forEach(function (method) {
          var original = scripting[method];
          if (typeof original !== "function" || original.__orbitTabID) { return; }
          var native = original.bind(scripting);
          var wrapped = function () {
            var args = Array.prototype.slice.call(arguments);
            var details = args[0];
            if (details && typeof details === "object" && details.target && typeof details.target.tabId === "number") {
              var injection = {};
              Object.keys(details).forEach(function (key) { injection[key] = details[key]; });
              var target = {};
              Object.keys(details.target).forEach(function (key) { target[key] = details.target[key]; });
              target.tabId = nativeTabID(details.target.tabId);
              injection.target = target;
              args[0] = injection;
            }
            return native.apply(null, args);
          };
          wrapped.__orbitTabID = true;
          wrapped.__orbitNative = native;
          scripting[method] = wrapped;
        });
      }

      function noteTabGeneration(reply) {
        if (reply && typeof reply.generation === "number") { lastTabGeneration = reply.generation; }
      }

      function urlAgrees(tab, reference) {
        if (!reference || !reference.url || !tab || !tab.url) { return true; }
        return tab.url === reference.url || tab.pendingUrl === reference.url;
      }

      function pickTab(tabs, reference) {
        var windowID = windowIDByNumber[reference.window];
        var hits = (tabs || []).filter(function (tab) {
          return tab && tab.index === reference.index && (windowID == null || tab.windowId === windowID);
        });
        if (hits.length > 1) { hits = hits.filter(function (tab) { return urlAgrees(tab, reference); }); }
        if (hits.length !== 1 || !urlAgrees(hits[0], reference)) { return null; }
        return hits[0];
      }

      // The index read from tabs.query only counts when Orbit's tab layout did not
      // change between taking the reference and answering locate after the query.
      function locateTab(reference, attempt) {
        return callTabs("query", [{}]).then(function (tabs) {
          return invoke("orbitTabs", "locate", [reference.number]).then(function (reply) {
            noteTabGeneration(reply);
            var current = reply && reply.reference;
            if (!current) { return null; }
            if (current.generation === reference.generation) {
              var tab = pickTab(tabs, current);
              if (tab) {
                rememberTab(current.number, tab.id);
                rememberWindow(current.window, tab.windowId);
                return tab;
              }
            }
            if (attempt + 1 >= TAB_RESOLVE_ATTEMPTS) {
              var byURL = (tabs || []).filter(function (tab) { return tab && current.url && tab.url === current.url; });
              return byURL.length === 1 ? byURL[0] : null;
            }
            return locateTab(current, attempt + 1);
          });
        });
      }

      function resolveTab(reference) {
        if (!reference || typeof reference.number !== "number") { return Promise.resolve(null); }
        var known = tabIDByNumber[reference.number];
        var lookup = known != null
          ? callTabs("get", [known]).then(function (tab) { return tab || locateTab(reference, 0); }, function () {
              delete tabIDByNumber[reference.number];
              return locateTab(reference, 0);
            })
          : locateTab(reference, 0);
        return lookup.then(function (tab) {
          if (!tab || typeof tab.id !== "number") { return tab; }
          var orbit = tabNumberByID[tab.id];
          if (typeof orbit !== "number") { return tab; }
          var copy = {};
          Object.keys(tab).forEach(function (key) { copy[key] = tab[key]; });
          copy.id = orbit;
          return copy;
        }).catch(function () { return null; });
      }

      function resolveTabID(reference) {
        if (reference && typeof reference.number === "number") { return Promise.resolve(reference.number); }
        return Promise.resolve(-1);
      }

      function hasTabReference(value) {
        if (!value || typeof value !== "object") { return false; }
        if (value.__orbitTabID || value.__orbitTab) { return true; }
        return Object.keys(value).some(function (key) { return hasTabReference(value[key]); });
      }

      // Never rejects: an unresolvable tab becomes -1, chrome.tabs.TAB_ID_NONE.
      function resolveTabReferences(value) {
        if (!hasTabReference(value)) { return Promise.resolve(value); }
        if (value.__orbitTabID) { return resolveTabID(value.__orbitTabID); }
        if (value.__orbitTab) {
          return resolveTab(value.__orbitTab).then(function (tab) {
            var merged = {};
            if (tab) { Object.keys(tab).forEach(function (key) { merged[key] = tab[key]; }); }
            Object.keys(value).forEach(function (key) {
              if (key === "__orbitTab") { return; }
              if (merged[key] === undefined || merged[key] === "") { merged[key] = value[key]; }
            });
            return merged;
          });
        }
        var keys = Object.keys(value);
        var isArray = Array.isArray(value);
        return Promise.all(keys.map(function (key) { return resolveTabReferences(value[key]); })).then(function (resolved) {
          var copy = isArray ? [] : {};
          keys.forEach(function (key, index) { copy[key] = resolved[index]; });
          return copy;
        });
      }

      // lastTabGeneration was read before tabs.get, so an unchanged generation at
      // numberAt proves the index WebKit reported still names the same Orbit tab.
      function numberForURL(url, webKitId) {
        var missing = new Error("No tab with id: " + webKitId + ".");
        if (!url) { return Promise.reject(missing); }
        var lookup = invoke("orbitTabs", "numberForURL", [url]);
        var expired = new Promise(function (_, reject) {
          setTimeout(function () { reject(missing); }, 400);
        });
        return Promise.race([lookup, expired]).then(function (reply) {
          if (!reply || typeof reply.number !== "number") { throw missing; }
          rememberTab(reply.number, webKitId);
          return reply.number;
        });
      }

      function tabNumberFor(tabID, attempt, fromWebKit) {
        attempt = attempt || 0;
        // Extensions pass Orbit's number. sender.tab.id is still WebKit's.
        if (!fromWebKit && tabIDByNumber[tabID] != null) { return Promise.resolve(tabID); }
        var missing = new Error("No tab with id: " + tabID + ".");
        var generation = lastTabGeneration;
        return callTabs("get", [tabID]).then(function (tab) {
          if (!tab) { throw missing; }
          var knownWindow = windowNumberByID[tab.windowId];
          return invoke("orbitTabs", "numberAt", [tab.index, generation, tab.url || "", knownWindow == null ? -1 : knownWindow]).then(function (reply) {
            noteTabGeneration(reply);
            if (reply && reply.stale) {
              if (attempt + 1 >= TAB_RESOLVE_ATTEMPTS) { return numberForURL(tab.url, tabID); }
              return tabNumberFor(tabID, attempt + 1, fromWebKit);
            }
            if (!reply || typeof reply.number !== "number") { return numberForURL(tab.url, tabID); }
            rememberTab(reply.number, tabID);
            rememberWindow(reply.window, tab.windowId);
            return reply.number;
          });
        }, function () { throw missing; });
      }

      function actionTabArgument(args) {
        return args[0] && typeof args[0] === "object" && typeof args[0].tabId === "number" ? [[args[0], "tabId"]] : [];
      }
      var TAB_ARGUMENTS = {
        "tabs.reload": function (args) { return typeof args[0] === "number" ? [[args, 0]] : []; },
        "search.query": function (args) {
          return args[0] && typeof args[0] === "object" && typeof args[0].tabId === "number" ? [[args[0], "tabId"]] : [];
        },
        "action.setBadgeText": actionTabArgument,
        "action.getBadgeText": actionTabArgument,
        "action.setTitle": actionTabArgument,
        "action.getTitle": actionTabArgument,
        "action.setIcon": actionTabArgument,
        "action.setPopup": actionTabArgument,
        "action.getPopup": actionTabArgument,
        "action.enable": actionTabArgument,
        "action.disable": actionTabArgument,
        "action.isEnabled": actionTabArgument,
        "action.setBadgeBackgroundColor": actionTabArgument,
        "action.getBadgeBackgroundColor": actionTabArgument,
        "action.setBadgeTextColor": actionTabArgument,
        "action.getBadgeTextColor": actionTabArgument
      };

      function translateOutgoing(namespace, method, args) {
        var locate = TAB_ARGUMENTS[namespace + "." + method];
        if (!locate) { return Promise.resolve(args); }
        var copy = args.map(function (arg) {
          if (!arg || typeof arg !== "object" || Array.isArray(arg)) { return arg; }
          var shallow = {};
          Object.keys(arg).forEach(function (key) { shallow[key] = arg[key]; });
          return shallow;
        });
        return Promise.all(locate(copy).map(function (slot) {
          return tabNumberFor(slot[0][slot[1]]).then(function (number) {
            slot[0][slot[1]] = number;
          }, function () {});
        })).then(function () { return copy; });
      }

      // Content scripts have no native port or chrome.tabs; their calls are relayed
      // to the background, which translates there.
      function callNative(namespace, method, args) {
        var rt = runtime();
        if (!rt || !hasNativeTransport()) { return invoke(namespace, method, args); }
        return translateOutgoing(namespace, method, args).then(function (translated) {
          return invoke(namespace, method, translated);
        }).then(resolveTabReferences);
      }

      var eventDelivery = Promise.resolve();
      globalThis.__orbitDeliverChromeEvent = function (message) {
        if (!message || message.orbitChromeEvent !== true) { return; }
        // A page hears an event on its port and through evaluateJavaScript; act on it once.
        if (!firstDelivery(message.seq)) { return; }
        if (message.namespace === "__orbit") { handleInternalEvent(message); return; }
        var spread = Array.isArray(message.args);
        var args = spread ? message.args : [message.payload];
        // Chained so a tab lookup cannot reorder events, e.g. onCompleted before onCommitted.
        eventDelivery = eventDelivery.then(function () {
          return resolveTabReferences(args).catch(function () { return args; });
        }).then(function (resolved) {
          if (message.namespace === "webNavigation" && navigationEvents[message.event]) {
            var navEvent = navigationEvents[message.event];
            if (spread) { navEvent.__orbitDispatch.apply(navEvent, resolved); }
            else { navEvent.__orbitDispatch(resolved[0]); }
            return;
          }
          // Listeners stay on the event object the wrapper installed. WebKit can replace
          // chrome.permissions or chrome.cookies afterwards; the lookup below would miss them.
          if (message.namespace === "permissions" && permissionEvents[message.event]) {
            var permissionTarget = permissionEvents[message.event];
            if (typeof permissionTarget.__orbitDispatch === "function") {
              if (spread) { permissionTarget.__orbitDispatch.apply(permissionTarget, resolved); }
              else { permissionTarget.__orbitDispatch(resolved[0]); }
              return;
            }
          }
          if (message.namespace === "cookies" && message.event === "onChanged" && cookieEvent && typeof cookieEvent.__orbitDispatch === "function") {
            if (spread) { cookieEvent.__orbitDispatch.apply(cookieEvent, resolved); }
            else { cookieEvent.__orbitDispatch(resolved[0]); }
            return;
          }
          var api = resolveNamespace(globalThis.chrome, message.namespace);
          var ev = api && api[message.event];
          if (!ev || typeof ev.__orbitDispatch !== "function") { return; }
          if (spread) { ev.__orbitDispatch.apply(ev, resolved); }
          else { ev.__orbitDispatch(resolved[0]); }
        }).catch(function () {});
      };

      // A failure runs the callback inside a reply WebKit failed, which is the only
      // way runtime.lastError can be set: WebKit's lastError cannot be assigned.
      function callNativeCallback(namespace, method, args, callback) {
        if (!hasNativeTransport()) {
          callNative(namespace, method, args).then(function (value) { callback(value); }, function () { callback(); });
          return;
        }
        translateOutgoing(namespace, method, args).then(function (translated) {
          rawInvoke(namespace, method, translated, function (error, value, live) {
            if (error !== null) {
              if (live) { callback(); } else { raiseLastError(error, callback); }
              return;
            }
            resolveTabReferences(value).then(function (resolved) {
              setTimeout(function () { callback(resolved); }, 0);
            });
          });
        }, function (error) {
          raiseLastError(String((error && error.message) || error), callback);
        });
      }

      function wrap(namespace, method) {
        return function () {
          var args = Array.prototype.slice.call(arguments);
          var callback = null;
          if (args.length && typeof args[args.length - 1] === "function") { callback = args.pop(); }
          if (callback) {
            callNativeCallback(namespace, method, args, callback);
            return undefined;
          }
          return callNative(namespace, method, args);
        };
      }

      var GRANTED = [];
      var EVENTS = {};

      function event() {
        var listeners = [];
        return {
          addListener: function (listener) { listeners.push(listener); },
          removeListener: function (listener) {
            listeners = listeners.filter(function (item) { return item !== listener; });
          },
          hasListener: function (listener) { return listeners.indexOf(listener) !== -1; },
          hasListeners: function () { return listeners.length > 0; },
          __orbitDispatch: function () {
            var args = Array.prototype.slice.call(arguments);
            listeners.slice().forEach(function (listener) {
              try { listener.apply(null, args); } catch (e) { reportListenerError(e); }
            });
          }
        };
      }

      function namespaceSlot(root, namespace, create) {
        var parts = namespace.split(".");
        var parent = root;
        for (var i = 0; i < parts.length - 1; i++) {
          if (!parent[parts[i]]) {
            if (!create) { return null; }
            parent[parts[i]] = {};
          }
          parent = parent[parts[i]];
        }
        return { parent: parent, key: parts[parts.length - 1] };
      }

      // Orbit's namespaces exist only with their permission, except the members upstream leaves ungated.
      function install(root) {
        if (!root) { return; }
        Object.keys(NAMESPACES).forEach(function (namespace) {
          var granted = GRANTED.indexOf(namespace) !== -1;
          var methods = granted ? NAMESPACES[namespace] : (UNGATED[namespace] || []);
          if (!methods.length) { return; }
          var slot = namespaceSlot(root, namespace, true);
          var api = slot.parent[slot.key];
          if (!api) {
            api = {};
            Object.defineProperty(api, "__orbitNamespace", { value: true, enumerable: false });
          }
          methods.forEach(function (method) {
            if (typeof api[method] !== "function") { api[method] = wrap(namespace, method); }
          });
          if (granted) {
            (EVENTS[namespace] || []).forEach(function (name) {
              if (!api[name] || typeof api[name].addListener !== "function") { api[name] = event(); }
            });
          }
          var constants = CONSTANTS[namespace] || {};
          Object.keys(constants).forEach(function (name) {
            if (api[name] === undefined || api[name] === null) { api[name] = constants[name]; }
          });
          slot.parent[slot.key] = api;
        });
      }

      // A revoked optional permission takes its namespace away again, back to any ungated members.
      function withdrawNamespace(root, namespace) {
        var slot = namespaceSlot(root, namespace, false);
        var api = slot && slot.parent[slot.key];
        if (!api || !api.__orbitNamespace) { return; }
        var keep = UNGATED[namespace] || [];
        if (!keep.length) {
          try { delete slot.parent[slot.key]; } catch (e) {}
          return;
        }
        Object.keys(api).forEach(function (name) {
          if (typeof api[name] === "function" && keep.indexOf(name) === -1) { delete api[name]; }
          else if (api[name] && typeof api[name].__orbitDispatch === "function") { delete api[name]; }
        });
      }

      function ensureScripting(root) {
        var api = root.scripting;
        if (!api) { return; }
        var worlds = api.ExecutionWorld || {};
        if (worlds.ISOLATED == null) { worlds.ISOLATED = "ISOLATED"; }
        if (worlds.MAIN == null) { worlds.MAIN = "MAIN"; }
        api.ExecutionWorld = worlds;
      }
      function ensureMissingEvents(api, names) {
        names.forEach(function (name) {
          if (!api[name] || typeof api[name].addListener !== "function") { api[name] = event(); }
        });
        return api;
      }
      function captureEvent(ev) {
        if (!ev || ev.__orbitCaptured) { return ev; }
        var listeners = [];
        try {
          if (typeof ev.addListener === "function") {
            var originalAdd = ev.addListener.bind(ev);
            ev.addListener = function (listener) {
              listeners.push(listener);
              return originalAdd.apply(ev, arguments);
            };
            if (typeof ev.removeListener === "function") {
              var originalRemove = ev.removeListener.bind(ev);
              ev.removeListener = function (listener) {
                listeners = listeners.filter(function (item) { return item !== listener; });
                return originalRemove(listener);
              };
            }
            if (typeof ev.hasListener === "function") {
              var originalHas = ev.hasListener.bind(ev);
              ev.hasListener = function (listener) {
                return listeners.indexOf(listener) !== -1 || originalHas(listener);
              };
            }
          }
          ev.__orbitDispatch = function () {
            var args = Array.prototype.slice.call(arguments);
            listeners.forEach(function (listener) {
              try { listener.apply(null, args); } catch (e) {}
            });
          };
          if (typeof ev.hasListeners !== "function") {
            ev.hasListeners = function () { return listeners.length > 0; };
          }
          ev.__orbitCaptured = true;
        } catch (e) {}
        return ev;
      }
      function isMatchPattern(value) {
        return value === "<all_urls>" || /^(\*|https?|ftp|file|wss?):\/\/(\*|(\*\.)?[^\/:*]+)\/(.*)$/.test(value);
      }
      function patternForURL(value) {
        try {
          var url = new URL(value);
          if (!url.hostname) { return null; }
          return url.protocol + "//" + url.hostname + "/*";
        } catch (e) { return null; }
      }
      // The id an extension sees is Orbit's tab number. WebKit's own id is remembered
      // so tabs.get can call back into WebKit.
      function withKnownOrbitIDs(list) {
        return (list || []).map(function (tab) {
          if (!tab || typeof tab.id !== "number") { return tab; }
          if (tabNumberByID[tab.id] == null || tabIDByNumber[tab.id] != null) { return tab; }
          var copy = {};
          Object.keys(tab).forEach(function (key) { copy[key] = tab[key]; });
          copy.id = tabNumberByID[tab.id];
          return copy;
        });
      }
      function withOrbitIDs(list) {
        return Promise.all((list || []).map(function (tab) {
          if (!tab || typeof tab.id !== "number") { return Promise.resolve(tab); }
          if (tabNumberByID[tab.id] != null && tabIDByNumber[tab.id] == null) {
            var known = {};
            Object.keys(tab).forEach(function (key) { known[key] = tab[key]; });
            known.id = tabNumberByID[tab.id];
            return Promise.resolve(known);
          }
          return tabNumberFor(tab.id).then(function (number) {
            rememberTab(number, tab.id);
            var copy = {};
            Object.keys(tab).forEach(function (key) { copy[key] = tab[key]; });
            copy.id = number;
            return copy;
          }, function () { return tab; });
        }));
      }
      function ensureTabs(root) {
        var api = root.tabs || {};
        ensureMissingEvents(api, ["onCreated", "onUpdated", "onMoved", "onActivated", "onRemoved", "onReplaced"]);
        ["onCreated", "onUpdated", "onMoved", "onActivated", "onRemoved", "onReplaced"].forEach(function (name) {
          if (api[name]) { captureEvent(api[name]); }
        });
        if (typeof api.query === "function" && !api.query.__orbitWrapped) {
          var originalQuery = api.query.bind(api);
          var wrappedQuery = function (query, callback) {
            var exact = [];
            var next = {};
            Object.keys(query || {}).forEach(function (key) {
              if (key === "title" || key === "currentWindow" || key === "groupId" || key === "windowType") { return; }
              next[key] = query[key];
            });
            if (query && query.url != null) {
              var urls = Array.isArray(query.url) ? query.url : [query.url];
              var patterns = [];
              urls.forEach(function (url) {
                if (typeof url !== "string") { return; }
                if (isMatchPattern(url)) { patterns.push(url); return; }
                exact.push(url);
                var pattern = patternForURL(url);
                if (pattern) { patterns.push(pattern); }
              });
              if (patterns.length === 0) { delete next.url; }
              else { next.url = Array.isArray(query.url) ? patterns : patterns[0]; }
            }
            var tabSnapshotKeys = ["url", "pendingUrl", "title", "favIconUrl", "status"];
            var concealedDetailKeys = { url: true, pendingUrl: true, title: true, favIconUrl: true };
            // Content-script matches are not host permissions. Without "tabs" or a declared
            // host permission the property must be absent, not null: the first query runs
            // before any later conformance script is installed.
            function extensionMaySeeTabDetails() {
              try {
                var manifest = root.runtime && root.runtime.getManifest ? root.runtime.getManifest() : null;
                if (!manifest) { return true; }
                var names = [].concat(manifest.permissions || [], manifest.optional_permissions || []);
                if (names.indexOf("tabs") !== -1) { return true; }
                var hosts = [].concat(manifest.host_permissions || [], manifest.optional_host_permissions || []);
                return hosts.length > 0;
              } catch (e) { return true; }
            }
            function withoutConcealedDetails(tab) {
              if (!tab || extensionMaySeeTabDetails()) { return tab; }
              var copy = {};
              var fields = Object.keys(tab);
              for (var i = 0; i < fields.length; i++) {
                if (!concealedDetailKeys[fields[i]]) { copy[fields[i]] = tab[fields[i]]; }
              }
              ["id", "index", "windowId", "active", "pinned", "highlighted", "audible", "mutedInfo", "status", "incognito", "groupId", "autoDiscardable", "discarded", "frozen"].forEach(function (key) {
                if (copy[key] !== undefined) { return; }
                try { if (tab[key] !== undefined) { copy[key] = tab[key]; } } catch (e) {}
              });
              return copy;
            }
            function normalizeTab(tab) {
              if (!tab || typeof tab !== "object") { return tab; }
              var keys = Object.keys(tab);
              var present = Object.create(null);
              for (var i = 0; i < keys.length; i++) { present[keys[i]] = true; }
              var unchanged = true;
              for (var s = 0; s < tabSnapshotKeys.length; s++) {
                var name = tabSnapshotKeys[s];
                if (present[name]) { continue; }
                try { if (tab[name] != null) { unchanged = false; break; } } catch (e) {}
              }
              if (unchanged && (!present.groupId || tab.groupId == null)) { unchanged = false; }
              if (unchanged && (!present.autoDiscardable || tab.autoDiscardable == null)) { unchanged = false; }
              if (unchanged && (!present.discarded || tab.discarded == null)) { unchanged = false; }
              if (unchanged && (!present.frozen || tab.frozen == null)) { unchanged = false; }
              // WebKit already returned every field the copy would fill in.
              if (unchanged) { return withoutConcealedDetails(tab); }
              var copy = {};
              for (var k = 0; k < keys.length; k++) { copy[keys[k]] = tab[keys[k]]; }
              // Title and pendingUrl are often getters, so Object.keys misses them and a title filter matches nothing.
              for (var n = 0; n < tabSnapshotKeys.length; n++) {
                var key = tabSnapshotKeys[n];
                try { if (tab[key] != null && copy[key] == null) { copy[key] = tab[key]; } } catch (e) {}
              }
              if (copy.groupId == null) { copy.groupId = -1; }
              if (copy.autoDiscardable == null) { copy.autoDiscardable = true; }
              if (copy.discarded == null) { copy.discarded = false; }
              if (copy.frozen == null) { copy.frozen = false; }
              return withoutConcealedDetails(copy);
            }
            function titleOK(tab, title) {
              if (title == null) { return true; }
              var patterns = Array.isArray(title) ? title : [title];
              return patterns.some(function (pattern) {
                var source = "^" + String(pattern).replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*").replace(/\?/g, ".") + "$";
                return new RegExp(source, "i").test((tab && tab.title) || "");
              });
            }
            function urlOK(tab) {
              if (!query || query.url == null) { return true; }
              var wanted = Array.isArray(query.url) ? query.url : [query.url];
              var patterns = wanted.filter(function (url) { return typeof url === "string" && isMatchPattern(url); });
              if (!patterns.length) { return true; }
              var candidates = [tab && tab.url].filter(Boolean);
              return patterns.some(function (pattern) {
                return candidates.some(function (url) { return webRequestPatternMatches(pattern, url); });
              });
            }
            function attachPending(list) {
              return invoke("orbitTabs", "pending", []).then(function (rows) {
                var byURL = {};
                (rows || []).forEach(function (row) {
                  if (row && row.url && row.pending) { byURL[row.url] = row.pending; }
                });
                var tabs = list || [];
                var changed = null;
                for (var i = 0; i < tabs.length; i++) {
                  var tab = tabs[i];
                  var pending = tab && !tab.pendingUrl && typeof tab.url === "string" ? byURL[tab.url] : undefined;
                  if (!pending) {
                    if (changed) { changed.push(tab); }
                    continue;
                  }
                  if (!changed) { changed = tabs.slice(0, i); }
                  var copy = {};
                  var fields = Object.keys(tab);
                  for (var k = 0; k < fields.length; k++) { copy[fields[k]] = tab[fields[k]]; }
                  copy.pendingUrl = pending;
                  changed.push(copy);
                }
                return changed || tabs;
              }, function () { return list || []; });
            }
            function finish(tabs) {
              var list = (tabs || []).map(normalizeTab);
              if (exact.length) {
                list = list.filter(function (tab) {
                  return exact.some(function (url) { return tab && tab.url === url; });
                });
              }
              list = list.filter(urlOK);
              return list;
            }
            function constrain(list, currentId, done) {
              var info = query || {};
              done(list.filter(function (tab) {
                if (!tab) { return false; }
                if (info.currentWindow === true && currentId != null && tab.windowId !== currentId) { return false; }
                if (info.currentWindow === false && currentId != null && tab.windowId === currentId) { return false; }
                if (info.groupId != null && tab.groupId !== info.groupId) { return false; }
                if (info.windowType != null && info.windowType !== "normal") { return false; }
                if (!titleOK(tab, info.title)) { return false; }
                return true;
              }));
            }
            function deliver(list, done) {
              var info = query || {};
              // A service worker's getCurrent is often empty, so the active tab comes from Orbit.
              if (info.active === true && info.currentWindow === true) {
                invoke("orbitTabs", "active", []).then(function (active) {
                  if (!active || typeof active.number !== "number") {
                    var nativeActive = (list || []).filter(function (tab) {
                      return tab && tab.active !== false && /^https?:/i.test(tab.url || "");
                    });
                    if (nativeActive.length) { done(nativeActive); return; }
                    deliverByWindow(list, done);
                    return;
                  }
                  var match = (list || []).filter(function (tab) { return tab && tab.id === active.number; })[0];
                  if (!match) {
                    match = {
                      id: active.number,
                      url: active.url || "",
                      active: true,
                      windowId: active.window,
                      index: 0,
                      status: "complete"
                    };
                  }
                  done([match]);
                }, function () { deliverByWindow(list, done); });
                return;
              }
              deliverByWindow(list, done);
            }
            function deliverByWindow(list, done) {
              var info = query || {};
              if (info.currentWindow == null) { constrain(list, null, done); return; }
              var windows = root.windows;
              if (!windows || typeof windows.getCurrent !== "function") { constrain(list, null, done); return; }
              var sent = false;
              function windowIdFrom(list) {
                var ids = [];
                (list || []).forEach(function (tab) {
                  if (tab && typeof tab.windowId === "number" && ids.indexOf(tab.windowId) < 0) { ids.push(tab.windowId); }
                });
                return ids.length === 1 ? ids[0] : null;
              }
              function reply(id) {
                if (sent) { return; }
                sent = true;
                if (id == null) { id = windowIdFrom(list); }
                // getCurrent's own lastError is still set inside its callback. The query
                // callback has to run after that, or promisify rejects a successful list.
                setTimeout(function () {
                  constrain(list, id, function (filtered) {
                    var wantsCurrentActive = info.active === true && info.currentWindow === true;
                    if (!wantsCurrentActive) { done(filtered); return; }
                    invoke("orbitTabs", "active", []).then(function (active) {
                      if (!active || typeof active.number !== "number") { done(filtered || []); return; }
                      var match = (list || []).filter(function (tab) { return tab && tab.id === active.number; })[0];
                      if (!match) {
                        match = (filtered || []).filter(function (tab) { return tab && tab.id === active.number; })[0];
                      }
                      if (match) { done([match]); return; }
                      done([{
                        id: active.number,
                        url: active.url || "",
                        active: true,
                        windowId: active.window,
                        index: 0,
                        status: "complete"
                      }]);
                    }, function () { done(filtered || []); });
                  });
                }, 0);
              }
              try {
                var pending = windows.getCurrent(function (win) { reply(win && win.id); });
                if (pending && typeof pending.then === "function") {
                  pending.then(function (win) { reply(win && win.id); }, function () { reply(null); });
                }
              } catch (e) { reply(null); }
              setTimeout(function () {
                if (sent || typeof windows.getAll !== "function") { return; }
                try {
                  windows.getAll(function (wins) {
                    var focused = (wins || []).filter(function (win) { return win && win.focused; })[0];
                    reply(focused ? focused.id : null);
                  });
                } catch (e) { reply(null); }
              }, 250);
            }
            var wantsFocused = !!(query && query.lastFocusedWindow);
            function withoutFocused(q) {
              var retry = {};
              Object.keys(q || {}).forEach(function (key) {
                if (key !== "lastFocusedWindow") { retry[key] = q[key]; }
              });
              return retry;
            }
            function run(q, allowFallback, done) {
              var settled = false;
              function accept(tabs) {
                if (settled) { return; }
                var list = finish(tabs);
                if (allowFallback && wantsFocused && (!list || !list.length)) {
                  settled = true;
                  run(withoutFocused(q), false, done);
                  return;
                }
                settled = true;
                var presentedOnce = false;
                function present(tabs) {
                  if (presentedOnce) { return; }
                  presentedOnce = true;
                  deliver(tabs, done);
                }
                attachPending(list).then(withOrbitIDs).then(present, function () { present(withKnownOrbitIDs(list)); });
                setTimeout(function () { present(withKnownOrbitIDs(list)); }, 1000);
              }
              try { originalQuery(q, accept); }
              catch (e) { accept([]); }
            }
            if (typeof callback === "function") {
              run(next, true, function (tabs) {
                setTimeout(function () { callback(tabs); }, 0);
              });
              return;
            }
            var result = originalQuery(next);
            if (result && typeof result.then === "function") {
              return result.then(function (tabs) {
                var list = finish(tabs);
                if (wantsFocused && (!list || !list.length)) {
                  var retry = originalQuery(withoutFocused(next));
                  var retried = retry && typeof retry.then === "function" ? retry.then(finish) : Promise.resolve(finish(retry));
                  return Promise.resolve(retried).then(attachPending).then(withOrbitIDs);
                }
                return attachPending(list).then(withOrbitIDs);
              });
            }
            return result;
          };
          wrappedQuery.__orbitWrapped = true;
          wrappedQuery.__orbitNative = originalQuery;
          api.query = wrappedQuery;
        }
        if (typeof api.get === "function" && !api.get.__orbitGet) {
          var nativeGet = api.get.bind(api);
          function withShownID(tab, shownID) {
            if (!tab || typeof shownID !== "number") { return tab; }
            var copy = {};
            Object.keys(tab).forEach(function (key) { copy[key] = tab[key]; });
            copy.id = shownID;
            return copy;
          }
            function forgetShownID(shownID) {
              var webKitId = tabIDByNumber[shownID];
              if (webKitId != null) { delete tabNumberByID[webKitId]; }
              delete tabIDByNumber[shownID];
            }
            function locateShown(tabId) {
              return invoke("orbitTabs", "locate", [tabId]).then(function (reply) {
                var ref = reply && reply.reference;
                if (!ref || typeof ref.number !== "number") { return null; }
                return { id: ref.number, url: ref.url || "", index: ref.index, windowId: ref.window, active: true };
              }, function () { return null; });
            }
            var wrappedGet = function (tabId, callback) {
            function answer(tab) {
              if (typeof callback !== "function") { return Promise.resolve(tab); }
              // The user callback must run after WebKit's get callback, or lastError rejects a real tab.
              setTimeout(function () { callback(tab); }, 0);
              return undefined;
            }
            function fromWebKit(webKitId, shownID) {
              function recovered(tab) {
                if (tab) { return answer(withShownID(tab, shownID)); }
                forgetShownID(shownID);
                var located = locateShown(shownID);
                if (typeof callback === "function") {
                  located.then(function (found) {
                    if (found) { answer(found); return; }
                    nativeGet(tabId, callback);
                  });
                  return undefined;
                }
                return located.then(function (found) { return found || nativeGet(tabId); });
              }
              if (typeof callback === "function") {
                return nativeGet(webKitId, function (tab) {
                  var rt = runtime();
                  if ((rt && rt.lastError) || !tab) { recovered(null); return; }
                  answer(withShownID(tab, shownID));
                });
              }
              var pending = nativeGet(webKitId);
              if (pending && typeof pending.then === "function") {
                return pending.then(function (tab) { return withShownID(tab, shownID); }, function () { return recovered(null); });
              }
              return pending ? withShownID(pending, shownID) : recovered(null);
            }
            if (tabIDByNumber[tabId] != null) { return fromWebKit(tabIDByNumber[tabId], tabId); }
            var located = locateShown(tabId);
            if (typeof callback === "function") {
              located.then(function (tab) {
                if (tab) { answer(tab); return; }
                nativeGet(tabId, callback);
              });
              return undefined;
            }
            return located.then(function (tab) { return tab || nativeGet(tabId); });
          };
          wrappedGet.__orbitGet = true;
          wrappedGet.__orbitNative = nativeGet;
          api.get = wrappedGet;
        }
        installTabReload(api);
        installZoomSettings(api);
        if (typeof api.reload !== "function") {
          var reloadTries = 0;
          var reloadTimer = setInterval(function () {
            reloadTries += 1;
            var live = (root && root.tabs) || api;
            if (live && typeof live.reload === "function") {
              clearInterval(reloadTimer);
              installTabReload(live);
            } else if (reloadTries > 40) { clearInterval(reloadTimer); }
          }, 25);
        }
        root.tabs = api;
      }
      // WebKit has getZoom and setZoom, not the settings object. Orbit's zoom is per
      // host, and the page zoom is what getZoom already returns.
      function installZoomSettings(api) {
        if (!api || typeof api.getZoom !== "function") { return; }
        if (typeof api.getZoomSettings !== "function") {
          api.getZoomSettings = function (tabId, callback) {
            var id = typeof tabId === "number" ? tabId : undefined;
            var done = typeof tabId === "function" ? tabId : callback;
            var pending = id == null ? api.getZoom() : api.getZoom(id);
            function pack(factor) {
              return { mode: "automatic", scope: "per-origin", defaultZoomFactor: factor };
            }
            if (typeof done === "function") {
              if (pending && typeof pending.then === "function") { pending.then(function (factor) { done(pack(factor)); }); }
              else { done(pack(pending)); }
              return;
            }
            if (pending && typeof pending.then === "function") { return pending.then(pack); }
            return Promise.resolve(pack(pending));
          };
        }
        if (typeof api.setZoomSettings !== "function" && typeof api.setZoom === "function") {
          api.setZoomSettings = function (tabId, zoomSettings, callback) {
            var id, settings, done;
            if (typeof tabId === "number") {
              id = tabId;
              settings = zoomSettings;
              done = callback;
            } else {
              id = undefined;
              settings = tabId;
              done = typeof zoomSettings === "function" ? zoomSettings : callback;
            }
            var factor = settings && settings.defaultZoomFactor;
            if (typeof factor !== "number") {
              if (typeof done === "function") { done(); return; }
              return Promise.resolve();
            }
            return id == null ? api.setZoom(factor, done) : api.setZoom(id, factor, done);
          };
        }
      }
      function installTabReload(api) {
        if (!api || api.__orbitReloadHook) { return; }
        var originalReload = typeof api.reload === "function" ? api.reload.bind(api) : null;
        var wrappedReload = function (a, b, c) {
          var tabId = null;
          var props = null;
          var callback = null;
          if (typeof a === "number") {
            tabId = a;
            if (typeof b === "function") { callback = b; }
            else { props = b; if (typeof c === "function") { callback = c; } }
          } else if (typeof a === "function") {
            callback = a;
          } else if (a && typeof a === "object") {
            props = a;
            if (typeof b === "function") { callback = b; }
          }
          // WebKit's own reload targets the tab WebKit thinks is current, which is not
          // Orbit's active tab, and it ignores bypassCache. Orbit owns the tab strip.
          var call = wrap("tabs", "reload");
          var result = tabId == null ? call(props || {}, callback) : call(tabId, props || {}, callback);
          if (result && typeof result.catch === "function" && typeof originalReload === "function") {
            return result.catch(function () { return originalReload(a, b, c); });
          }
          return result;
        };
        wrappedReload.__orbitWrapped = true;
        try {
          Object.defineProperty(api, "reload", {
            configurable: true,
            enumerable: true,
            get: function () { return wrappedReload; },
            set: function (value) {
              if (value && value.__orbitWrapped) { return; }
              if (typeof value === "function") { originalReload = value.bind(api); }
            }
          });
          api.__orbitReloadHook = true;
        } catch (e) {
          if (typeof api.reload !== "function" || api.reload.__orbitWrapped) { return; }
          api.reload = wrappedReload;
          api.__orbitReloadHook = true;
        }
      }
      // WebKit leaves runtime.id unset in a service worker, and the property rejects assignment.
      // Chrome's id is the host of the extension origin.
      function ensureRuntimeID(root) {
        var api = root && root.runtime;
        if (!api || api.__orbitRuntimeID) { return; }
        if (typeof api.getURL !== "function") { return; }
        var host = "";
        try { host = new URL(api.getURL("/")).host; } catch (e) { return; }
        if (!host) { return; }
        if (api.id != null && api.id !== "") { return; }
        var proxy = new Proxy(api, {
          get: function (target, prop, receiver) {
            if (prop === "id") { return host; }
            if (prop === "__orbitRuntimeID") { return true; }
            var value = Reflect.get(target, prop, receiver);
            return typeof value === "function" ? value.bind(target) : value;
          }
        });
        try { root.runtime = proxy; } catch (e) {}
      }
      function ensureRuntime(root) {
        var api = root.runtime || {};
        ensureMissingEvents(api, ["onInstalled", "onSuspend", "onSuspendCanceled", "onUpdateAvailable", "onConnect"]);
        if (typeof api.getURL === "function" && !api.getURL.__orbitWrapped) {
          var originalGetURL = api.getURL.bind(api);
          api.getURL = function (path) {
            var url = originalGetURL(path);
            if (!path && url && url.charAt(url.length - 1) !== "/") { url += "/"; }
            return url;
          };
          api.getURL.__orbitWrapped = true;
        }
        root.runtime = api;
        ensureRuntimeID(root);
      }
      var commandEvent = null;
      function ensureCommands(root) {
        var api = root.commands || {};
        if (typeof api.getAll !== "function" || !api.getAll.__orbitWrapped) {
          var getAll = wrap("commands", "getAll");
          getAll.__orbitWrapped = true;
          api.getAll = getAll;
        }
        if (!commandEvent) {
          if (api.onCommand && typeof api.onCommand.__orbitDispatch === "function") {
            commandEvent = api.onCommand;
          } else if (api.onCommand && typeof api.onCommand.addListener === "function") {
            captureEvent(api.onCommand);
            commandEvent = api.onCommand;
          } else {
            commandEvent = event();
          }
        }
        if (api.onCommand !== commandEvent) { adoptEvent(api, "onCommand", commandEvent); }
        root.commands = api;
      }
      function ensureSessions(root) {
        if (GRANTED.indexOf("sessions") === -1) { return; }
        var api = root.sessions || {};
        if (api.MAX_SESSION_RESULTS == null) { api.MAX_SESSION_RESULTS = ORBIT_CONFIG.maxSessionResults || 25; }
        root.sessions = api;
      }
      function dispatchCookieChange(api, details, value, removed) {
        var cookie = (value && typeof value === "object") ? value : {
          name: details && details.name,
          value: details && details.value,
          url: details && details.url
        };
        var info = cookieChangeInfo({ removed: removed === true, cookie: cookie, cause: "explicit" });
        var target = cookieEvent || (api && api.onChanged);
        if (target && typeof target.__orbitDispatch === "function") { target.__orbitDispatch(info); }
      }
      function wrapCookieMutator(api, name, removed) {
        if (typeof api[name] !== "function" || api[name].__orbitWrapped) { return; }
        var original = api[name].bind(api);
        var wrapped = function (details, callback) {
          if (typeof callback === "function") {
            return original(details, function (value) {
              dispatchCookieChange(api, details, value, removed);
              callback(value);
            });
          }
          var result = original(details);
          if (result && typeof result.then === "function") {
            return result.then(function (value) {
              dispatchCookieChange(api, details, value, removed);
              return value;
            });
          }
          return result;
        };
        wrapped.__orbitWrapped = true;
        api[name] = wrapped;
      }
      function cookieChangeInfo(info) {
        var change = info && typeof info === "object" ? info : {};
        var cookie = change.cookie && typeof change.cookie === "object" ? change.cookie : {};
        var domain = cookie.domain;
        if (typeof domain !== "string" || !domain) {
          if (typeof cookie.url === "string") {
            try { domain = new URL(cookie.url).hostname; } catch (e) { domain = ""; }
          } else {
            domain = "";
          }
        }
        var copy = {};
        Object.keys(cookie).forEach(function (key) { copy[key] = cookie[key]; });
        copy.domain = domain;
        return {
          removed: change.removed === true,
          cookie: copy,
          cause: typeof change.cause === "string" ? change.cause : "explicit"
        };
      }
      var cookieEvent = null;
      function ensureCookies(root) {
        var api = root.cookies;
        if (!api) { return; }
        if (!cookieEvent) {
          cookieEvent = event();
          var native = api.onChanged;
          if (native && native !== cookieEvent && typeof native.addListener === "function") {
            try {
              native.addListener(function (info) {
                var change = cookieChangeInfo(info);
                if (typeof change.cookie.name !== "string" || !change.cookie.name) { return; }
                cookieEvent.__orbitDispatch(change);
              });
            } catch (e) {}
          }
        }
        if (!api.__orbitCookies) {
          api.__orbitCookies = true;
          wrapCookieMutator(api, "set", false);
          wrapCookieMutator(api, "remove", true);
        }
        // WebKit sometimes never calls getAll back, and anything awaiting it never finishes.
        if (typeof api.getAll === "function" && !api.getAll.__orbitGetAll) {
          var nativeGetAll = api.getAll.bind(api);
          function wrappedGetAll(details, callback) {
            if (typeof details === "function") { callback = details; details = {}; }
            var sent = false;
            function listFrom(cookies) { return Array.isArray(cookies) ? cookies : []; }
            function finish(cookies) {
              if (sent) { return; }
              sent = true;
              if (typeof callback === "function") {
                var list = listFrom(cookies);
                setTimeout(function () { callback(list); }, 0);
              }
            }
            if (typeof callback !== "function") {
              try {
                var promised = nativeGetAll(details || {});
                if (promised && typeof promised.then === "function") {
                  return promised.then(listFrom, function () { return []; });
                }
              } catch (e) {}
              return Promise.resolve([]);
            }
            try {
              nativeGetAll(details || {}, function (cookies) { finish(cookies); });
            } catch (e) { finish([]); }
            setTimeout(function () { finish([]); }, 1000);
          }
          wrappedGetAll.__orbitGetAll = true;
          api.getAll = wrappedGetAll;
        }
        if (api.onChanged !== cookieEvent) { adoptEvent(api, "onChanged", cookieEvent); }
      }
      function chromeSetting(name) {
        var setting = {
          get: function (details) { return invoke("privacy", "get", [name, details || {}]); },
          set: function (details) {
            return invoke("privacy", "set", [name, details || {}]).then(function (value) {
              setting.onChange.__orbitDispatch(value);
            });
          },
          clear: function (details) {
            return invoke("privacy", "clear", [name, details || {}]).then(function (value) {
              setting.onChange.__orbitDispatch(value);
            });
          },
          onChange: event()
        };
        return setting;
      }
      function ensurePrivacy(root) {
        if (GRANTED.indexOf("privacy") === -1) { return; }
        var privacy = root.privacy;
        if (!privacy) {
          privacy = {};
          Object.defineProperty(privacy, "__orbitNamespace", { value: true, enumerable: false });
        }
        var services = privacy.services || {};
        // Kept across a re-run after a grant, so listeners on onChange survive.
        if (!services.searchSuggestEnabled || !services.searchSuggestEnabled.__orbitSetting) {
          services.searchSuggestEnabled = chromeSetting("searchSuggestEnabled");
          Object.defineProperty(services.searchSuggestEnabled, "__orbitSetting", { value: true, enumerable: false });
        }
        delete services.passwordSavingEnabled;
        delete services.autofillAddressEnabled;
        delete services.autofillCreditCardEnabled;
        privacy.services = services;
        delete privacy.network;
        delete privacy.websites;
        root.privacy = privacy;
      }
      function fillExtensionSurface(root) {
        ensureNavigation(root);
        ensureScripting(root);
        ensureWebRequestConstants(root);
        tolerateWebRequestFilters(root);
        ensureAuthRequired(root);
        ensureTabs(root);
        ensureRuntime(root);
        ensureLifecycle(root);
        ensureCommands(root);
        ensureSessions(root);
        ensureCookies(root);
        ensurePrivacy(root);
        ensurePermissions(root);
        ensureStorage(root);
        tolerateDeclarativeNetRequest(root);
        hookAction(root);
      }
      function hookWindows(root) {
        var api = root.windows;
        if (!api || typeof api.getAll !== "function" || api.getAll.__orbitWindows) { return; }
        function present(win) {
          if (!win) { return Promise.resolve(win); }
          if (!win.tabs) { return Promise.resolve(win); }
          return withOrbitIDs(win.tabs).then(function (tabs) {
            var copy = {};
            Object.keys(win).forEach(function (key) { copy[key] = win[key]; });
            copy.tabs = tabs;
            return copy;
          });
        }
        var originalAll = api.getAll.bind(api);
        api.getAll = function (info, callback) {
          if (typeof info === "function") { callback = info; info = {}; }
          if (typeof callback === "function") {
            return originalAll(info || {}, function (wins) {
              Promise.all((wins || []).map(present)).then(function (presented) { callback(presented); });
            });
          }
          var result = originalAll(info || {});
          if (result && typeof result.then === "function") {
            return result.then(function (wins) { return Promise.all((wins || []).map(present)); });
          }
          return result;
        };
        api.getAll.__orbitWindows = true;
      }
      function hookAction(root) {
        var api = root.action;
        if (!api) { return; }
        // WebKit replaces these methods in place. The flag on the namespace would hide that.
        if (api.setBadgeText && api.setBadgeText.__orbitAction) { return; }
        // WebKit's action object has no disable, enable, or isEnabled, and no badge-colour
        // pair. The toolbar reads those from Orbit, so the call has to land here.
        ["setBadgeBackgroundColor", "getBadgeBackgroundColor", "setBadgeTextColor", "getBadgeTextColor",
         "setPopup", "getPopup", "setTitle", "getTitle", "setBadgeText", "getBadgeText",
         "setIcon", "enable", "disable", "isEnabled"].forEach(function (method) {
          var wrapped = function () {
            var args = Array.prototype.slice.call(arguments);
            var callback = null;
            if (args.length && typeof args[args.length - 1] === "function") { callback = args.pop(); }
            var details = args[0];
            var payload = details == null ? {} : (typeof details === "object" ? details : { tabId: details });
            if (callback) {
              callNativeCallback("action", method, [payload], callback);
              return undefined;
            }
            return callNative("action", method, [payload]);
          };
          wrapped.__orbitAction = true;
          api[method] = wrapped;
        });
        api.__orbitActionHooked = true;
      }
      function hookDeclarativeNetRequest(root) {
        tolerateDeclarativeNetRequest(root);
        var existing = root.declarativeNetRequest;
        // Without the permission there is nothing to hook, and a stored undefined would mask a later grant.
        if (!existing) { return; }
        try {
          var stored = existing;
          Object.defineProperty(root, "declarativeNetRequest", {
            configurable: true,
            enumerable: true,
            get: function () {
              tolerateDeclarativeNetRequest({ declarativeNetRequest: stored });
              return stored;
            },
            set: function (value) {
              stored = value;
              tolerateDeclarativeNetRequest({ declarativeNetRequest: stored });
            }
          });
        } catch (e) {}
      }
      // WebKit defines chrome.webRequest only for an extension holding the permission.
      function ensureWebRequestConstants(root) {
        var api = root.webRequest;
        if (!api) { return; }
        ["OnBeforeRequestOptions", "OnBeforeSendHeadersOptions", "OnSendHeadersOptions", "OnHeadersReceivedOptions", "OnAuthRequiredOptions", "OnResponseStartedOptions", "OnBeforeRedirectOptions", "OnCompletedOptions", "OnErrorOccurredOptions"].forEach(function (name) {
          var bag = api[name] || {};
          if (bag.EXTRA_HEADERS == null) { bag.EXTRA_HEADERS = "extraHeaders"; }
          if (bag.BLOCKING == null) { bag.BLOCKING = "blocking"; }
          if (bag.REQUEST_HEADERS == null) { bag.REQUEST_HEADERS = "requestHeaders"; }
          if (bag.RESPONSE_HEADERS == null) { bag.RESPONSE_HEADERS = "responseHeaders"; }
          api[name] = bag;
        });
        ["onBeforeRequest", "onBeforeSendHeaders", "onSendHeaders", "onHeadersReceived", "onAuthRequired", "onResponseStarted", "onBeforeRedirect", "onCompleted", "onErrorOccurred"].forEach(function (name) {
          if (!api[name] || typeof api[name].addListener !== "function") { api[name] = event(); }
        });
      }

      function webRequestMatches(filter, details) {
        if (!filter || !details || typeof details.url !== "string") { return !filter; }
        var urls = filter.urls;
        if (Array.isArray(urls) && urls.length && !urls.some(function (pattern) { return webRequestPatternMatches(pattern, details.url); })) {
          return false;
        }
        if (Array.isArray(filter.types) && filter.types.length && filter.types.indexOf(details.type) === -1) { return false; }
        return true;
      }
      function webRequestPatternMatches(pattern, url) {
        if (pattern === "<all_urls>") { return /^(https?|wss?|ftp|file):/i.test(url); }
        var parsed;
        try { parsed = new URL(url); } catch (e) { return false; }
        var match = /^(\*|https?|wss?|ftp|file):\/\/([^/]*)(\/.*)$/.exec(pattern);
        if (!match) { return false; }
        var scheme = match[1].toLowerCase();
        var actualScheme = parsed.protocol.replace(/:$/, "").toLowerCase();
        if (scheme === "*") {
          if (actualScheme !== "http" && actualScheme !== "https" && actualScheme !== "ws" && actualScheme !== "wss" && actualScheme !== "ftp") { return false; }
        } else if (scheme !== actualScheme) { return false; }
        var hostPort = match[2];
        var host = hostPort;
        var port = null;
        var colon = hostPort.lastIndexOf(":");
        if (colon > 0 && /^\d+$/.test(hostPort.slice(colon + 1))) {
          host = hostPort.slice(0, colon);
          port = hostPort.slice(colon + 1);
        }
        if (port !== null && String(parsed.port || "") !== port) { return false; }
        var actualHost = parsed.hostname.toLowerCase();
        host = host.toLowerCase();
        if (host !== "*") {
          if (host.indexOf("*.") === 0) {
            var suffix = host.slice(2);
            if (actualHost !== suffix && actualHost.slice(-(suffix.length + 1)) !== "." + suffix) { return false; }
          } else if (actualHost !== host) { return false; }
        }
        var path = match[3];
        var actualPath = parsed.pathname || "/";
        var regex = "^" + path.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*") + "$";
        return new RegExp(regex).test(actualPath);
      }
      function tolerateWebRequestFilters(root) {
        var api = root.webRequest;
        if (!api) { return; }
        ["onBeforeRequest", "onBeforeSendHeaders", "onSendHeaders", "onHeadersReceived", "onAuthRequired", "onResponseStarted", "onBeforeRedirect", "onCompleted", "onErrorOccurred"].forEach(function (name) {
          var ev = api[name];
          if (!ev || typeof ev.addListener !== "function" || ev.__orbitFilterWrapped) { return; }
          captureEvent(ev);
          var original = ev.addListener.bind(ev);
          ev.addListener = function (listener, filter, extra) {
            var gated = function (details) {
              if (!webRequestMatches(filter, details)) { return; }
              return listener.apply(null, arguments);
            };
            var next = filter;
            if (filter && Array.isArray(filter.urls)) {
              var urls = filter.urls.filter(function (pattern) { return !/^wss?:/i.test(pattern); });
              if (urls.length === 0) { urls = ["<all_urls>"]; }
              next = {};
              Object.keys(filter).forEach(function (key) { next[key] = filter[key]; });
              next.urls = urls;
            }
            return original(gated, next, extra);
          };
          ev.__orbitFilterWrapped = true;
        });
      }

      function bindRuntimeBridge() {
      var rt = runtime();
      if (rt && rt.onMessage && typeof rt.onMessage.addListener === "function") {
        var listeners = [];
        var queuedUntilListener = [];
        var originalAdd = rt.onMessage.addListener.bind(rt.onMessage);
        function normalizeSender(sender) {
          if (!sender || typeof sender !== "object") { return sender; }
          var derived = null;
          if (typeof sender.url === "string" && sender.url) {
            try { derived = new URL(sender.url).origin; } catch (e) {}
          }
          if (sender.origin && sender.origin !== "null" && sender.origin !== derived) {
            if (!(derived && String(sender.url || "").indexOf(derived) === 0 && (sender.url.indexOf("-extension:") !== -1))) {
              return sender;
            }
          }
          if (sender.origin && sender.origin !== "null" && !derived) { return sender; }
          if (!derived) {
            try {
              var current = runtime();
              if (current && typeof current.getURL === "function") {
                derived = new URL(current.getURL("/")).origin;
              }
            } catch (e) {}
          }
          if (!derived) { return sender; }
          try { sender.origin = derived; return sender; } catch (e) {}
          var copy = {};
          Object.keys(sender).forEach(function (key) { copy[key] = sender[key]; });
          copy.origin = derived;
          return copy;
        }
        rt.onMessage.addListener = function (listener) {
          var wrapped = function (message, sender, sendResponse) {
            var chromeRoot = globalThis.chrome;
            if (chromeRoot && chromeRoot.tabs && typeof chromeRoot.tabs.query === "function" && !chromeRoot.tabs.query.__orbitWrapped) {
              try { ensureTabs(chromeRoot); } catch (e) {}
            }
            var normalized = normalizeSender(sender);
            var tab = normalized && normalized.tab;
            function deliver() {
              var keep;
              try { keep = listener(message, normalized, sendResponse); }
              catch (e) { try { sendResponse(); } catch (e2) {} return; }
              if (keep === true) { return; }
              // An async listener calls sendResponse later. Answering now drops that reply.
              if (keep && typeof keep.then === "function") {
                keep.then(function (value) {
                  if (value !== true) { try { sendResponse(); } catch (e) {} }
                }, function () { try { sendResponse(); } catch (e) {} });
                return;
              }
              try { sendResponse(); } catch (e) {}
            }
            if (!tab || typeof tab.id !== "number") {
              var immediate;
              try { immediate = listener(message, normalized, sendResponse); }
              catch (e) { return; }
              if (immediate && typeof immediate.then === "function") {
                immediate.then(function () {}, function () {});
                return true;
              }
              return immediate;
            }
            if (tabNumberByID[tab.id] != null) {
              var mapped = tabNumberByID[tab.id];
              var knownWebKitId = tab.id;
              if (!tab.url) {
                tab.id = mapped;
                return listener(message, normalized, sendResponse);
              }
              numberForURL(tab.url, knownWebKitId).then(function (shown) {
                tab.id = shown;
                deliver();
              }, function () {
                tab.id = mapped;
                deliver();
              });
              return true;
            }
            tabNumberFor(tab.id, 0, true).then(function (number) {
              var webKitId = tab.id;
              function finish(shown) {
                tab.id = shown;
                deliver();
              }
              if (!tab.url) { finish(number); return; }
              numberForURL(tab.url, webKitId).then(finish, function () { finish(number); });
            }, function () { deliver(); });
            return true;
          };
          listeners.push(wrapped);
          var registered = originalAdd(wrapped);
          if (queuedUntilListener.length) {
            var queued = queuedUntilListener.splice(0);
            queued.forEach(function (item) {
              try { wrapped(item[0], item[1], item[2]); } catch (e) {}
            });
          }
          return registered;
        };
        rt.__orbitDispatch = function (message, sendResponse) {
          listeners.forEach(function (listener) {
            try { listener(message, {}, sendResponse); } catch (e) {}
          });
        };
        originalAdd(function (message, sender, sendResponse) {
          if (message && message.orbitChromeWrapper === true) {
            callNative(message.namespace, message.method, message.args || []).then(function (value) {
              sendResponse(value);
            }, function (error) {
              sendResponse({ __orbitError: String(error && error.message || error) });
            });
            return true;
          }
          // A message can wake the worker before its listener exists. Hold the channel until then.
          if (!listeners.length) {
            queuedUntilListener.push([message, sender, sendResponse]);
            return true;
          }
        });
      }

      try {
        if (nativeConnect) {
          var port = nativeConnect(APP_ID);
          if (port && port.onMessage && typeof port.onMessage.addListener === "function") {
            port.onMessage.addListener(function (message) {
              globalThis.__orbitDeliverChromeEvent(message);
            });
            orbitEventPort = port;
            // The background announces itself once its own listeners exist; a page can hear events at once.
            if (!isBackgroundContext()) { sendPortHello("page"); }
          }
        }
      } catch (e) {}

      var origFetch = globalThis.fetch;
      if (typeof origFetch === "function" && !origFetch.__orbitWrapped) {
        var wrappedFetch = function (input, init) {
          var url = typeof input === "string" ? input : (input && input.url);
          var text = url == null ? "" : String(url);
          if (text.indexOf("chrome-extension://") !== 0 && text.indexOf("webkit-extension://") !== 0) {
            return origFetch.apply(this, arguments);
          }
          return origFetch.apply(this, arguments).catch(function () {
            return invoke("runtime", "getResource", [text]).then(function (payload) {
              if (!payload || payload.error) { throw new Error((payload && payload.error) || "missing"); }
              var binary = atob(payload.body || "");
              var bytes = new Uint8Array(binary.length);
              for (var i = 0; i < binary.length; i++) { bytes[i] = binary.charCodeAt(i); }
              return new Response(bytes, {
                status: 200,
                headers: { "Content-Type": payload.mime || "application/octet-stream" }
              });
            });
          });
        };
        wrappedFetch.__orbitWrapped = true;
        globalThis.fetch = wrappedFetch;
      }
      }
      // WebKit drops HTMLElement.click() when the element has no box (display:none,
      // or a popup that is not on screen). Chrome still runs the listeners.
      (function () {
        if (typeof HTMLElement === "undefined") { return; }
        var proto = HTMLElement.prototype;
        if (!proto.click || proto.click.__orbitWrapped) { return; }
        var nativeClick = proto.click;
        function click() {
          // WebKit does not run listeners for a click on an element with no box.
          // Chrome does. Reveal display:none ancestors for the call, then put them back.
          var restore = [];
          if (this.getClientRects && this.getClientRects().length === 0) {
            var node = this;
            while (node && node.nodeType === 1) {
              if (getComputedStyle(node).display === "none") {
                restore.push([node, node.style.display]);
                node.style.setProperty("display", "block", "important");
              }
              node = node.parentElement;
            }
            if (document.body) { void document.body.offsetWidth; }
          }
          try {
            var result = nativeClick.call(this);
            if (restore.length) {
              this.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, composed: true, view: window }));
            }
            return result;
          } finally {
            for (var i = 0; i < restore.length; i++) {
              restore[i][0].style.display = restore[i][1];
            }
          }
        }
        click.__orbitWrapped = true;
        try {
          Object.defineProperty(proto, "click", { configurable: true, writable: true, value: click });
        } catch (e) {
          try { proto.click = click; } catch (e2) {}
        }
      })();
      function activateOrbitChrome() {
        if (globalThis.__orbitChromeWrapperActive) { return true; }
        var chromeRoot = globalThis.chrome;
        if (!chromeRoot || !chromeRoot.runtime || !chromeRoot.tabs || typeof chromeRoot.tabs.query !== "function") {
          return false;
        }
        globalThis.__orbitChromeWrapperActive = true;
        captureNativeTransport();
        installPortDisconnectError();
        var browserRoot = globalThis.browser || chromeRoot;
        install(chromeRoot);
        if (browserRoot !== chromeRoot) { install(browserRoot); }
        fillExtensionSurface(chromeRoot);
        if (browserRoot !== chromeRoot) { fillExtensionSurface(browserRoot); }
        hookDeclarativeNetRequest(chromeRoot);
        if (browserRoot !== chromeRoot) { hookDeclarativeNetRequest(browserRoot); }
        bindRuntimeBridge();
        scheduleBackgroundReady();
        return true;
      }
      /* ORBIT-WRAPPER-MODULES */
      var bootTries = 0;
      var bootTimer = setInterval(function () {
        bootTries += 1;
        var root = globalThis.chrome;
        if (root) {
          ensureNavigation(root);
          ensureCommands(root);
          ensurePermissions(root);
          ensureCookies(root);
          hookAction(root);
          hookWindows(root);
          tolerateWebRequestFilters(root);
          ensureRuntimeID(root);
          installNativeTabTargets(root);
          if (root.tabs && root.tabs.query && !root.tabs.query.__orbitWrapped) { ensureTabs(root); }
          if (globalThis.browser && globalThis.browser !== root) { installNativeTabTargets(globalThis.browser); }
        }
        activateOrbitChrome();
        installPortDisconnectError();
        if (bootTries > 150) { clearInterval(bootTimer); }
      }, 20);
      activateOrbitChrome();
      installPortDisconnectError();
      } catch (e) {}
    })();
    """#

    struct Configuration {
        /// Optional permissions the user already granted, so their namespaces exist from the first line.
        var grantedOptionalPermissions: [String] = []
        var maxSessionResults = 25
    }

    /// `source` split around the grant list, config, and module marker. The pieces share `source`'s
    /// storage, so installing an extension only allocates the script it writes.
    private static let renderedScriptPieces: (
        beforeConfig: Substring, between: Substring, afterGranted: Substring, afterModules: Substring
    )? = {
        let configToken = "var ORBIT_CONFIG = {};"
        let grantedToken = "var GRANTED = [];"
        let marker = ChromeAPIWrapperModules.marker
        guard
            let configRange = source.range(of: configToken),
            let grantedRange = source.range(of: grantedToken),
            let markerRange = source.range(of: marker),
            configRange.upperBound <= grantedRange.lowerBound,
            grantedRange.upperBound <= markerRange.lowerBound,
            source.range(of: configToken, range: configRange.upperBound..<source.endIndex) == nil,
            source.range(of: grantedToken, range: grantedRange.upperBound..<source.endIndex) == nil,
            source.range(of: marker, range: markerRange.upperBound..<source.endIndex) == nil
        else { return nil }
        return (
            beforeConfig: source[..<configRange.lowerBound],
            between: source[configRange.upperBound..<grantedRange.lowerBound],
            afterGranted: source[grantedRange.upperBound..<markerRange.lowerBound],
            afterModules: source[markerRange.upperBound...]
        )
    }()

    private static func renderedScript(grantedLiteral: String, configJSON: String) -> String {
        let configLine = "var ORBIT_CONFIG = \(configJSON);"
        let grantedLine = "var GRANTED = \(grantedLiteral);"
        guard let pieces = renderedScriptPieces else {
            return source
                .replacingOccurrences(of: "var GRANTED = [];", with: grantedLine)
                .replacingOccurrences(of: "var ORBIT_CONFIG = {};", with: configLine)
                .replacingOccurrences(of: ChromeAPIWrapperModules.marker, with: ChromeAPIWrapperModules.source)
        }
        let modules = ChromeAPIWrapperModules.source
        var script = String()
        script.reserveCapacity(
            pieces.beforeConfig.count + configLine.count + pieces.between.count + grantedLine.count
                + pieces.afterGranted.count + modules.count + pieces.afterModules.count
        )
        script += pieces.beforeConfig
        script += configLine
        script += pieces.between
        script += grantedLine
        script += pieces.afterGranted
        script += modules
        script += pieces.afterModules
        return script
    }

    static func install(in directory: URL, configuration: Configuration = Configuration()) throws {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        guard var manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if var scripts = manifest["content_scripts"] as? [[String: Any]] {
            for index in scripts.indices {
                var files = scripts[index]["js"] as? [String] ?? []
                if !files.contains(fileName) { files.insert(fileName, at: 0) }
                scripts[index]["js"] = files
            }
            manifest["content_scripts"] = scripts
        }
        if var background = manifest["background"] as? [String: Any] {
            if var files = background["scripts"] as? [String], !files.contains(fileName) {
                files.insert(fileName, at: 0)
                background["scripts"] = files
            }
            if let worker = background["service_worker"] as? String, worker != backgroundEntryName {
                let module = (background["type"] as? String) == "module"
                let entry = module
                    ? "import \(JavaScriptLiteral.string(moduleSpecifier(fileName)));\nimport \(JavaScriptLiteral.string(moduleSpecifier(worker)));\n"
                    : "importScripts(\(JavaScriptLiteral.string(fileName)));\nimportScripts(\(JavaScriptLiteral.string(worker)));\n"
                if !module { background.removeValue(forKey: "type") }
                try entry.write(to: directory.appendingPathComponent(backgroundEntryName), atomically: true, encoding: .utf8)
                background["service_worker"] = backgroundEntryName
            }
            manifest["background"] = background
        }
        // The manifest's own permissions, untouched: Orbit's transport is granted on the context instead.
        let permissions = manifest["permissions"] as? [String] ?? []
        let wrapped = ChromeAPISurfaceInventory.wrappedPermissions
        // WebKit refuses to load a manifest whose description is missing or blank. Chrome does not.
        let existingDescription = (manifest["description"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if existingDescription.isEmpty {
            let name = (manifest["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            manifest["description"] = name.isEmpty ? "Extension" : name
        }
        // `_execute_action: {}` is a valid Chrome command. WebKit rejects it as empty.
        if var commands = manifest["commands"] as? [String: Any] {
            for (name, value) in commands {
                var entry = value as? [String: Any] ?? [:]
                let description = (entry["description"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if description.isEmpty {
                    entry["description"] = "Activate the extension"
                }
                commands[name] = entry
            }
            manifest["commands"] = commands
        }
        // Sorted and written only on change, so a reload of unchanged bytes leaves the bundle unchanged.
        let rewritten = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        if rewritten != data { try rewritten.write(to: manifestURL, options: .atomic) }
        var granted: [String] = []
        for name in permissions + configuration.grantedOptionalPermissions where wrapped.contains(name) && !granted.contains(name) {
            granted.append(name)
        }
        let grantedLiteral = "[\(granted.map { JavaScriptLiteral.string($0) }.joined(separator: ", "))]"
        let config: [String: Any] = ["maxSessionResults": configuration.maxSessionResults]
        let configData = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        let script = renderedScript(
            grantedLiteral: grantedLiteral,
            configJSON: String(decoding: configData, as: UTF8.self)
        )
        let scriptURL = directory.appendingPathComponent(fileName)
        if (try? String(contentsOf: scriptURL, encoding: .utf8)) != script {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        }
        try injectWrapper(intoHTMLIn: directory)
    }

    /// Popups are extension pages, not content scripts, so the wrapper has to be a script tag.
    private static func injectWrapper(intoHTMLIn directory: URL) throws {
        let root = directory.standardizedFileURL
        let scriptFile = root.appendingPathComponent(fileName)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        for case let file as URL in enumerator {
            guard file.pathExtension.lowercased() == "html" else { continue }
            var text = try String(contentsOf: file, encoding: .utf8)
            guard !text.contains(fileName) else { continue }
            let relative = relativePath(from: file.deletingLastPathComponent().standardizedFileURL, to: scriptFile)
            let tag = "<script src=\"\(relative)\"></script>"
            if let range = text.range(of: "<head>", options: .caseInsensitive) {
                text.insert(contentsOf: tag, at: range.upperBound)
            } else if let range = text.range(of: "<head ", options: .caseInsensitive),
                      let end = text[range.lowerBound...].firstIndex(of: ">") {
                text.insert(contentsOf: tag, at: text.index(after: end))
            } else {
                text = tag + text
            }
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    private static func relativePath(from base: URL, to target: URL) -> String {
        let from = base.standardizedFileURL.pathComponents
        let to = target.standardizedFileURL.pathComponents
        var shared = 0
        while shared < from.count, shared < to.count, from[shared] == to[shared] { shared += 1 }
        let ups = Array(repeating: "..", count: max(0, from.count - shared))
        return (ups + to[shared...]).joined(separator: "/")
    }

    private static func moduleSpecifier(_ path: String) -> String {
        if path.hasPrefix("./") || path.hasPrefix("../") || path.hasPrefix("/") { return path }
        return "./" + path
    }
}

enum JavaScriptLiteral {
    static func string(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return text
    }
}
