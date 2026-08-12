import Foundation

/// Shims `chrome.webstorePrivate`/`chrome.management` at document start. Also exposed
/// as `window.__orbitWebStorePrivate`/`__orbitManagement`, since Chromium's own native
/// accessor silently ignores writes to `chrome.webstorePrivate` on the real store origin.
public enum WebStorePrivateBridgeScript {

    /// Must match the engine's own script channel name exactly.
    public static let channelName = "orbitWebStorePrivate"

    public static let scriptID = UUID(uuidString: "8F3C2E71-4A5D-4B9E-9C1A-2D6E8F0B3C77")!

    public static let chromiumPostExpression =
        "__orbitPost('\(channelName)', JSON.stringify(message))"

    public static func source(postExpression: String) -> String {
        """
        (function() {
          // Own idempotency flag, not "chrome.webstorePrivate already exists": the real one
          // hangs forever on beginInstallWithManifest3 and must be overridden, never feature-detected.
          if (window.__orbitWebStorePrivateShimInstalled) { return; }
          window.__orbitWebStorePrivateShimInstalled = true;

          // Captured now, before the engine deletes the global binding.
          var __orbitPost = window.__orbitPostMessage;
          if (typeof __orbitPost !== 'function') { return; }

          function post(message) {
            try { \(postExpression); } catch (e) {}
          }

          var chrome = window.chrome = window.chrome || {};
          chrome.runtime = chrome.runtime || {};
          if (typeof chrome.runtime.getManifest !== 'function') {
            chrome.runtime.getManifest = function() { return {}; };
          }

          var reqCounter = 0;
          function nextRequestId() {
            reqCounter += 1;
            return 'req-' + Date.now().toString(36) + '-' + reqCounter.toString(36) +
              '-' + Math.random().toString(36).slice(2, 8);
          }

          var pending = new Map();

          function deliver(payload, callback) {
            try {
              if (payload && payload.ok === true) {
                delete chrome.runtime.lastError;
                if (typeof callback === 'function') { callback(payload.result); }
              } else {
                var message = (payload && payload.error && payload.error.message) || 'Unknown error';
                chrome.runtime.lastError = { message: message };
                if (typeof callback === 'function') { callback(undefined); }
              }
            } catch (e) {
            } finally {
              delete chrome.runtime.lastError;
            }
          }

          function invoke(api, method, args, callback) {
            var requestId = nextRequestId();
            pending.set(requestId, function(payload) { deliver(payload, callback); });
            post({ requestId: requestId, api: api, method: method, args: args });
          }

          // Event plumbing: native pushes events through __orbitRespond_<channel> too, using
          // a requestId of 'evt-<eventName>' instead of a per-call one.
          var EVENT_PREFIX = 'evt-';

          function makeEvent(name) {
            var listeners = [];
            return {
              addListener: function(fn) {
                if (typeof fn === 'function' && listeners.indexOf(fn) === -1) { listeners.push(fn); }
              },
              removeListener: function(fn) {
                var i = listeners.indexOf(fn);
                if (i !== -1) { listeners.splice(i, 1); }
              },
              hasListener: function(fn) { return listeners.indexOf(fn) !== -1; },
              _dispatch: function(args) {
                listeners.slice().forEach(function(fn) {
                  try { fn.apply(null, args); } catch (e) {}
                });
              }
            };
          }

          var managementEvents = {
            onInstalled: makeEvent('onInstalled'),
            onUninstalled: makeEvent('onUninstalled'),
            onEnabled: makeEvent('onEnabled'),
            onDisabled: makeEvent('onDisabled')
          };

          window.__orbitRespond_\(channelName) = function(requestId, payload) {
            try {
              if (typeof requestId !== 'string') { return; }
              if (requestId.indexOf(EVENT_PREFIX) === 0) {
                var event = managementEvents[requestId.slice(EVENT_PREFIX.length)];
                if (!event) { return; }
                var args = (payload && payload.ok === true)
                  ? (Array.isArray(payload.result) ? payload.result : [payload.result])
                  : [];
                event._dispatch(args);
                return;
              }
              var entry = pending.get(requestId);
              if (!entry) { return; }
              pending.delete(requestId);
              entry(payload);
            } catch (e) {}
          };

          // MARK: webstorePrivate

          var webstorePrivateAPI = {
            beginInstallWithManifest3: function(details, callback) {
              invoke('webstorePrivate', 'beginInstallWithManifest3', [details], callback);
            },
            completeInstall: function(id, callback) {
              invoke('webstorePrivate', 'completeInstall', [id], callback);
            },
            getExtensionStatus: function(id, manifestOrCallback, maybeCallback) {
              var manifest = null, callback = manifestOrCallback;
              if (typeof manifestOrCallback !== 'function') {
                manifest = manifestOrCallback;
                callback = maybeCallback;
              }
              invoke('webstorePrivate', 'getExtensionStatus', [id, manifest], callback);
            },
            getBrowserLogin: function(callback) {
              invoke('webstorePrivate', 'getBrowserLogin', [], callback);
            },
            getStoreLogin: function(callback) {
              invoke('webstorePrivate', 'getStoreLogin', [], callback);
            },
            getWebGLStatus: function(callback) {
              invoke('webstorePrivate', 'getWebGLStatus', [], callback);
            },
            getIsLauncherEnabled: function(callback) {
              invoke('webstorePrivate', 'getIsLauncherEnabled', [], callback);
            },
            isInIncognitoMode: function(callback) {
              invoke('webstorePrivate', 'isInIncognitoMode', [], callback);
            },
            isPendingCustodianApproval: function(id, callback) {
              invoke('webstorePrivate', 'isPendingCustodianApproval', [id], callback);
            },
            getReferrerChain: function(callback) {
              invoke('webstorePrivate', 'getReferrerChain', [], callback);
            },
            getFullChromeVersion: function(callback) {
              invoke('webstorePrivate', 'getFullChromeVersion', [], callback);
            },
            getMV2DeprecationStatus: function(callback) {
              invoke('webstorePrivate', 'getMV2DeprecationStatus', [], callback);
            }
          };
          chrome.webstorePrivate = webstorePrivateAPI;
          window.__orbitWebStorePrivate = webstorePrivateAPI;

          // MARK: management

          var managementAPI = {
            getAll: function(callback) {
              invoke('management', 'getAll', [], callback);
            },
            get: function(id, callback) {
              invoke('management', 'get', [id], callback);
            },
            setEnabled: function(id, enabled, callback) {
              invoke('management', 'setEnabled', [id, enabled], callback);
            },
            uninstall: function(id, optionsOrCallback, maybeCallback) {
              var options = null, callback = optionsOrCallback;
              if (typeof optionsOrCallback !== 'function') {
                options = optionsOrCallback;
                callback = maybeCallback;
              }
              invoke('management', 'uninstall', [id, options], callback);
            },
            onInstalled: managementEvents.onInstalled,
            onUninstalled: managementEvents.onUninstalled,
            onEnabled: managementEvents.onEnabled,
            onDisabled: managementEvents.onDisabled
          };
          chrome.management = managementAPI;
          window.__orbitManagement = managementAPI;
        })();
        """
    }

