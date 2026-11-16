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
          'ng', 'useNuxtApp', '__reactRouterContext', '__reactRouterDataRouter', '__remixRouter',
          '__STORYBOOK_PREVIEW__', '___loader', '___emitter', '___gatsby', '__astro_dev_toolbar__'
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
          ['__NUXT__.versions.nuxt', ['__NUXT__', 'versions', 'nuxt']],
          ['__reactRouterVersion', ['__reactRouterVersion']],
          ['__astro_dev_toolbar__.version', ['__astro_dev_toolbar__', 'version']]
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

        // Nuxt removes window.__NUXT__ after hydration; the app object keeps the versions.
        try {
          if (typeof window.useNuxtApp === 'function' && !globalVersions['__NUXT__.versions.nuxt']) {
            var nuxtVersion = fw_version(window.useNuxtApp().versions.nuxt);
            if (nuxtVersion) globalVersions['__NUXT__.versions.nuxt'] = nuxtVersion;
          }
        } catch(e) {}

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
          ['#___gatsby', function() { return !!document.getElementById('___gatsby'); }],
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
        try { fw_attachHooks(); fw_devProbe(); } catch(e) {}
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
      var fw_overlayTimer = null;
      var fw_lastOverlaySignature = '';

      function fw_overlaySelectors() {
        return ['nextjs-portal', 'vite-error-overlay', 'rsbuild-error-overlay', 'nuxt-error-overlay',
                'gatsby-fast-refresh', '#webpack-dev-server-client-overlay', '#react-refresh-overlay',
                '#__parcel__error__overlay__', '#webpack-hot-middleware-clientOverlay'];
      }

      function fw_overlayElements() {
        var out = [];
        fw_overlaySelectors().forEach(function(sel) {
          try { var el = document.querySelector(sel); if (el) out.push({ sel: sel, el: el }); } catch(e) {}
        });
        return out;
      }

      function fw_applyOverlayVisibility() {
        // A hidden overlay stays hidden when the framework mounts a new one for the next error.
        var hidden = !!window.__orbitFwOverlayHidden;
        fw_overlayElements().forEach(function(item) {
          try {
            if (hidden) item.el.style.setProperty('display', 'none', 'important');
            else if (item.el.style.display === 'none') item.el.style.removeProperty('display');
          } catch(e) {}
        });
      }

      function fw_checkOverlays() {
        var result = { visible: false, message: '', file: null, line: null, col: null, source: '' };

        try {
          var portal = document.querySelector('nextjs-portal');
          var root = portal && portal.shadowRoot;
          // The portal also holds the dev indicator, so only an open error dialog counts as an error overlay.
          var dialog = root && (root.querySelector('[data-nextjs-dialog]') || root.querySelector('[data-nextjs-dialog-overlay]'));
          if (dialog) {
            var desc = root.querySelector('#nextjs__container_errors_desc');
            var label = root.querySelector('#nextjs__container_errors_label');
            var text = ((desc && desc.textContent) || (dialog.textContent || '')).trim();
            if (text.length > 0) {
              var codeframe = root.querySelector('[data-nextjs-codeframe]');
              var scope = ((codeframe && codeframe.textContent) || '') + ' ' + (dialog.textContent || '');
              var fileMatch = scope.match(/([a-zA-Z0-9._\-\/@\[\]()]+\.[a-z0-9]{1,8}):(\d+)(?::(\d+))?/);
              result = { visible: true, message: ((label && label.textContent ? label.textContent.trim() + ': ' : '') + text).slice(0, 1000),
                file: fileMatch ? fileMatch[1] : null, line: fileMatch ? parseInt(fileMatch[2], 10) : null,
                col: fileMatch && fileMatch[3] ? parseInt(fileMatch[3], 10) : null, source: 'next' };
            }
          }
        } catch(e) {}

        if (!result.visible) try {
          var viteOverlay = document.querySelector('vite-error-overlay');
          if (viteOverlay && viteOverlay.shadowRoot) {
            var msg = viteOverlay.shadowRoot.querySelector('.message-body') ||
                      viteOverlay.shadowRoot.querySelector('pre');
            var fileEl = viteOverlay.shadowRoot.querySelector('.file');
            var vtext = msg ? (msg.textContent || '').trim() : '';
            if (vtext.length > 0) {
              var loc = fileEl ? (fileEl.textContent || '').trim().match(/^(.*?):(\d+)(?::(\d+))?$/) : null;
              result = { visible: true, message: vtext.slice(0, 1000), file: loc ? loc[1] : null,
                line: loc ? parseInt(loc[2], 10) : null, col: loc && loc[3] ? parseInt(loc[3], 10) : null, source: 'vite' };
            }
          }
        } catch(e) {}

        if (!result.visible) try {
          var rs = document.querySelector('rsbuild-error-overlay');
          if (rs && rs.shadowRoot && (rs.shadowRoot.textContent || '').trim()) {
            result = { visible: true, message: (rs.shadowRoot.textContent || '').trim().slice(0, 1000), file: null, line: null, col: null, source: 'rsbuild' };
          }
        } catch(e) {}

        if (!result.visible) try {
          var iframe = document.querySelector('#webpack-dev-server-client-overlay');
          if (iframe) {
            var inner = '';
            try { inner = (iframe.contentDocument && iframe.contentDocument.body && iframe.contentDocument.body.textContent || '').trim(); } catch(e) {}
            result = { visible: true, message: (inner || 'Build error (see webpack overlay)').slice(0, 1000), file: null, line: null, col: null, source: 'webpack' };
          }
        } catch(e) {}

        var signature = [result.visible, result.message, result.file, result.line, result.source].join('|');
        if (signature === fw_lastOverlaySignature) return;
        fw_lastOverlaySignature = signature;
        post({ t: 'fw.overlay', visible: result.visible, message: result.message, file: result.file,
               line: result.line, col: result.col, source: result.source });
      }

      // DOM mutations arrive in bursts; one check per burst keeps the bridge quiet.
      function fw_scheduleOverlayCheck() {
        if (fw_overlayTimer !== null) return;
        fw_overlayTimer = setTimeout(function() {
          fw_overlayTimer = null;
          try { fw_applyOverlayVisibility(); fw_checkOverlays(); } catch(e) {}
        }, 250);
      }


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
          fw_overlayObserver = new MutationObserver(function() { fw_scheduleOverlayCheck(); });
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
        if (fw_overlayTimer !== null) { clearTimeout(fw_overlayTimer); fw_overlayTimer = null; }
        if (fw_pollTimer !== null) { clearInterval(fw_pollTimer); fw_pollTimer = null; }
      });

      navHooks.push(function() {
        setTimeout(function() { try { fw_scanEvidence(); } catch(e) {} }, 100);
      });


      // ---- Dev server surface: HMR sockets, frames, hooks, probe and actions ----

      var fw_sockSeq = 0;
      var fw_epoch = 0;
      var fw_hooked = typeof WeakSet === 'function' ? new WeakSet() : null;
      var fw_runtimeErrors = 0;

      function fw_now() { return Date.now(); }

      function fw_parcelPresent() {
        try {
          if (typeof window.parcelRequire !== 'undefined') return true;
          var keys = Object.keys(window);
          for (var i = 0; i < keys.length; i++) {
            if (keys[i].indexOf('parcelRequire') === 0 || keys[i].indexOf('$parcel$') === 0) return true;
          }
        } catch(e) {}
        return false;
      }

      // Null for sockets the page uses for anything else, so app traffic never reaches the inspector.
      function fw_devSocketInfo(url, protocols) {
        var u;
        try { u = new URL(url, location.href); } catch(e) { return null; }
        if (protocols.indexOf('vite-ping') >= 0) return null;
        if (protocols.indexOf('vite-hmr') >= 0) return {};
        var p = u.pathname;
        if (/\/_next\/(webpack-)?hmr/.test(p) || /\/rsbuild-hmr/.test(p) || /\/ng-cli-ws/.test(p) ||
            /\/sockjs-node/.test(p) || /\/livereload/.test(p) || /\/__webpack_hmr/.test(p) ||
            /\/__parcel_hmr/.test(p) || /\/storybook-server-channel/.test(p)) return {};
        if (/\/ws$/.test(p)) return {};
        if (p === '/socket' && u.port === '8002') return {};
        if ((p === '/' || p === '') && fw_parcelPresent()) return { hint: 'parcel' };
        return null;
      }

      function fw_watchSocket(target, url, protocols, transport) {
        var list = Array.isArray(protocols) ? protocols.map(String) : (protocols ? [String(protocols)] : []);
        var info = fw_devSocketInfo(url, list);
        if (!info) return;
        var id = ++fw_sockSeq;
        var abs = url;
        try { abs = new URL(url, location.href).href; } catch(e) {}
        function state(name, extra) {
          var msg = { t: 'fw.devSocket', id: id, url: abs, protocols: list, transport: transport,
                      state: name, hint: info.hint || '', at: fw_now() };
          if (extra) for (var k in extra) msg[k] = extra[k];
          post(msg);
        }
        state('connecting');
        target.addEventListener('open', function() { state('open'); });
        target.addEventListener('close', function(e) { state('closed', { code: finite(e && e.code) }); });
        target.addEventListener('error', function() { state(target.readyState === 2 ? 'closed' : 'error'); });
        target.addEventListener('message', function(e) {
          var d = e.data;
          if (typeof d === 'string') {
            post({ t: 'fw.devFrame', id: id, data: d.length > 200000 ? d.slice(0, 200000) : d, at: fw_now() });
          } else {
            var len = 0;
            try { len = (d && (d.byteLength || d.size)) || 0; } catch(x) {}
            post({ t: 'fw.devFrame', id: id, data: '', binary: true, len: len, at: fw_now() });
          }
        });
      }

      function fw_event(name, detail, extra) {
        var msg = { t: 'fw.devEvent', name: name, detail: detail == null ? '' : fw_str(detail), at: fw_now() };
        if (extra) for (var k in extra) msg[k] = extra[k];
        post(msg);
      }

      function fw_once(obj) {
        if (!obj || !fw_hooked) return false;
        if (fw_hooked.has(obj)) return false;
        fw_hooked.add(obj);
        return true;
      }

      function fw_errorMessage(err) {
        if (!err) return '';
        if (typeof err === 'string') return err;
        var parts = [];
        if (err.title) parts.push(fw_str(err.title));
        if (err.description) parts.push(fw_str(err.description));
        if (err.message) parts.push(fw_str(err.message));
        return parts.length ? parts.join(': ') : fw_str(err);
      }

      // Framework router and lifecycle hooks only exist once the app has booted, so this runs repeatedly and each target is hooked once.
      function fw_attachHooks() {
        var epoch = fw_epoch;
        function live() { return epoch === fw_epoch; }

        try {
          var nx = window.next;
          if (nx && nx.router && nx.router.events && typeof nx.router.events.on === 'function' && fw_once(nx.router.events)) {
            ['routeChangeStart', 'routeChangeComplete'].forEach(function(name) {
              nx.router.events.on(name, function(url) { if (live()) fw_event('next.' + name, url); });
            });
            nx.router.events.on('routeChangeError', function(err, url) {
              if (!live() || (err && err.cancelled)) return;
              fw_event('next.routeChangeError', url, { message: fw_errorMessage(err) });
            });
          }
        } catch(e) {}

        try {
          var rr = window.__reactRouterDataRouter || window.__remixRouter;
          if (rr && typeof rr.subscribe === 'function' && fw_once(rr)) {
            var last = '';
            rr.subscribe(function(s) {
              if (!live()) return;
              var nav = (s.navigation && s.navigation.state) || 'idle';
              var key = nav + '|' + (s.revalidation || 'idle');
              if (key === last) return;
              last = key;
              var path = (s.navigation && s.navigation.location && s.navigation.location.pathname) || (s.location && s.location.pathname) || '';
              fw_event(s.revalidation === 'loading' ? 'rr.revalidating' : 'rr.' + nav, path);
            });
          }
        } catch(e) {}

        try {
          if (typeof window.useNuxtApp === 'function') {
            var app = window.useNuxtApp();
            if (app && typeof app.hook === 'function' && fw_once(app)) {
              ['page:start', 'page:finish', 'app:data:refresh'].forEach(function(name) {
                app.hook(name, function() { if (live()) fw_event('nuxt.' + name, location.pathname); });
              });
              ['app:error', 'vue:error'].forEach(function(name) {
                app.hook(name, function(err) { if (live()) fw_event('nuxt.' + name, '', { message: fw_errorMessage(err) }); });
              });
            }
          }
        } catch(e) {}

        try {
          if (fw_once(document)) {
            ['before-preparation', 'after-swap', 'page-load'].forEach(function(name) {
              document.addEventListener('astro:' + name, function() { if (live()) fw_event('astro.' + name, location.pathname); });
            });
          }
        } catch(e) {}

        try {
          var sb = window.__STORYBOOK_PREVIEW__;
          if (sb && sb.channel && typeof sb.channel.on === 'function' && fw_once(sb.channel)) {
            ['storyRendered', 'storyErrored', 'storyThrewException', 'storyHotUpdated'].forEach(function(name) {
              sb.channel.on(name, function(arg) {
                if (!live()) return;
                var detail = typeof arg === 'string' ? arg : '';
                fw_event('storybook.' + name, detail, { message: typeof arg === 'string' ? '' : fw_errorMessage(arg) });
              });
            });
          }
        } catch(e) {}

        try {
          var em = window.___emitter;
          if (em && typeof em.on === 'function' && fw_once(em)) {
            ['pageQueryResult', 'staticQueryResult', 'onRouteUpdate'].forEach(function(name) {
              em.on(name, function() { if (live()) fw_event('gatsby.' + name, location.pathname); });
            });
            em.on('overlayError', function(e) {
              if (live()) fw_event('gatsby.overlayError', '', { message: fw_errorMessage(e && (e.payload || e)) });
            });
          }
        } catch(e) {}
      }

      // What the page offers: names the Swift side maps to controls and to "is this a dev server".
      function fw_devProbe() {
        var signals = [];
        var facts = {};
        var env = [];
        function sig(name) { if (signals.indexOf(name) < 0) signals.push(name); }
        function fact(key, value) { if (value != null && value !== '') facts[key] = String(value); }
        function isFn(obj, key) { try { return !!obj && typeof obj[key] === 'function'; } catch(e) { return false; } }

        try {
          var nx = window.next;
          var nd = window.__NEXT_DATA__;
          var appRouter = !!(nx && nx.appDir);
          if (nx) {
            fact('next.version', nx.version);
            if (appRouter) sig('next.app');
            var router = nx.router;
            if (router) {
              if (isFn(router, 'push')) sig('next.router.push');
              if (isFn(router, 'replace')) sig('next.router.replace');
              if (isFn(router, 'refresh')) sig('next.router.refresh');
              if (isFn(router, 'hmrRefresh')) sig('next.router.hmrRefresh');
            }
            if (nx.turbopack === true) sig('next.turbopack');
          }
          if (nd) {
            if (!appRouter) sig('next.pages');
            fact('next.router', appRouter ? 'app' : 'pages');
            ['gsp', 'gssp', 'gip', 'appGip', 'autoExport', 'nextExport', 'isFallback', 'isPreview'].forEach(function(key) {
              if (nd[key]) facts['next.' + key] = 'true';
            });
            fact('next.page', nd.page);
            if (nd.buildId === 'development') sig('next.devBuildId');
          } else if (appRouter) {
            fact('next.router', 'app');
          }
          var dbg = window.nd;
          if (dbg && typeof dbg === 'object' && 'router' in dbg && 'tree' in dbg) sig('next.nd');
          if (document.querySelector('nextjs-portal')) sig('next.portal');
        } catch(e) {}

        try {
          if (document.querySelector('script[src*="/@vite/client"]')) sig('vite.client');
          var keys = Object.keys(window);
          for (var i = 0; i < keys.length; i++) {
            var k = keys[i];
            if (k.indexOf('webpackHotUpdate') === 0) sig('webpack.hmr');
            if (k === '__sveltekit_dev') sig('sveltekit.dev');
            if (k.indexOf('__sveltekit') === 0) {
              var payload = window[k];
              if (payload && payload.env && typeof payload.env === 'object') {
                Object.keys(payload.env).slice(0, 40).forEach(function(name) {
                  env.push({ key: name, value: preview(payload.env[name], 1, new WeakSet()), source: 'SvelteKit public env' });
                });
              }
            }
          }
          if (window.__webpack_hot_middleware_reporter__) sig('whm.reporter');
        } catch(e) {}

        try {
          var hook = window.__REACT_DEVTOOLS_GLOBAL_HOOK__;
          if (hook && hook.renderers && hook.renderers.size) {
            var dev = false, prod = false;
            hook.renderers.forEach(function(renderer) {
              if (renderer && renderer.bundleType === 1) dev = true;
              else if (renderer && renderer.bundleType === 0) prod = true;
            });
            if (dev) sig('react.dev'); else if (prod) sig('react.prod');
          }
        } catch(e) {}

        try {
          if (window.ng && isFn(window.ng, 'getComponent')) sig('angular.dev');
          var ngRoot = document.querySelector('[ng-version]');
          if (ngRoot) fact('angular.hydration', document.querySelector('[ngh]') ? 'enabled (ngh attributes present)' : 'not detected');
          if (window.ng && isFn(window.ng, 'ɵnavigateByUrl')) sig('angular.router');
        } catch(e) {}

        try {
          if (typeof window.useNuxtApp === 'function') {
            sig('nuxt.app');
            var nuxt = window.useNuxtApp();
            if (nuxt) {
              if (nuxt.versions) { fact('nuxt.version', nuxt.versions.nuxt); fact('vue.version', nuxt.versions.vue); }
              var payloadN = nuxt.payload || {};
              fact('nuxt.serverRendered', payloadN.serverRendered === undefined ? null : !!payloadN.serverRendered);
              var cfg = payloadN.config || {};
              if (cfg.app) { fact('nuxt.baseURL', cfg.app.baseURL); fact('nuxt.buildId', cfg.app.buildId); }
              if (cfg.public && typeof cfg.public === 'object') {
                Object.keys(cfg.public).slice(0, 40).forEach(function(name) {
                  env.push({ key: name, value: preview(cfg.public[name], 1, new WeakSet()), source: 'Nuxt runtimeConfig.public' });
                });
              }
            }
          }
        } catch(e) {}

        try {
          var router2 = window.__reactRouterDataRouter || window.__remixRouter;
          if (router2 && isFn(router2, 'revalidate') && isFn(router2, 'navigate')) sig('rr.dataRouter');
          var ctx = window.__reactRouterContext;
          if (ctx) { fact('rr.ssr', ctx.ssr === undefined ? null : !!ctx.ssr); fact('rr.basename', ctx.basename); }
        } catch(e) {}

        try {
          var tb = window.__astro_dev_toolbar__;
          if (tb) { sig('astro.toolbar'); fact('astro.version', tb.version); fact('astro.root', tb.root); }
          fact('astro.islands', document.querySelectorAll('astro-island').length || null);
          if (document.querySelector('[data-astro-source-file]')) facts['astro.sourceAttrs'] = 'true';
        } catch(e) {}

        try {
          if (window.___loader) sig('gatsby.loader');
          if (isFn(window, '___navigate')) sig('gatsby.navigate');
          if (window.__STORYBOOK_PREVIEW__) sig('storybook.preview');
        } catch(e) {}

        try {
          if (window.__svelte && window.__svelte.v && typeof window.__svelte.v.forEach === 'function') {
            window.__svelte.v.forEach(function(v) { if (!facts['svelte.major']) facts['svelte.major'] = String(v); });
          }
          var q = document.querySelector('[q\\:container]');
          if (q) {
            var render = q.getAttribute('q:render') || '';
            var version = q.getAttribute('q:version') || '';
            fact('qwik.render', render);
            fact('qwik.version', version);
            if (/dev/.test(render) || version === 'dev') sig('qwik.dev');
          }
        } catch(e) {}

        var hosts = [];
        fw_overlayElements().forEach(function(item) { hosts.push(item.sel); });

        function finish(workers, caches) {
          post({ t: 'fw.devProbe', signals: signals, facts: facts, overlays: hosts, overlayHidden: !!window.__orbitFwOverlayHidden,
                 env: env, serviceWorkers: workers, cacheEntries: caches, pathname: String(location.pathname) });
        }
        var swCount = (navigator.serviceWorker && navigator.serviceWorker.getRegistrations)
          ? navigator.serviceWorker.getRegistrations().then(function(r) { return r.length; }, function() { return 0; })
          : Promise.resolve(0);
        var cacheCount = (window.caches && typeof caches.keys === 'function')
          ? caches.keys().then(function(k) { return k.length; }, function() { return 0; })
          : Promise.resolve(0);
        Promise.all([swCount, cacheCount]).then(function(v) { finish(v[0], v[1]); }, function() { finish(0, 0); });
      }

      ops['fw.devProbe'] = function() { fw_attachHooks(); fw_devProbe(); };

      function fw_http(method, url, limit) {
        // The raw fetch keeps these control requests out of the Network tool.
        var send = (typeof net_rawFetch === 'function') ? net_rawFetch : (typeof fetch === 'function' ? fetch : null);
        if (!send) return Promise.reject(new Error('fetch is unavailable on this page.'));
        return send.call(window, url, { method: method, credentials: 'same-origin', cache: 'no-store' }).then(function(r) {
          return r.text().then(function(text) { return { status: r.status, ok: r.ok, body: text.slice(0, limit || 400) }; });
        });
      }

      // Tries each candidate endpoint in order and stops at the first that answers with success.
      ops['fw.launch'] = function(msg) {
        var list = msg.requests || [];
        var index = 0;
        var lastStatus = 0;
        function next() {
          if (index >= list.length) { post({ t: 'fw.launchResult', ok: false, status: lastStatus, url: '' }); return; }
          var url = list[index++];
          fw_http('GET', url).then(function(r) {
            lastStatus = r.status;
            if (r.ok) post({ t: 'fw.launchResult', ok: true, status: r.status, url: url });
            else next();
          }, function() { next(); });
        }
        next();
      };

      function fw_clearCaches() {
        var tasks = [];
        var workers = 0;
        var caches_ = 0;
        if (navigator.serviceWorker && navigator.serviceWorker.getRegistrations) {
          tasks.push(navigator.serviceWorker.getRegistrations().then(function(regs) {
            return Promise.all(regs.map(function(r) { return r.unregister().then(function(ok) { if (ok) workers++; }); }));
          }));
        }
        if (window.caches && typeof caches.keys === 'function') {
          tasks.push(caches.keys().then(function(keys) {
            return Promise.all(keys.map(function(k) { return caches.delete(k).then(function(ok) { if (ok) caches_++; }); }));
          }));
        }
        return Promise.all(tasks).then(function() {
          return 'Removed ' + workers + ' service worker' + (workers === 1 ? '' : 's') + ' and ' + caches_ + ' cache' + (caches_ === 1 ? '' : 's') + '.';
        });
      }

      function fw_navigate(strategy, path, done, fail) {
        function settle(p, label) { Promise.resolve(p).then(function() { done(true, label); }, fail); }
        switch (strategy) {
          case 'next.router.push': settle(window.next.router.push(path), 'Navigated with next.router.push, no page load.'); return;
          case 'rr.navigate': settle((window.__reactRouterDataRouter || window.__remixRouter).navigate(path), 'Navigated with the data router, no page load.'); return;
          case 'nuxt.router.push': settle(window.useNuxtApp().$router.push(path), 'Navigated with the Nuxt router, no page load.'); return;
          case 'gatsby.navigate': settle(window.___navigate(path), 'Navigated with ___navigate, no page load.'); return;
          case 'angular.router': settle(window.ng['ɵnavigateByUrl'](path), 'Navigated with the Angular router, no page load.'); return;
          default: break;
        }
        // A client router that delegates link handling (SvelteKit, Astro, Turbo) intercepts a real anchor click; others load the page.
        var a = document.createElement('a');
        a.href = path;
        a.style.display = 'none';
        (document.body || document.documentElement).appendChild(a);
        var marker = window.__orbitFwNavMarker = fw_now();
        a.click();
        a.remove();
        setTimeout(function() {
          if (window.__orbitFwNavMarker !== marker) return;
          var target = new URL(path, location.href);
          var moved = target.pathname === location.pathname && target.search === location.search;
          done(moved, moved ? 'The client router handled the link click, no page load.' : 'The link click had no effect (the page did not navigate).');
        }, 500);
      }

      ops['fw.devAction'] = function(msg) {
        var action = String(msg.action || '');
        function done(ok, message, pending) { post({ t: 'fw.devActionResult', action: action, ok: ok, message: message || '', pending: !!pending }); }
        function fail(e) { done(false, fw_str(e && e.message || e)); }
        try {
          if (action === 'clearCaches') {
            fw_clearCaches().then(function(text) { done(true, text); }, fail);
          } else if (action === 'hardReload') {
            fw_clearCaches().then(function() { location.reload(); }, function() { location.reload(); });
          } else if (action === 'softRefresh') {
            var strategy = msg.strategy;
            if (strategy === 'next.app.refresh') { window.next.router.refresh(); done(true, 'router.refresh() called.'); }
            else if (strategy === 'next.pages.replace') { Promise.resolve(window.next.router.replace(window.next.router.asPath)).then(function() { done(true, 'router.replace(asPath) refetched the page data.'); }, fail); }
            else if (strategy === 'rr.revalidate') { Promise.resolve((window.__reactRouterDataRouter || window.__remixRouter).revalidate()).then(function() { done(true, 'router.revalidate() reran the loaders.'); }, fail); }
            else if (strategy === 'nuxt.refreshData') { Promise.resolve(window.useNuxtApp().hooks.callHookParallel('app:data:refresh')).then(function() { done(true, 'app:data:refresh ran.'); }, fail); }
            else if (strategy === 'storybook.forceReRender') { window.__STORYBOOK_PREVIEW__.channel.emit('forceReRender'); done(true, 'forceReRender emitted.'); }
            else done(false, 'No refresh API is available for this page.');
          } else if (action === 'hmrRefresh') {
            window.next.router.hmrRefresh();
            done(true, 'router.hmrRefresh() called.');
          } else if (action === 'toggleOverlay') {
            window.__orbitFwOverlayHidden = !window.__orbitFwOverlayHidden;
            fw_applyOverlayVisibility();
            done(true, window.__orbitFwOverlayHidden ? 'Overlay hidden.' : 'Overlay shown.');
            fw_devProbe();
          } else if (action === 'rebuild') {
            fw_http('GET', msg.path || '/webpack-dev-server/invalidate').then(function(r) {
              done(r.ok, r.ok ? 'Compiler invalidated; a rebuild follows.' : 'The dev server answered HTTP ' + r.status + '.');
            }, fail);
          } else if (action === 'refreshSourceData') {
            fw_http('POST', msg.path || '/__refresh').then(function(r) {
              var text = r.ok ? 'Refresh requested.' : 'The dev server answered HTTP ' + r.status + '.';
              try { var body = JSON.parse(r.body); if (body && body.error) text = body.error; } catch(e) {}
              done(r.ok, text);
            }, fail);
          } else if (action === 'navigate') {
            fw_navigate(msg.strategy, String(msg.path || '/'), done, fail);
          } else {
            done(false, 'Unknown action ' + action + '.');
          }
        } catch(e) { fail(e); }
      };

      // Posts the restart, then watches the server's execution id change; Next reloads the page itself once it reconnects.
      ops['fw.devRestart'] = function(msg) {
        var action = String(msg.action || 'restartServer');
        function done(ok, message, pending) { post({ t: 'fw.devActionResult', action: action, ok: ok, message: message || '', pending: !!pending }); }
        var before = null;
        fw_http('GET', msg.statusPath).then(function(r) {
          try { before = JSON.parse(r.body).executionId; } catch(e) {}
          return fw_http('POST', msg.requestPath);
        }).then(function(r) {
          if (!r.ok) { done(false, 'The dev server answered HTTP ' + r.status + '.'); return; }
          done(true, 'Restart requested. Waiting for the server to come back.', true);
          var tries = 0;
          (function poll() {
            tries++;
            setTimeout(function() {
              fw_http('GET', msg.statusPath).then(function(s) {
                var after = null;
                try { after = JSON.parse(s.body).executionId; } catch(e) {}
                if (s.ok && (before === null || after !== before)) { done(true, 'Dev server restarted.'); return; }
                if (tries < 15) poll(); else done(false, 'The server did not restart within 15 s. It only restarts when started with next dev.');
              }, function() { if (tries < 15) poll(); else done(false, 'The server did not come back within 15 s.'); });
            }, 1000);
          })();
        }).catch(function(e) { done(false, fw_str(e && e.message || e)); });
      };

      // Vite injects import.meta.env as a literal at the top of every module that uses it, so one served module reveals it.
      ops['fw.devEnv'] = function() {
        function done(entries, message) { post({ t: 'fw.devEnv', entries: entries, message: message || '' }); }
        var urls = [];
        var seen = {};
        function add(u) {
          try {
            var x = new URL(u, location.href);
            if (x.origin !== location.origin || seen[x.href]) return;
            if (/node_modules|\/@vite\/|\/@react-refresh|\/@id\/|\.vite\/deps/.test(x.pathname)) return;
            if (!/\.(m?[jt]sx?|vue|svelte|astro)$/.test(x.pathname)) return;
            seen[x.href] = 1;
            urls.push(x.href);
          } catch(e) {}
        }
        try {
          Array.prototype.forEach.call(document.querySelectorAll('script[type="module"][src]'), function(s) { add(s.src); });
          (performance.getEntriesByType('resource') || []).forEach(function(e) { add(e.name); });
        } catch(e) {}
        urls = urls.slice(0, 40);
        if (!urls.length) { done([], 'No source modules from a Vite dev server were found on this page.'); return; }
        var index = 0;
        function next() {
          if (index >= urls.length) { done([], 'None of the ' + urls.length + ' loaded modules reads import.meta.env, so Vite did not inject it.'); return; }
          fw_http('GET', urls[index++], 200000).then(function(r) {
            var m = r.ok ? r.body.match(/import\.meta\.env\s*=\s*(\{[\s\S]*?\})\s*;/) : null;
            if (!m) { next(); return; }
            var obj;
            try { obj = JSON.parse(m[1]); } catch(e) { next(); return; }
            var entries = Object.keys(obj).map(function(k) { return { key: k, value: preview(obj[k], 1, new WeakSet()), source: 'import.meta.env' }; });
            done(entries, '');
          }, function() { next(); });
        }
        next();
      };

      inits.push(function fw_installDevObservers() {
        fw_epoch++;
        fw_hooked = typeof WeakSet === 'function' ? new WeakSet() : null;
        var live = { on: true };
        // Bumping the epoch also silences router and lifecycle hooks the page keeps calling after a detach.
        disposers.push(function() { live.on = false; fw_epoch++; });

        try {
          if (typeof WebSocket !== 'undefined') {
            var fwOrigWS = WebSocket;
            var fwWSWrap = function WebSocket(url, protocols) {
              var ws = protocols !== undefined ? new fwOrigWS(url, protocols) : new fwOrigWS(url);
              if (live.on) { try { fw_watchSocket(ws, String(url), protocols, 'WebSocket'); } catch(e) {} }
              return ws;
            };
            fwWSWrap.prototype = fwOrigWS.prototype;
            try { Object.setPrototypeOf(fwWSWrap, fwOrigWS); } catch(e) {}
            try { fwWSWrap.CONNECTING = fwOrigWS.CONNECTING; fwWSWrap.OPEN = fwOrigWS.OPEN; fwWSWrap.CLOSING = fwOrigWS.CLOSING; fwWSWrap.CLOSED = fwOrigWS.CLOSED; } catch(e) {}
            try { Object.defineProperty(fwWSWrap, 'name', { value: 'WebSocket', configurable: true }); } catch(e) {}
            try { Object.defineProperty(fwWSWrap, 'length', { value: 1, configurable: true }); } catch(e) {}
            window.WebSocket = fwWSWrap;
            disposers.push(function() { restoreIfOurs(window, 'WebSocket', fwWSWrap, fwOrigWS); });
          }
        } catch(e) {}

        try {
          if (typeof EventSource !== 'undefined') {
            var fwOrigES = EventSource;
            var fwESWrap = function EventSource(url, init) {
              var es = init !== undefined ? new fwOrigES(url, init) : new fwOrigES(url);
              if (live.on) { try { fw_watchSocket(es, String(url), [], 'EventSource'); } catch(e) {} }
              return es;
            };
            fwESWrap.prototype = fwOrigES.prototype;
            try { Object.setPrototypeOf(fwESWrap, fwOrigES); } catch(e) {}
            try { Object.defineProperty(fwESWrap, 'name', { value: 'EventSource', configurable: true }); } catch(e) {}
            try { Object.defineProperty(fwESWrap, 'length', { value: 1, configurable: true }); } catch(e) {}
            window.EventSource = fwESWrap;
            disposers.push(function() { restoreIfOurs(window, 'EventSource', fwESWrap, fwOrigES); });
          }
        } catch(e) {}

        try {
          var onError = function(e) {
            try {
              if (!live.on || fw_runtimeErrors++ >= 100) return;
              var err = e.error;
              fw_event('runtimeError', '', { message: fw_str(e.message || (err && err.message)), file: fw_str(e.filename),
                line: finite(e.lineno), col: finite(e.colno), stack: err && err.stack ? fw_str(err.stack).slice(0, 4000) : '' });
            } catch(x) {}
          };
          var onRejection = function(e) {
            try {
              if (!live.on || fw_runtimeErrors++ >= 100) return;
              var reason = e.reason;
              fw_event('unhandledRejection', '', { message: fw_errorMessage(reason) || 'Unhandled promise rejection',
                stack: reason && reason.stack ? fw_str(reason.stack).slice(0, 4000) : '' });
            } catch(x) {}
          };
          window.addEventListener('error', onError);
          window.addEventListener('unhandledrejection', onRejection);
          disposers.push(function() {
            window.removeEventListener('error', onError);
            window.removeEventListener('unhandledrejection', onRejection);
          });
        } catch(e) {}

        // Routers and lifecycle hooks appear as the app boots, so look a few times early on.
        [0, 400, 1500, 4000].forEach(function(delay) {
          setTimeout(function() { if (live.on) { try { fw_attachHooks(); } catch(e) {} } }, delay);
        });
        [300, 2500].forEach(function(delay) {
          setTimeout(function() { if (live.on) { try { fw_devProbe(); } catch(e) {} } }, delay);
        });
      });

      navHooks.push(function() {
        fw_event('navigate', location.pathname + location.search + location.hash);
        setTimeout(function() { try { fw_devProbe(); } catch(e) {} }, 300);
      });

    """##
}
