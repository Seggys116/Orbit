extension OrbitInspectAgent {
    static let applicationSource = ##"""
      // ----- application (app_) -----

      var app_PAGE_SIZE = 50;

      // ---- Helpers ----

      function app_storageEntries(storage) {
        var entries = [];
        try {
          for (var i = 0; i < storage.length; i++) {
            var k = storage.key(i);
            if (k === null) continue;
            entries.push({ key: k, value: storage.getItem(k) || "" });
          }
        } catch (err) {}
        return entries;
      }

      // Serializes an IDB key to JSON; a Date becomes { __idbDate: timestamp }.
      function app_keyToJSON(key) {
        if (key instanceof Date) return { __idbDate: key.getTime() };
        if (Array.isArray(key)) return key.map(app_keyToJSON);
        return key;
      }

      function app_keyFromJSON(v) {
        if (v === null || v === undefined) return v;
        if (v && typeof v === "object" && v.__idbDate !== undefined) return new Date(v.__idbDate);
        if (Array.isArray(v)) return v.map(app_keyFromJSON);
        return v;
      }

      function app_idbKeyToString(key) {
        if (key === undefined || key === null) return "";
        if (key instanceof Date) return key.toISOString();
        if (Array.isArray(key)) return "[" + key.map(app_idbKeyToString).join(", ") + "]";
        return String(key);
      }

      function app_idbValuePreview(value) {
        try {
          if (value === null || value === undefined) return String(value);
          if (value instanceof ArrayBuffer) return "[ArrayBuffer " + value.byteLength + "B]";
          if (ArrayBuffer.isView && ArrayBuffer.isView(value)) return "[" + value.constructor.name + " " + (value.byteLength || 0) + "B]";
          if (value instanceof Blob) return "[Blob " + value.size + "B type=" + (value.type || "") + "]";
          if (value instanceof Date) return value.toISOString();
          if (value instanceof Map) return "[Map " + value.size + " entries]";
          if (value instanceof Set) return "[Set " + value.size + " values]";
          if (Array.isArray(value)) {
            var s = JSON.stringify(value.slice(0, 10));
            return value.length > 10 ? s.slice(0, -1) + ", …]" : s;
          }
          if (typeof value === "object") {
            try {
              var str = JSON.stringify(value, null, 0);
              return str && str.length > 300 ? str.slice(0, 300) + "…" : (str || "[object]");
            } catch (e) { return "[object]"; }
          }
          return String(value);
        } catch (err) { return "[unparseable]"; }
      }

      // ---- localStorage / sessionStorage ----

      ops["app.getLocalStorage"] = function() {
        try {
          post({ t: "app.localStorageData", origin: String(location.origin), entries: app_storageEntries(localStorage) });
        } catch (err) {
          post({ t: "app.error", section: "localStorage", message: String(err) });
        }
      };

      ops["app.getSessionStorage"] = function() {
        try {
          post({ t: "app.sessionStorageData", origin: String(location.origin), entries: app_storageEntries(sessionStorage) });
        } catch (err) {
          post({ t: "app.error", section: "sessionStorage", message: String(err) });
        }
      };

      ops["app.setStorage"] = function(message) {
        try {
          var storage = message.stype === "session" ? sessionStorage : localStorage;
          storage.setItem(message.key, message.value);
        } catch (err) {}
      };

      ops["app.removeStorage"] = function(message) {
        try {
          var storage = message.stype === "session" ? sessionStorage : localStorage;
          storage.removeItem(message.key);
        } catch (err) {}
      };

      ops["app.clearStorage"] = function(message) {
        try {
          var storage = message.stype === "session" ? sessionStorage : localStorage;
          storage.clear();
        } catch (err) {}
      };

      // The storage event fires in OTHER frames when a same-origin frame changes storage.
      inits.push(function() {
        try {
          window.addEventListener("storage", function(e) {
            post({ t: "app.storageChanged",
              key: e.key || "",
              newValue: e.newValue,
              oldValue: e.oldValue,
              url: e.url || String(location.href)
            });
          });
        } catch (err) {}
      });

      // ---- IndexedDB ----

      ops["app.idbListDatabases"] = function() {
        if (typeof indexedDB === "undefined") {
          post({ t: "app.error", section: "indexedDB", message: "IndexedDB is not available in this context" });
          return;
        }
        if (typeof indexedDB.databases !== "function") {
          post({ t: "app.error", section: "indexedDB", message: "indexedDB.databases() is not supported (private browsing or unsupported environment)" });
          return;
        }
        indexedDB.databases().then(function(dbs) {
          post({ t: "app.idbDatabases", databases: dbs.map(function(db) {
            return { name: db.name || "", version: db.version || 0 };
          })});
        }).catch(function(e) {
          post({ t: "app.error", section: "indexedDB", message: String(e) });
        });
      };

      ops["app.idbGetStoreInfo"] = function(message) {
        if (typeof indexedDB === "undefined") { return; }
        var dbName = String(message.db || "");
        var req = indexedDB.open(dbName);
        req.onupgradeneeded = function(e) {
          // DB doesn't exist at this version - abort immediately to avoid creating it
          try { e.target.transaction.abort(); } catch (err) {}
        };
        req.onerror = function(e) {
          var msg = e.target.error ? e.target.error.message : "unknown error";
          if (e.target.error && e.target.error.name === "AbortError") {
            post({ t: "app.error", section: "indexedDB", message: "Database \"" + dbName + "\" does not exist" });
          } else {
            post({ t: "app.error", section: "indexedDB", message: "Could not open \"" + dbName + "\": " + msg });
          }
        };
        req.onsuccess = function(e) {
          var db = e.target.result;
          try {
            var names = Array.prototype.slice.call(db.objectStoreNames);
            if (names.length === 0) {
              db.close();
              post({ t: "app.idbStoreInfo", db: dbName, stores: [] });
              return;
            }
            var tx = db.transaction(names, "readonly");
            var stores = [];
            var pending = names.length;
            names.forEach(function(name) {
              try {
                var store = tx.objectStore(name);
                var indexes = Array.prototype.slice.call(store.indexNames).map(function(idxName) {
                  try {
                    var idx = store.index(idxName);
                    return { name: idxName, keyPath: JSON.stringify(idx.keyPath), unique: idx.unique, multiEntry: idx.multiEntry };
                  } catch (err) { return { name: idxName, keyPath: "", unique: false, multiEntry: false }; }
                });
                var storeInfo = { name: name, keyPath: JSON.stringify(store.keyPath), autoIncrement: store.autoIncrement, indexes: indexes, count: 0 };
                var countReq = store.count();
                countReq.onsuccess = function(ce) {
                  storeInfo.count = ce.target.result;
                  stores.push(storeInfo);
                  pending--;
                  if (pending === 0) { db.close(); post({ t: "app.idbStoreInfo", db: dbName, stores: stores }); }
                };
                countReq.onerror = function() {
                  stores.push(storeInfo);
                  pending--;
                  if (pending === 0) { db.close(); post({ t: "app.idbStoreInfo", db: dbName, stores: stores }); }
                };
              } catch (err) {
                pending--;
                if (pending === 0) { db.close(); post({ t: "app.idbStoreInfo", db: dbName, stores: stores }); }
              }
            });
          } catch (err) {
            db.close();
            post({ t: "app.error", section: "indexedDB", message: String(err) });
          }
        };
      };

      ops["app.idbGetRecords"] = function(message) {
        if (typeof indexedDB === "undefined") { return; }
        var dbName = String(message.db || "");
        var storeName = String(message.store || "");
        var page = message.page || 0;
        var indexName = message.index || null;
        var direction = message.direction || "next";
        var keyRangeSpec = message.keyRangeSpec || null;
        var req = indexedDB.open(dbName);
        req.onupgradeneeded = function(e) { try { e.target.transaction.abort(); } catch (err) {} };
        req.onerror = function(e) {
          post({ t: "app.error", section: "indexedDB",
            message: "Could not open \"" + dbName + "\": " + (e.target.error ? e.target.error.message : "unknown") });
        };
        req.onsuccess = function(e) {
          var db = e.target.result;
          try {
            var tx = db.transaction([storeName], "readonly");
            var store = tx.objectStore(storeName);
            var target = indexName ? store.index(indexName) : store;
            // Build key range
            var keyRange = null;
            if (keyRangeSpec) {
              try {
                switch (keyRangeSpec.type) {
                  case "only":  keyRange = IDBKeyRange.only(keyRangeSpec.lower); break;
                  case "lower": keyRange = IDBKeyRange.lowerBound(keyRangeSpec.lower, keyRangeSpec.lowerOpen || false); break;
                  case "upper": keyRange = IDBKeyRange.upperBound(keyRangeSpec.upper, keyRangeSpec.upperOpen || false); break;
                  case "bound": keyRange = IDBKeyRange.bound(keyRangeSpec.lower, keyRangeSpec.upper,
                    keyRangeSpec.lowerOpen || false, keyRangeSpec.upperOpen || false); break;
                }
              } catch (err) { keyRange = null; }
            }
            var countTotal = 0;
            var countReq = target.count(keyRange);
            countReq.onsuccess = function(ce) { countTotal = ce.target.result; };
            var records = [];
            var skipRemaining = page * app_PAGE_SIZE;
            var collected = 0;
            var cursorReq = target.openCursor(keyRange, direction);
            cursorReq.onsuccess = function(ce) {
              var cursor = ce.target.result;
              if (!cursor) {
                db.close();
                post({ t: "app.idbRecords", db: dbName, store: storeName, page: page,
                  total: countTotal, records: records });
                return;
              }
              if (skipRemaining > 0) {
                var skip = skipRemaining;
                skipRemaining = 0;
                cursor.advance(skip);
                return;
              }
              if (collected >= app_PAGE_SIZE) {
                db.close();
                post({ t: "app.idbRecords", db: dbName, store: storeName, page: page,
                  total: countTotal, records: records });
                return;
              }
              records.push({
                keyDisplay: app_idbKeyToString(cursor.key),
                primaryKeyDisplay: app_idbKeyToString(cursor.primaryKey),
                keyJSON: JSON.stringify(app_keyToJSON(cursor.key)),
                primaryKeyJSON: JSON.stringify(app_keyToJSON(cursor.primaryKey)),
                value: app_idbValuePreview(cursor.value)
              });
              collected++;
              cursor.continue();
            };
            cursorReq.onerror = function(ce) {
              db.close();
              post({ t: "app.error", section: "indexedDB",
                message: "Cursor error: " + (ce.target.error ? ce.target.error.message : "unknown") });
            };
          } catch (err) {
            db.close();
            post({ t: "app.error", section: "indexedDB", message: String(err) });
          }
        };
      };

      ops["app.idbDeleteRecord"] = function(message) {
        if (typeof indexedDB === "undefined") { return; }
        var dbName = String(message.db || "");
        var storeName = String(message.store || "");
        var key = app_keyFromJSON(JSON.parse(message.keyJSON));
        var req = indexedDB.open(dbName);
        req.onupgradeneeded = function(e) { try { e.target.transaction.abort(); } catch (err) {} };
        req.onsuccess = function(e) {
          var db = e.target.result;
          try {
            var tx = db.transaction([storeName], "readwrite");
            tx.objectStore(storeName).delete(key);
            tx.oncomplete = function() { db.close(); };
            tx.onerror = function() { db.close(); };
          } catch (err) { db.close(); }
        };
      };

      ops["app.idbClearStore"] = function(message) {
        if (typeof indexedDB === "undefined") { return; }
        var dbName = String(message.db || "");
        var storeName = String(message.store || "");
        var req = indexedDB.open(dbName);
        req.onupgradeneeded = function(e) { try { e.target.transaction.abort(); } catch (err) {} };
        req.onsuccess = function(e) {
          var db = e.target.result;
          try {
            var tx = db.transaction([storeName], "readwrite");
            tx.objectStore(storeName).clear();
            tx.oncomplete = function() { db.close(); };
            tx.onerror = function() { db.close(); };
          } catch (err) { db.close(); }
        };
      };

      ops["app.idbPutRecord"] = function(message) {
        if (typeof indexedDB === "undefined") { return; }
        var dbName = String(message.db || "");
        var storeName = String(message.store || "");
        var req = indexedDB.open(dbName);
        req.onupgradeneeded = function(e) { try { e.target.transaction.abort(); } catch (err) {} };
        req.onsuccess = function(e) {
          var db = e.target.result;
          try {
            var value;
            try { value = JSON.parse(message.valueJSON); } catch (err) {
              post({ t: "app.error", section: "indexedDB", message: "Invalid JSON: " + err.message });
              db.close(); return;
            }
            var tx = db.transaction([storeName], "readwrite");
            var putReq = tx.objectStore(storeName).put(value);
            putReq.onerror = function(pe) {
              post({ t: "app.error", section: "indexedDB",
                message: "Put failed: " + (pe.target.error ? pe.target.error.message : "unknown") });
            };
            tx.oncomplete = function() { db.close(); };
            tx.onerror = function() { db.close(); };
          } catch (err) {
            db.close();
            post({ t: "app.error", section: "indexedDB", message: String(err) });
          }
        };
      };

      ops["app.idbDeleteDatabase"] = function(message) {
        if (typeof indexedDB === "undefined") { return; }
        indexedDB.deleteDatabase(String(message.name || ""));
      };

      // ---- Cache Storage ----

      ops["app.listCaches"] = function() {
        if (typeof caches === "undefined" || typeof caches.keys !== "function") {
          post({ t: "app.error", section: "cacheStorage", message: "Cache Storage is not available in this context" });
          return;
        }
        caches.keys().then(function(names) {
          post({ t: "app.cacheNames", names: names });
        }).catch(function(e) {
          post({ t: "app.error", section: "cacheStorage", message: String(e) });
        });
      };

      ops["app.getCacheEntries"] = function(message) {
        if (typeof caches === "undefined") { return; }
        var cacheName = String(message.name || "");
        caches.open(cacheName).then(function(cache) {
          return cache.keys().then(function(requests) {
            var limited = requests.slice(0, 200);
            return Promise.all(limited.map(function(req) {
              return cache.match(req).then(function(response) {
                if (!response) return { url: req.url, status: 0, contentType: "", size: 0 };
                var status = response.status;
                var ct = response.headers.get("content-type") || "";
                return response.clone().blob().then(function(blob) {
                  return { url: req.url, status: status, contentType: ct, size: blob.size };
                }).catch(function() {
                  return { url: req.url, status: status, contentType: ct, size: -1 };
                });
              }).catch(function() {
                return { url: req.url, status: 0, contentType: "", size: 0 };
              });
            }));
          });
        }).then(function(entries) {
          post({ t: "app.cacheEntries", name: cacheName, entries: entries });
        }).catch(function(e) {
          post({ t: "app.error", section: "cacheStorage", message: String(e) });
        });
      };

      ops["app.deleteCacheEntry"] = function(message) {
        if (typeof caches === "undefined") { return; }
        caches.open(String(message.cacheName || "")).then(function(cache) {
          return cache.delete(String(message.url || ""));
        }).catch(function() {});
      };

      ops["app.deleteCache"] = function(message) {
        if (typeof caches === "undefined") { return; }
        caches.delete(String(message.name || "")).catch(function() {});
      };

      // ---- Service Workers ----

      ops["app.getServiceWorkers"] = function() {
        if (typeof navigator === "undefined" || typeof navigator.serviceWorker === "undefined") {
          post({ t: "app.error", section: "serviceWorkers",
            message: "Service Workers are not available in this context (requires HTTPS or localhost)" });
          return;
        }
        navigator.serviceWorker.getRegistrations().then(function(regs) {
          function workerInfo(w) { return w ? { state: w.state, scriptURL: w.scriptURL } : null; }
          var items = regs.map(function(reg) {
            var scriptURL = (reg.active && reg.active.scriptURL) ||
              (reg.installing && reg.installing.scriptURL) ||
              (reg.waiting && reg.waiting.scriptURL) || "";
            return {
              scope: reg.scope,
              scriptURL: scriptURL,
              updateViaCache: reg.updateViaCache || "",
              installing: workerInfo(reg.installing),
              waiting: workerInfo(reg.waiting),
              active: workerInfo(reg.active)
            };
          });
          post({ t: "app.serviceWorkers", registrations: items });
        }).catch(function(e) {
          post({ t: "app.error", section: "serviceWorkers", message: String(e) });
        });
      };

      ops["app.swUpdate"] = function(message) {
        if (typeof navigator === "undefined" || typeof navigator.serviceWorker === "undefined") { return; }
        navigator.serviceWorker.getRegistrations().then(function(regs) {
          regs.forEach(function(reg) {
            if (reg.scope === message.scope) { reg.update().catch(function() {}); }
          });
        }).catch(function() {});
      };

      ops["app.swUnregister"] = function(message) {
        if (typeof navigator === "undefined" || typeof navigator.serviceWorker === "undefined") { return; }
        navigator.serviceWorker.getRegistrations().then(function(regs) {
          regs.forEach(function(reg) {
            if (reg.scope === message.scope) { reg.unregister().catch(function() {}); }
          });
        }).catch(function() {});
      };

      ops["app.swSkipWaiting"] = function(message) {
        if (typeof navigator === "undefined" || typeof navigator.serviceWorker === "undefined") { return; }
        navigator.serviceWorker.getRegistrations().then(function(regs) {
          regs.forEach(function(reg) {
            if (reg.scope === message.scope && reg.waiting) {
              reg.waiting.postMessage({ type: "SKIP_WAITING" });
            }
          });
        }).catch(function() {});
      };

      // ---- Manifest ----

      ops["app.getManifest"] = function() {
        try {
          var link = document.querySelector("link[rel~='manifest']");
          if (!link || !link.href) {
            post({ t: "app.error", section: "manifest", message: "No <link rel=\"manifest\"> found on this page" });
            return;
          }
          var manifestURL = String(link.href);
          fetch(manifestURL, { credentials: "same-origin" }).then(function(response) {
            if (!response.ok) throw new Error("HTTP " + response.status + " " + response.statusText);
            return response.text();
          }).then(function(text) {
            post({ t: "app.manifest", url: manifestURL, json: text });
          }).catch(function(e) {
            post({ t: "app.error", section: "manifest", message: String(e) });
          });
        } catch (err) {
          post({ t: "app.error", section: "manifest", message: String(err) });
        }
      };

      // ---- Storage quota ----

      ops["app.getQuota"] = function() {
        if (typeof navigator === "undefined" || typeof navigator.storage === "undefined") {
          post({ t: "app.error", section: "quota", message: "navigator.storage API is not available" });
          return;
        }
        var estimateP = navigator.storage.estimate ? navigator.storage.estimate() : Promise.resolve({});
        var persistedP = navigator.storage.persisted ? navigator.storage.persisted() : Promise.resolve(false);
        Promise.all([estimateP, persistedP]).then(function(results) {
          var est = results[0] || {};
          post({ t: "app.quota",
            usage: est.usage || 0,
            quota: est.quota || 0,
            isPersisted: results[1] || false,
            usageDetails: est.usageDetails || {}
          });
        }).catch(function(e) {
          post({ t: "app.error", section: "quota", message: String(e) });
        });
      };

      ops["app.requestPersist"] = function() {
        if (typeof navigator === "undefined" || typeof navigator.storage === "undefined" ||
            typeof navigator.storage.persist !== "function") { return; }
        navigator.storage.persist().then(function(granted) {
          // Re-fetch quota to get updated persisted state
          ops["app.getQuota"]();
        }).catch(function() {});
      };

      // ---- Frames ----

      ops["app.getFrames"] = function() {
        var frames = [];
        function collectFrame(win, depth) {
          try {
            frames.push({
              url: String(win.location.href || ""),
              origin: String(win.location.origin || "null"),
              name: String(win.name || ""),
              isSecureContext: win.isSecureContext === true,
              isCrossOriginIsolated: win.crossOriginIsolated === true,
              depth: depth
            });
            for (var i = 0; i < win.frames.length; i++) {
              try { collectFrame(win.frames[i], depth + 1); } catch (err) {
                frames.push({ url: "cross-origin", origin: "cross-origin", name: "",
                  isSecureContext: false, isCrossOriginIsolated: false, depth: depth + 1 });
              }
            }
          } catch (err) {
            frames.push({ url: "cross-origin", origin: "cross-origin", name: "",
              isSecureContext: false, isCrossOriginIsolated: false, depth: depth });
          }
        }
        try { collectFrame(window, 0); } catch (err) {}
        post({ t: "app.frames", frames: frames });
      };

      // ---- Permissions ----

      ops["app.getPermissions"] = function() {
        if (typeof navigator === "undefined" || typeof navigator.permissions === "undefined" ||
            typeof navigator.permissions.query !== "function") {
          post({ t: "app.error", section: "permissions",
            message: "Permissions API (navigator.permissions.query) is not available in this context" });
          return;
        }
        var names = [
          "geolocation", "notifications", "camera", "microphone",
          "clipboard-read", "clipboard-write", "persistent-storage",
          "screen-wake-lock", "midi"
        ];
        var results = [];
        var pending = names.length;
        names.forEach(function(name) {
          navigator.permissions.query({ name: name }).then(function(status) {
            results.push({ name: name, state: status.state, detail: "" });
          }).catch(function(e) {
            // WebKit throws TypeError for unknown permission names
            results.push({ name: name, state: "n/a", detail: String(e) });
          }).finally(function() {
            pending--;
            if (pending === 0) post({ t: "app.permissions", permissions: results });
          });
        });
      };

    """##
}