    /// Delivers one `handle(payload:contents:)` answer back to the waiting
    /// page-side callback. `resultJSON` is already the `{"ok":…}` envelope.
    public static func responseScript(requestID: String, resultJSON: String) -> String {
        let quotedID = (try? JSONSerialization.data(withJSONObject: [requestID]))
            .flatMap { String(data: $0, encoding: .utf8) }
            .map { String($0.dropFirst().dropLast()) } ?? "\"\""
        return "(function(){var r=window.__orbitRespond_\(channelName);" +
            "if(typeof r==='function'){r(\(quotedID),\(resultJSON));}})();"
    }

    /// Pushes a chrome.management event through the same __orbitRespond_<channel> global per-call responses use, with the evt-<name> requestId reserved for events; resultJSON must already be {"ok":true,"result":<single listener argument>}.
    public static func managementEventScript(name: String, resultJSON: String) -> String {
        "(function(){var r=window.__orbitRespond_\(channelName);" +
            "if(typeof r==='function'){r('evt-\(name)',\(resultJSON));}})();"
    }

    /// Installed once per session, not per-tab: must keep working across navigations.
    public static var chromiumUserScript: UserScript {
        UserScript(
            id: scriptID,
            kind: .javaScript,
            source: source(postExpression: chromiumPostExpression),
            injectionTime: .documentStart,
            matchPatterns: [
                "https://chromewebstore.google.com/*",
                "https://chrome.google.com/webstore/*"
            ],
            allFrames: false
        )
    }
}
