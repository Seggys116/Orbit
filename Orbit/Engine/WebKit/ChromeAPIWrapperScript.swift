import Foundation

/// Script prepended to every loaded extension. It fills chrome.* namespaces
/// WebKit does not implement and forwards them through runtime.sendNativeMessage.
enum ChromeAPIWrapperScript {
    static let fileName = "orbit-chrome-wrapper.js"
    static let backgroundEntryName = "orbit-background-entry.js"

    static let source = #"""
    (function () {
      if (globalThis.__orbitChromeWrapperInstalled) { return; }
      globalThis.__orbitChromeWrapperInstalled = true;
      var APP_ID = "com.orbit.chrome";
      var NAMESPACES = {
        bookmarks: ["getTree", "get", "getChildren", "getSubTree", "search", "create", "move", "update", "remove", "removeTree"],
        downloads: ["search", "download", "pause", "resume", "cancel", "erase", "open", "show", "removeFile", "showDefaultFolder"],
        history: ["search", "getVisits", "addUrl", "deleteUrl", "deleteRange", "deleteAll"],
        sessions: ["getRecentlyClosed", "restore"],
        search: ["query"],
        management: ["getAll", "get", "getSelf", "setEnabled", "uninstall"]
      };

      function runtime() {
        var root = globalThis.browser || globalThis.chrome;
        return root && root.runtime;
      }

      function invoke(namespace, method, args) {
        var rt = runtime();
        var message = { orbitChromeAPI: true, namespace: namespace, method: method, args: args };
        if (rt && typeof rt.sendNativeMessage === "function") {
          return rt.sendNativeMessage(APP_ID, message);
        }
        if (rt && typeof rt.sendMessage === "function") {
          return new Promise(function (resolve, reject) {
            rt.sendMessage({ orbitChromeWrapper: true, namespace: namespace, method: method, args: args }, function (reply) {
              var err = rt.lastError;
              if (err) { reject(new Error(err.message || String(err))); return; }
              if (reply && reply.__orbitError) { reject(new Error(reply.__orbitError)); return; }
              resolve(reply);
            });
          });
        }
        return Promise.reject(new Error("Orbit chrome wrapper has no runtime port"));
      }

      function wrap(namespace, method) {
        return function () {
          var args = Array.prototype.slice.call(arguments);
          var callback = null;
          if (args.length && typeof args[args.length - 1] === "function") { callback = args.pop(); }
          var promise = invoke(namespace, method, args);
          if (callback) {
            promise.then(function (value) { callback(value); }, function (error) {
              var rt = runtime();
              if (rt) { rt.lastError = { message: String(error && error.message || error) }; }
              callback();
            });
            return undefined;
          }
          return promise;
        };
      }

      function install(root) {
        if (!root) { return; }
        Object.keys(NAMESPACES).forEach(function (namespace) {
          var api = root[namespace] || {};
          NAMESPACES[namespace].forEach(function (method) {
            if (typeof api[method] !== "function") { api[method] = wrap(namespace, method); }
          });
          root[namespace] = api;
        });
      }

      var chromeRoot = globalThis.chrome = globalThis.chrome || {};
      var browserRoot = globalThis.browser = globalThis.browser || chromeRoot;
      install(chromeRoot);
      if (browserRoot !== chromeRoot) { install(browserRoot); }

      var rt = runtime();
      if (rt && rt.onMessage && typeof rt.onMessage.addListener === "function") {
        var listeners = [];
        var originalAdd = rt.onMessage.addListener.bind(rt.onMessage);
        rt.onMessage.addListener = function (listener) {
          listeners.push(listener);
          return originalAdd(listener);
        };
        rt.__orbitDispatch = function (message, sendResponse) {
          listeners.forEach(function (listener) {
            try { listener(message, {}, sendResponse); } catch (e) {}
          });
        };
        rt.onMessage.addListener(function (message, sender, sendResponse) {
          if (!message || message.orbitChromeWrapper !== true) { return; }
          invoke(message.namespace, message.method, message.args || []).then(function (value) {
            sendResponse(value);
          }, function (error) {
            sendResponse({ __orbitError: String(error && error.message || error) });
          });
          return true;
        });
      }
    })();
    """#

    static func install(in directory: URL) throws {
        try source.write(to: directory.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
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
        var permissions = manifest["permissions"] as? [String] ?? []
        let wrapped: Set<String> = ["bookmarks", "downloads", "history", "sessions", "management", "search"]
        if !Set(permissions).isDisjoint(with: wrapped), !permissions.contains("nativeMessaging") {
            permissions.append("nativeMessaging")
        }
        manifest["permissions"] = permissions
        let rewritten = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
        try rewritten.write(to: manifestURL, options: .atomic)
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
