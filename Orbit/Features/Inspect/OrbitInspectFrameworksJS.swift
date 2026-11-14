extension OrbitInspectAgent {
    static let frameworksSource = ##"""


      function fw_safeGet(obj, path) {
        try {
          var parts = path.split('.');
          var cur = obj;
          for (var i = 0; i < parts.length; i++) {
            if (cur == null || typeof cur !== 'object') return undefined;
            cur = cur[parts[i]];
          }
          return cur;
        } catch(e) { return undefined; }
      }

      function fw_str(v) {
        if (v == null) return '';
        return String(v);
      }

      function fw_version(v) {
        if (v == null) return null;
        var s = String(v);
        // Accept "X.Y.Z" or "vX.Y.Z"
        var m = s.match(/v?(\d+\.\d+(?:\.\d+)?(?:[.\-][a-zA-Z0-9.]+)?)/);
        return m ? m[1] : (s.length < 30 ? s : null);
      }


      function fw_scanEvidence() {
        var globals = [];
        var globalVersions = {};
        var domMarkers = [];
        var scriptURLs = [];
        var linkURLs = [];
        var metaGenerators = [];

        var probes = [
          '__REACT_DEVTOOLS_GLOBAL_HOOK__', 'React', '__NEXT_DATA__', '__next_f',
          '__vue_app__', '__VUE__', 'Vue',
          '__NUXT__', '$nuxt',
          '__remixContext', '__remixManifest',
          '___gatsby',
          '__PREACT_DEVTOOLS__',
          'Solid', '_$getOwner',
          'htmx', 'Alpine', 'jQuery', '$', 'litElementVersions',
          '__webpack_require__', 'parcelRequire',
          'ng'
        ];
        probes.forEach(function(name) {
          try {
            if (typeof window[name] !== 'undefined' && window[name] !== null) globals.push(name);
          } catch(e) {}
        });

        try {
          Object.keys(window).forEach(function(k) {
            if (k.startsWith('webpackChunk') || k.startsWith('__sveltekit') ||
                k.startsWith('__turbopack') || k.startsWith('$parcel$')) {
              globals.push(k);
            }
          });
        } catch(e) {}

        var versionProbes = [
          ['React.version', ['React', 'version']],
          ['next.version', ['next', 'version']],
          ['Vue.version', ['Vue', 'version']],
          ['ng.version.full', ['ng', 'version', 'full']],
          ['Alpine.version', ['Alpine', 'version']],
          ['htmx.version', ['htmx', 'version']],
          ['jQuery.fn.jquery', ['jQuery', 'fn', 'jquery']],
          ['$.fn.jquery', ['$', 'fn', 'jquery']],
          ['litElementVersions', ['litElementVersions', '0']],
          ['__NUXT__.versions.nuxt', ['__NUXT__', 'versions', 'nuxt']]
        ];
        versionProbes.forEach(function(probe) {
          try {
            var cur = window;
            var parts = probe[1];
            for (var i = 0; i < parts.length; i++) {
              if (cur == null) { cur = undefined; break; }
              cur = cur[parts[i]];
            }
            var v = fw_version(cur);
            if (v) globalVersions[probe[0]] = v;
          } catch(e) {}
        });

        // React DevTools hook renderer versions
        try {
          var hook = window.__REACT_DEVTOOLS_GLOBAL_HOOK__;
          if (hook && hook.renderers && hook.renderers.size) {
            hook.renderers.forEach(function(renderer) {
              var v = fw_version(renderer.version);
              if (v && !globalVersions['React.version']) globalVersions['React.version'] = v;
            });
          }
        } catch(e) {}

        var domChecks = [
          ['#__next', function() { return !!document.getElementById('__next'); }],
          ['#__nuxt', function() { return !!document.getElementById('__nuxt'); }],
          ['data-reactroot', function() { return !!document.querySelector('[data-reactroot]'); }],
          ['data-svelte-h', function() { return !!document.querySelector('[data-svelte-h]'); }],
          ['ng-version', function() { return !!document.querySelector('[ng-version]'); }],
          ['q:container', function() { return !!document.querySelector('[q\\:container]'); }],
          ['astro-island', function() { return !!document.querySelector('astro-island'); }],
          ['x-data', function() { return !!document.querySelector('[x-data]'); }],
          ['hx-get', function() { return !!document.querySelector('[hx-get]'); }],
          ['hx-post', function() { return !!document.querySelector('[hx-post]'); }]
        ];
        domChecks.forEach(function(check) {
          try { if (check[1]()) domMarkers.push(check[0]); } catch(e) {}
        });

        try {
          var sample = document.querySelector('[class]');
          if (sample) {
            var attrs = sample.attributes;
            for (var i = 0; i < attrs.length; i++) {
              if (attrs[i].name.startsWith('data-v-')) { domMarkers.push('data-v-*'); break; }
            }
          }
        } catch(e) {}

        try {
          var scripts = document.querySelectorAll('script[src]');
          for (var i = 0; i < Math.min(scripts.length, 200); i++) {
            var src = scripts[i].src;
            if (src) scriptURLs.push(src);
          }
        } catch(e) {}

        try {
          var links = document.querySelectorAll('link[href]');
          for (var i = 0; i < Math.min(links.length, 100); i++) {
            var href = links[i].href;
            if (href) linkURLs.push(href);
          }
        } catch(e) {}

        try {
          var metas = document.querySelectorAll('meta[name="generator"]');
          for (var i = 0; i < metas.length; i++) {
            var c = metas[i].content;
            if (c) metaGenerators.push(c);
          }
        } catch(e) {}

        post({
          t: 'fw.evidence',
          globals: globals,
          globalVersions: globalVersions,
          domMarkers: domMarkers,
          scriptURLs: scriptURLs.slice(0, 200),
          linkURLs: linkURLs.slice(0, 100),
          metaGenerators: metaGenerators,
          hostname: String(location.hostname)
        });
      }

      ops['fw.scan'] = function() { fw_scanEvidence(); };


      function fw_selectedComponent() {
        try {
          var el = typeof el_selectedElement === 'function' ? el_selectedElement() : null;
          if (!el) return null;
          return fw_componentForElement(el);
        } catch(e) { return null; }
      }

      function fw_componentForElement(el) {
        if (!el) return null;
        var fiber = fw_findReactFiber(el);
        if (fiber) {
          var cur = fiber;
          // Walk up to the nearest non-host fiber.
          while (cur) {
            if (typeof cur.type === 'function' || typeof cur.type === 'object') return cur.stateNode || cur;
            cur = cur.return;
          }
        }
        try {
          if (el.__vueParentComponent) return el.__vueParentComponent;
        } catch(e) {}
        try {
          if (el.__vue__) return el.__vue__;
        } catch(e) {}
        return null;
      }


      function fw_findReactFiber(el) {
        if (!el) return null;
        try {
          var keys = Object.keys(el);
          for (var i = 0; i < keys.length; i++) {
            var k = keys[i];
            if (k.startsWith('__reactFiber$') || k.startsWith('__reactInternalInstance$')) {
              return el[k];
            }
          }
        } catch(e) {}
        return null;
      }

      function fw_findReactRoots() {
        var roots = [];
        // Via DevTools hook (most reliable in dev mode)
        try {
          var hook = window.__REACT_DEVTOOLS_GLOBAL_HOOK__;
          if (hook && hook.getFiberRoots) {
            hook.getFiberRoots(1).forEach(function(root) { roots.push(root); });
          } else if (hook && hook.renderers) {
            hook.renderers.forEach(function(renderer) {
              if (renderer.getFiberRoots) {
                renderer.getFiberRoots().forEach(function(r) { roots.push(r); });
              }
            });
          }
        } catch(e) {}

        if (roots.length > 0) return roots;

        // Fallback: scan common root IDs for __reactContainer$* keys
        var candidates = [
          '__next', 'root', 'app', '__gatsby', 'gatsby-focus-wrapper',
          '__nuxt', 'app-root', '__remix-root', '__reactRoot'
        ];
        candidates.forEach(function(id) {
          try {
            var el = document.getElementById(id);
            if (!el) return;
            var keys = Object.keys(el);
            for (var i = 0; i < keys.length; i++) {
              if (keys[i].startsWith('__reactContainer$')) {
                var fiber = el[keys[i]];
                if (fiber && fiber.current) { roots.push(fiber); return; }
              }
            }
          } catch(e) {}
        });

        if (roots.length === 0) {
          try {
            var children = document.body ? document.body.children : [];
            for (var i = 0; i < Math.min(children.length, 20); i++) {
              var el = children[i];
              var keys = Object.keys(el);
              for (var j = 0; j < keys.length; j++) {
                if (keys[j].startsWith('__reactContainer$')) {
                  var fiber = el[keys[j]];
                  if (fiber && fiber.current) { roots.push(fiber); break; }
                }
              }
            }
          } catch(e) {}
        }

        return roots;
      }

      function fw_fiberName(fiber) {
        if (!fiber) return null;
        try {
          var type = fiber.type;
          if (!type) return null;
          if (typeof type === 'string') return type;
          if (type.displayName) return fw_str(type.displayName);
          if (type.name) return fw_str(type.name);
          if (type.type) {
            var inner = type.type;
            if (inner.displayName) return 'memo(' + fw_str(inner.displayName) + ')';
            if (inner.name) return 'memo(' + fw_str(inner.name) + ')';
          }
          if (type.render) {
            if (type.render.displayName) return fw_str(type.render.displayName);
            if (type.render.name) return 'forwardRef(' + fw_str(type.render.name) + ')';
            return 'forwardRef(?)';
          }
          if (type._context) return 'Context.Provider';
          if (type.Provider) return 'Context';
          if (type.$$typeof) {
            var tt = fw_str(type.$$typeof);
            if (tt.includes('lazy')) return 'lazy(?)';
            if (tt.includes('suspense')) return 'Suspense';
          }
        } catch(e) {}
        return null;
      }

      function fw_fiberHooks(state) {
        var hooks = [];
        var known = ['useReducer','useState','useEffect','useLayoutEffect',
                     'useMemo','useCallback','useRef','useContext','useId','useTransition'];
        var cur = state;
        var idx = 0;
        var guard = 0;
        while (cur && guard < 100) {
          guard++;
          try {
            var memoized = cur.memoizedState;
            var queue = cur.queue;
            var label = 'hook';
            // Discriminate hook types heuristically
            if (queue === null || queue === undefined) {
              if (memoized !== null && memoized !== undefined && typeof memoized !== 'function') {
                label = 'ref';
              } else {
                label = 'effect';
              }
            } else if (queue && typeof queue === 'object') {
              if (queue.dispatch) label = 'state';
              else if (queue.lastRenderedReducer) label = 'reducer';
              else label = 'memo';
            }
            var val = memoized;
            hooks.push({ i: idx, l: label, v: preview(val, 2, new WeakSet()) });
          } catch(e) {
            hooks.push({ i: idx, l: 'hook', v: '?' });
          }
          cur = cur.next;
          idx++;
        }
        return hooks;
      }

      function fw_walkReactTree() {
        var roots = fw_findReactRoots();
        if (roots.length === 0) return null;

        var flat = [];
        var fiberIds = new Map();
        var nextId = 1;
        var total = 0;
        var MAX = 2000;
        var anyMinified = false;

        function fid(fiber) {
          if (fiberIds.has(fiber)) return fiberIds.get(fiber);
          var id = nextId++;
          fiberIds.set(fiber, id);
          return id;
        }

        function walk(fiber, parentNodeId) {
          if (!fiber || total >= MAX) return;

          var isHost = typeof fiber.type === 'string';
          var name = fw_fiberName(fiber);
          var skipHost = isHost; // skip plain DOM nodes to keep tree manageable

          var myNodeId = null;

          if (!skipHost && name) {
            total++;
            myNodeId = fid(fiber);
            var node = {
              id: myNodeId,
              name: name,
              isHost: isHost,
              key: fiber.key != null ? fw_str(fiber.key) : null,
              domId: null,
              src: null, srcLine: null, srcCol: null,
              owner: null,
              props: {},
              hooks: [],
              children: [],
              minified: false
            };

            try {
              if (fiber.stateNode && fiber.stateNode.nodeType) {
                node.domId = idOf(fiber.stateNode);
              }
            } catch(e) {}

            try {
              if (fiber._debugSource) {
                node.src = fw_str(fiber._debugSource.fileName || '');
                node.srcLine = finite(fiber._debugSource.lineNumber);
                node.srcCol = finite(fiber._debugSource.columnNumber);
              } else if (fiber._debugStack && fiber._debugStack.stack) {
                // React 19: parse the first frame of the stack string
                var line = fw_str(fiber._debugStack.stack).split('\n')[1] || '';
                var m = line.match(/\((.+):(\d+):(\d+)\)$/) || line.match(/at (.+):(\d+):(\d+)$/);
                if (m) { node.src = m[1]; node.srcLine = parseInt(m[2], 10); node.srcCol = parseInt(m[3], 10); }
              }
            } catch(e) {}

            try {
              if (fiber._debugOwner) node.owner = fw_fiberName(fiber._debugOwner) || null;
            } catch(e) {}

            try {
              var props = fiber.memoizedProps;
              if (props && typeof props === 'object') {
                Object.keys(props).filter(function(k) { return k !== 'children'; }).slice(0, 20).forEach(function(k) {
                  node.props[k] = preview(props[k], 2, new WeakSet());
                });
              }
            } catch(e) {}

            try {
              if (fiber.memoizedState && !isHost) {
                node.hooks = fw_fiberHooks(fiber.memoizedState);
              }
            } catch(e) {}

            if (name.length <= 2 && /^[a-z]/.test(name)) {
              node.minified = true;
              anyMinified = true;
            }

            flat.push({ n: node, p: parentNodeId });
          }

          var passId = myNodeId !== null ? myNodeId : parentNodeId;
          var child = fiber.child;
          var guard = 0;
          while (child && total < MAX && guard < 2000) {
            walk(child, passId);
            child = child.sibling;
            guard++;
          }
        }

        roots.forEach(function(r) {
          var start = (r.current) ? r.current : r;
          walk(start, null);
        });

        var nodeMap = {};
        flat.forEach(function(item) { nodeMap[item.n.id] = item.n; });
        flat.forEach(function(item) {
          if (item.p !== null && nodeMap[item.p]) {
            nodeMap[item.p].children.push(item.n.id);
          }
        });

        var rootIds = flat.filter(function(i) { return i.p === null; }).map(function(i) { return i.n.id; });

        return {
          framework: 'react',
          nodes: flat.map(function(i) { return i.n; }),
          roots: rootIds,
          minified: anyMinified,
          capped: total >= MAX,
          cappedAt: MAX
        };
      }


      function fw_walkVueTree() {
        var nodes = [];
        var nextId = 1;

        function walkInstance(inst, parentId) {
          if (!inst || nextId > 500) return;
          var id = nextId++;
          var name = fw_str(inst.type && (inst.type.__name || inst.type.name || inst.type.__file) || '?');
          var file = fw_str(inst.type && inst.type.__file || '');
          var props = {};
          try {
            if (inst.props && typeof inst.props === 'object') {
              Object.keys(inst.props).slice(0, 20).forEach(function(k) {
                props[k] = preview(inst.props[k], 2, new WeakSet());
              });
            }
          } catch(e) {}

          var domId = null;
          try {
            if (inst.vnode && inst.vnode.el && inst.vnode.el.nodeType) {
              domId = idOf(inst.vnode.el);
            }
          } catch(e) {}

          nodes.push({ n: { id: id, name: name, isHost: false, key: null, domId: domId,
            src: file, srcLine: null, srcCol: null, owner: null, props: props,
            hooks: [], children: [], minified: false }, p: parentId });

          try {
            var subTree = inst.subTree;
            if (subTree && subTree.component) walkInstance(subTree.component, id);
            var slots = inst.slots && inst.slots.default && inst.slots.default();
            if (Array.isArray(slots)) {
              slots.forEach(function(vnode) {
                if (vnode && vnode.component) walkInstance(vnode.component, id);
              });
            }
          } catch(e) {}
        }

        try {
          var app = window.__vue_app__;
          if (app && app._instance) walkInstance(app._instance, null);
        } catch(e) {}

        if (nodes.length === 0) return null;

        var nodeMap = {};
        nodes.forEach(function(item) { nodeMap[item.n.id] = item.n; });
        nodes.forEach(function(item) {
          if (item.p !== null && nodeMap[item.p]) nodeMap[item.p].children.push(item.n.id);
        });
        var rootIds = nodes.filter(function(i) { return i.p === null; }).map(function(i) { return i.n.id; });

        return {
          framework: 'vue',
          nodes: nodes.map(function(i) { return i.n; }),
          roots: rootIds,
          minified: false,
          capped: false,
          cappedAt: 500
        };
      }


      function fw_walkAstroIslands() {
        var nodes = [];
        try {
          var islands = document.querySelectorAll('astro-island');
          for (var i = 0; i < islands.length; i++) {
            var el = islands[i];
            var node = {
              id: i + 1,
              name: fw_str(el.getAttribute('component-export') || el.getAttribute('component-url') || 'AstroIsland'),
              isHost: false,
              key: null,
              domId: idOf(el),
              src: fw_str(el.getAttribute('component-url') || ''),
              srcLine: null, srcCol: null, owner: null,
              props: {},
              hooks: [],
              children: [],
              minified: false
            };
            try {
              var rawProps = el.getAttribute('props');
              if (rawProps) {
                var parsed = JSON.parse(rawProps);
                if (parsed && typeof parsed === 'object') {
                  Object.keys(parsed).slice(0, 20).forEach(function(k) {
                    node.props[k] = preview(parsed[k], 2, new WeakSet());
                  });
                }
              }
            } catch(e) {}
            node.props['client'] = fw_str(el.getAttribute('client') || 'load');
            nodes.push(node);
          }
        } catch(e) {}

        if (nodes.length === 0) return null;
        return { framework: 'astro', nodes: nodes, roots: nodes.map(function(n) { return n.id; }), minified: false, capped: false, cappedAt: 500 };
      }

      ops['fw.tree'] = function(msg) {
        var result = null;
        try { result = fw_walkReactTree(); } catch(e) {}
        if (!result) try { result = fw_walkVueTree(); } catch(e) {}
        if (!result) try { result = fw_walkAstroIslands(); } catch(e) {}

        post({ t: 'fw.tree', result: result });
      };


      ops['fw.select'] = function(msg) {
        // Only resolves name and source; the Swift model highlights the node after receiving fw.selected.
        var nodeId = msg.nodeId;
        try {
          var el = nodeById(nodeId);
          if (el && typeof selectNode === 'function') selectNode(el);
        } catch(e) {}
      };

      ops['fw.global'] = function(msg) {
        try {
          var el = typeof el_selectedElement === 'function' ? el_selectedElement() : null;
          if (!el) return;
          var comp = fw_componentForElement(el);
          window['$r'] = comp;
          post({ t: 'fw.globalStored', name: '$r', preview: preview(comp, 1, new WeakSet()) });
        } catch(e) {}
      };


      ops['fw.edit'] = function(msg) {
        var ok = false;
        var err = '';
        try {
          var el = nodeById(msg.domId);
          if (!el) throw new Error('element not found');

          var fiber = fw_findReactFiber(el);
          while (fiber && typeof fiber.type === 'string') fiber = fiber.return;
          if (!fiber) throw new Error('no React fiber');

          var hook = window.__REACT_DEVTOOLS_GLOBAL_HOOK__;
          if (!hook) throw new Error('DevTools hook not available');

          var overrideProps = null;
          var overrideHookState = null;
          hook.renderers && hook.renderers.forEach(function(r) {
            if (r.overrideProps) overrideProps = r.overrideProps;
            if (r.overrideHookState) overrideHookState = r.overrideHookState;
          });

          var val;
          try { val = JSON.parse(msg.value); } catch(e) { val = msg.value; }

          if (msg.kind === 'prop' && overrideProps) {
            overrideProps(fiber, msg.name, [msg.name], val);
            ok = true;
          } else if (msg.kind === 'hook' && overrideHookState) {
            overrideHookState(fiber, msg.hookIndex, [msg.hookIndex], val);
            ok = true;
          } else if (!overrideProps && !overrideHookState) {
            throw new Error('Renderer does not expose overrideProps/overrideHookState (production build or devtools not connected)');
          } else {
            throw new Error('Unsupported edit kind: ' + msg.kind);
          }
        } catch(e) {
          err = fw_str(e && e.message || e);
        }
        post({ t: 'fw.editResult', ok: ok, err: err });
      };


      function fw_extractData() {
        var items = [];

        try {
          if (window.__NEXT_DATA__) {
            var json = JSON.stringify(window.__NEXT_DATA__, null, 2);
            items.push({ id: 'next-page-data', label: 'Next.js Page Data', kind: 'json', json: json, framework: 'nextjs' });
          }
        } catch(e) {}

        try {
          if (window.__next_f && Array.isArray(window.__next_f) && window.__next_f.length > 0) {
            var chunks = window.__next_f.map(function(entry) {
              if (Array.isArray(entry) && entry.length >= 2) return fw_str(entry[1]);
              return fw_str(entry);
            }).filter(Boolean);
            items.push({ id: 'next-flight', label: 'RSC Flight Payload', kind: 'flight', chunks: chunks, framework: 'nextjs' });
          }
        } catch(e) {}

        try {
          if (window.__NUXT__) {
            items.push({ id: 'nuxt-payload', label: 'Nuxt Payload', kind: 'json',
              json: JSON.stringify(window.__NUXT__, null, 2), framework: 'nuxt' });
          }
        } catch(e) {}

        try {
          if (window.__remixContext) {
            items.push({ id: 'remix-context', label: 'Remix Context', kind: 'json',
              json: JSON.stringify(window.__remixContext, null, 2), framework: 'remix' });
          }
        } catch(e) {}

        try {
          var apollo = window.__APOLLO_STATE__ || (window.__APOLLO_CLIENT__ && window.__APOLLO_CLIENT__.cache && window.__APOLLO_CLIENT__.cache.extract());
          if (apollo) {
            items.push({ id: 'apollo-state', label: 'Apollo Cache', kind: 'json',
              json: JSON.stringify(apollo, null, 2), framework: 'apollo' });
          }
        } catch(e) {}

        try {
          var redux = window.__REDUX_STATE__ || window.__PRELOADED_STATE__ || window.__INITIAL_STATE__;
          if (redux) {
            items.push({ id: 'redux-state', label: 'Redux State', kind: 'json',
              json: JSON.stringify(redux, null, 2), framework: 'redux' });
          }
        } catch(e) {}

        try {
          if (window.___gatsby) {
            items.push({ id: 'gatsby', label: 'Gatsby Page Data', kind: 'json',
              json: JSON.stringify(window.___gatsby, null, 2), framework: 'gatsby' });
          }
        } catch(e) {}

        try {
          var ldScripts = document.querySelectorAll('script[type="application/ld+json"]');
          for (var i = 0; i < ldScripts.length; i++) {
            var text = ldScripts[i].textContent || '';
            if (text.trim()) {
              items.push({ id: 'ld-json-' + i, label: 'JSON-LD #' + (i + 1), kind: 'json',
                json: text.trim(), framework: null });
            }
          }
        } catch(e) {}

        try {
          var jsonScripts = document.querySelectorAll('script[type="application/json"]');
          for (var i = 0; i < jsonScripts.length; i++) {
            var text = jsonScripts[i].textContent || '';
            var id = jsonScripts[i].id || ('json-script-' + i);
            if (text.trim()) {
              items.push({ id: 'json-script-' + i, label: 'JSON Script' + (id !== 'json-script-' + i ? ' #' + id : ' #' + (i + 1)),
                kind: 'json', json: text.trim(), framework: null });
            }
          }
        } catch(e) {}

        try {
          var im = document.querySelector('script[type="importmap"]');
          if (im && im.textContent.trim()) {
            items.push({ id: 'importmap', label: 'Import Map', kind: 'json',
              json: im.textContent.trim(), framework: null });
          }
        } catch(e) {}

        try {
          var sr = document.querySelector('script[type="speculationrules"]');
          if (sr && sr.textContent.trim()) {
            items.push({ id: 'speculationrules', label: 'Speculation Rules', kind: 'json',
              json: sr.textContent.trim(), framework: null });
          }
        } catch(e) {}

        // Global snapshot: non-standard window properties
        try {
          var standard = new Set(['window','self','top','parent','opener','frames','closed',
            'location','history','navigator','screen','document','performance','console',
            'localStorage','sessionStorage','indexedDB','caches','crypto','fetch',
            'XMLHttpRequest','WebSocket','EventSource','Worker','ServiceWorker',
            'addEventListener','removeEventListener','dispatchEvent','alert','confirm',
            'prompt','open','close','focus','blur','print','setTimeout','clearTimeout',
            'setInterval','clearInterval','queueMicrotask','requestAnimationFrame',
            'cancelAnimationFrame','requestIdleCallback','cancelIdleCallback',
            'getComputedStyle','matchMedia','scrollTo','scrollBy','scroll',
            'customElements','speechSynthesis','visualViewport',
            'IntersectionObserver','ResizeObserver','MutationObserver','PerformanceObserver',
            'AbortController','AbortSignal','FormData','Headers','Request','Response',
            'URL','URLSearchParams','Blob','File','FileReader','ArrayBuffer','DataView',
            'Int8Array','Uint8Array','Float32Array','Float64Array',
            'Promise','Symbol','Proxy','Reflect','Map','Set','WeakMap','WeakSet',
            'Error','TypeError','RangeError','ReferenceError','SyntaxError',
            'JSON','Math','Date','RegExp','Number','String','Boolean','Object','Array',
            'Function','Generator','GeneratorFunction','AsyncFunction',
            'NaN','Infinity','undefined','null','eval','isFinite','isNaN',
            'parseInt','parseFloat','encodeURI','decodeURI','encodeURIComponent','decodeURIComponent',
            'atob','btoa','escape','unescape','globalThis','global',
            'webkit','__orbitInspect']);
          var globs = [];
          try {
            Object.keys(window).forEach(function(k) {
              if (standard.has(k)) return;
              if (k.startsWith('__orbit')) return;
              var v;
              try { v = preview(window[k], 1, new WeakSet()); } catch(e) { v = '?'; }
              globs.push({ name: k, preview: v });
            });
          } catch(e) {}
          if (globs.length > 0) {
            items.push({ id: 'globals', label: 'Page Globals', kind: 'globals', globals: globs.slice(0, 300), framework: null });
          }
        } catch(e) {}

        post({ t: 'fw.data', items: items });
      }

      ops['fw.data'] = function() { fw_extractData(); };


      function fw_extractRoutes() {
        var routes = [];
        var currentPath = String(location.pathname);

        try {
          if (window.__BUILD_MANIFEST && Array.isArray(window.__BUILD_MANIFEST.sortedPages)) {
            window.__BUILD_MANIFEST.sortedPages.forEach(function(p) {
              var current = p === (window.__NEXT_DATA__ && window.__NEXT_DATA__.page) || currentPath === p;
              routes.push({ id: 'np-' + p, path: p, current: current, dynamic: p.includes('['), params: {}, source: 'next-pages' });
            });
          } else if (window.__NEXT_DATA__ && window.__NEXT_DATA__.page) {
            routes.push({ id: 'np-current', path: window.__NEXT_DATA__.page, current: true,
              dynamic: false, params: window.__NEXT_DATA__.query || {}, source: 'next-pages' });
          }
        } catch(e) {}

        try {
          if (window.next && window.next.router && window.next.router.state) {
            routes.push({ id: 'na-current', path: currentPath, current: true, dynamic: false, params: {}, source: 'next-app-router' });
          }
        } catch(e) {}

        try {
          if (window.__remixManifest && window.__remixManifest.routes) {
            var remixRoutes = window.__remixManifest.routes;
            Object.keys(remixRoutes).forEach(function(id) {
              var r = remixRoutes[id];
              var path = r.path || (r.index ? '(index)' : id);
              routes.push({ id: 'rx-' + id, path: path, current: false, dynamic: (path || '').includes(':'), params: {}, source: 'remix' });
            });
          }
        } catch(e) {}

        try {
          if (window.$nuxt && window.$nuxt.$router && typeof window.$nuxt.$router.getRoutes === 'function') {
            window.$nuxt.$router.getRoutes().forEach(function(r, i) {
              routes.push({ id: 'nx-' + i, path: r.path || '', current: r.path === currentPath,
                dynamic: (r.path || '').includes(':'), params: {}, source: 'nuxt' });
            });
          }
        } catch(e) {}

        post({ t: 'fw.routes', routes: routes });
      }

      ops['fw.routes'] = function() { fw_extractRoutes(); };


      var fw_overlayObserver = null;

      function fw_checkOverlays() {
        try {
          var portal = document.querySelector('nextjs-portal');
          if (portal && portal.shadowRoot) {
            var body = portal.shadowRoot.querySelector('[data-nextjs-dialog]') ||
                       portal.shadowRoot.querySelector('body') ||
                       portal.shadowRoot;
            var text = body ? (body.textContent || '').trim() : '';
            if (text.length > 0) {
              var fileMatch = text.match(/([a-zA-Z0-9._\-\/]+\.[a-z]+):(\d+)/);
              post({ t: 'fw.overlay', visible: true, message: text.slice(0, 1000),
                file: fileMatch ? fileMatch[1] : null,
                line: fileMatch ? parseInt(fileMatch[2], 10) : null,
                source: 'next' });
              return;
            }
          }
        } catch(e) {}

        try {
          var viteOverlay = document.querySelector('vite-error-overlay');
          if (viteOverlay && viteOverlay.shadowRoot) {
            var msg = viteOverlay.shadowRoot.querySelector('.message-body') ||
                      viteOverlay.shadowRoot.querySelector('pre');
            var text = msg ? (msg.textContent || '').trim() : '';
            if (text.length > 0) {
              post({ t: 'fw.overlay', visible: true, message: text.slice(0, 1000), file: null, line: null, source: 'vite' });
              return;
            }
          }
        } catch(e) {}

        try {
          var iframe = document.querySelector('iframe[style*="z-index: 2147483647"]') ||
                       document.querySelector('#webpack-dev-server-client-overlay');
          if (iframe) {
            post({ t: 'fw.overlay', visible: true, message: 'Build error (see webpack overlay)', file: null, line: null, source: 'webpack' });
            return;
          }
        } catch(e) {}

        post({ t: 'fw.overlay', visible: false, message: '', file: null, line: null, source: '' });
      }


      ops['fw.launch'] = function(msg) {
        var file = msg.file || '';
        var line = msg.line || 1;
        var col = msg.col || 1;
        var devserver = msg.devserver || '';

        function tryURL(url) {
          try {
            var xhr = new XMLHttpRequest();
            xhr.open('GET', url, true);
            xhr.onload = function() {
              post({ t: 'fw.launchResult', ok: xhr.status < 400, status: xhr.status, devserver: devserver });
            };
            xhr.onerror = function() {
              post({ t: 'fw.launchResult', ok: false, status: 0, devserver: devserver });
            };
            xhr.send();
          } catch(e) {
            post({ t: 'fw.launchResult', ok: false, status: 0, devserver: devserver });
          }
        }

        if (devserver === 'next') {
          tryURL('/__nextjs_launch-editor?file=' + encodeURIComponent(file) + '&lineNumber=' + line + '&column=' + col);
        } else if (devserver === 'vite') {
          tryURL('/__open-in-editor?file=' + encodeURIComponent(file + ':' + line + ':' + col));
        } else {
          post({ t: 'fw.launchResult', ok: false, status: 0, devserver: devserver });
        }
      };


      var fw_pollTimer = null;

      ops['fw.start'] = function(msg) {
        if (fw_pollTimer !== null) return;
        var interval = (msg && msg.interval) ? msg.interval : 2000;
        fw_pollTimer = setInterval(function() {
          try { fw_scanEvidence(); } catch(e) {}
        }, interval);
      };

      ops['fw.stop'] = function() {
        if (fw_pollTimer !== null) {
          clearInterval(fw_pollTimer);
          fw_pollTimer = null;
        }
      };


      inits.push(function() {
        try {
          fw_overlayObserver = new MutationObserver(function() {
            try { fw_checkOverlays(); } catch(e) {}
          });
          fw_overlayObserver.observe(document.body || document.documentElement, {
            childList: true, subtree: true
          });
        } catch(e) {}

        setTimeout(function() {
          try { fw_scanEvidence(); } catch(e) {}
        }, 0);
      });

      disposers.push(function() {
        if (fw_overlayObserver) { try { fw_overlayObserver.disconnect(); } catch(e) {} fw_overlayObserver = null; }
        if (fw_pollTimer !== null) { clearInterval(fw_pollTimer); fw_pollTimer = null; }
      });

      navHooks.push(function() {
        setTimeout(function() { try { fw_scanEvidence(); } catch(e) {} }, 100);
      });

    """##
}
