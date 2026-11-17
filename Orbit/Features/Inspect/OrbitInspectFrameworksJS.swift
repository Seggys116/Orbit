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



      var FW_SCAN_LIMIT = 6000;

      function fw_forEachElement(limit, visit) {
        var count = 0;
        try {
          var walker = document.createTreeWalker(document.documentElement, NodeFilter.SHOW_ELEMENT);
          var node = walker.currentNode;
          while (node && count < limit) {
            if (!(node.id === 'orbit-inspect-root')) {
              count++;
              if (visit(node) === false) break;
            }
            node = walker.nextNode();
          }
        } catch(e) {}
        return count;
      }

      // Attribute names that identify a framework or UI kit, recorded as markers.
      var fw_attrMarkers = [
        ['_ngcontent-', 'ngcontent'], ['_nghost-', 'ngcontent'], ['ng-reflect-', 'ng-reflect'],
        ['data-radix-', 'data-radix'], ['data-astro-cid-', 'data-astro-cid'], ['data-v-', 'data-v-*']
      ];
      var fw_exactAttrMarkers = {
        'data-v-app': 'data-v-app', 'data-server-rendered': 'data-server-rendered', 'data-hk': 'data-hk',
        'data-emotion': 'data-emotion', 'data-styled': 'data-styled', 'data-aos': 'data-aos', 'data-wf-site': 'data-wf-site',
        'data-wf-page': 'data-wf-page', 'data-controller': 'data-controller', 'wire:id': 'wire:id', 'data-theme': 'data-theme',
        'data-vite-dev-id': 'data-vite-dev-id', 'data-svelte-h': 'data-svelte-h'
      };

      // One bounded pass over the page's elements: which frameworks left their mark, and which class names are in use.
      function fw_scanPageElements() {
        var markers = {};
        var classTokens = {};
        var tokenCount = 0;
        var vueVersion = null;

        fw_forEachElement(FW_SCAN_LIMIT, function(el) {
          var keys;
          try { keys = Object.keys(el); } catch(e) { keys = []; }
          for (var i = 0; i < keys.length; i++) {
            var k = keys[i];
            if (k.charCodeAt(0) !== 95 && k.charCodeAt(0) !== 36) continue;
            if (k.indexOf('__reactFiber$') === 0 || k.indexOf('__reactInternalInstance$') === 0) markers['react-fiber'] = true;
            else if (k.indexOf('__reactContainer$') === 0 || k === '_reactRootContainer') markers['react-container'] = true;
            else if (k === '__vue_app__') {
              markers['vue3-root'] = true;
              try { if (!vueVersion && el.__vue_app__ && el.__vue_app__.version) vueVersion = fw_version(el.__vue_app__.version); } catch(e) {}
            }
            else if (k === '_vnode') {
              try { if (el._vnode && (el._vnode.shapeFlag !== undefined || el._vnode.component)) markers['vue3-root'] = true; } catch(e) {}
            }
            else if (k === '__vue__') markers['vue2-root'] = true;
            else if (k === '__k' || k === '_children') {
              try { var kids = el[k]; if (kids && typeof kids === 'object' && (Array.isArray(kids) || 'type' in kids || '__e' in kids || '_dom' in kids)) markers['preact-root'] = true; } catch(e) {}
            }
            else if (k === '__svelte_meta') markers['svelte-meta'] = true;
          }

          var attrs = el.attributes;
          if (attrs) {
            for (var a = 0; a < attrs.length; a++) {
              var name = attrs[a].name;
              var exact = fw_exactAttrMarkers[name];
              if (exact) { markers[exact] = true; if (name === 'data-theme') markers['data-theme'] = true; continue; }
              if (name === 'data-page' && el.id === 'app') { markers['data-page'] = true; markers['#app'] = true; continue; }
              for (var m = 0; m < fw_attrMarkers.length; m++) {
                if (name.indexOf(fw_attrMarkers[m][0]) === 0) { markers[fw_attrMarkers[m][1]] = true; break; }
              }
            }
          }

          var tag = el.localName || '';
          if (tag.indexOf('-') > 0) {
            markers['custom-element'] = true;
            if (tag === 'turbo-frame') markers['turbo-frame'] = true;
            try { if (el.renderRoot !== undefined && el.hasUpdated !== undefined) markers['lit-element'] = true; } catch(e) {}
          }

          if (tokenCount < 2500) {
            var cls = null;
            try { cls = el.getAttribute('class'); } catch(e) {}
            if (cls) {
              var parts = cls.split(/\s+/);
              for (var c = 0; c < parts.length; c++) {
                var token = parts[c];
                if (token && token.length <= 64 && !classTokens[token]) { classTokens[token] = 1; tokenCount++; }
              }
            }
          }
        });

        return { markers: Object.keys(markers), classTokens: Object.keys(classTokens), vueVersion: vueVersion };
      }

      // The first segment of every custom property the page's own stylesheets define: "tw" for --tw-ring-offset-width, "bs" for --bs-blue.
      function fw_cssVariablePrefixes() {
        var seen = {};
        var budget = 6000;
        function collect(rules, depth) {
          if (!rules) return;
          for (var i = 0; i < rules.length && budget > 0; i++) {
            budget--;
            var rule = rules[i];
            try {
              var text = rule.cssText || '';
              if (text.indexOf('@property') === 0) {
                var pm = /^@property\s+(--[A-Za-z0-9_-]+)/.exec(text);
                if (pm) seen[pm[1].slice(2).split('-')[0]] = true;
              }
              if (rule.style) {
                for (var j = 0; j < rule.style.length; j++) {
                  var prop = rule.style[j];
                  if (prop && prop.charCodeAt(0) === 45 && prop.charCodeAt(1) === 45) seen[prop.slice(2).split('-')[0]] = true;
                }
              }
              if (depth < 3 && rule.cssRules) collect(rule.cssRules, depth + 1);
            } catch(e) {}
          }
        }
        try {
          var sheets = document.styleSheets;
          for (var s = 0; s < sheets.length && s < 60; s++) {
            var sheetRules = null;
            try { sheetRules = sheets[s].cssRules; } catch(e) { continue; }
            collect(sheetRules, 0);
          }
          var adopted = document.adoptedStyleSheets || [];
          for (var ad = 0; ad < adopted.length && ad < 20; ad++) collect(adopted[ad].cssRules, 0);
        } catch(e) {}
        return Object.keys(seen).filter(function(p) { return p; }).slice(0, 80);
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
          '__STORYBOOK_PREVIEW__', '___loader', '___emitter', '___gatsby', '__astro_dev_toolbar__',
          'bootstrap', 'Shopify', 'Stripe', 'gtag', '_gaq', 'GoogleAnalyticsObject', 'dataLayer', 'google_tag_manager',
          'fbq', '_fbq', 'hj', '_hjSettings', 'mixpanel', 'amplitude', 'posthog', 'plausible', 'fathom', '_paq', 'Matomo',
          'clarity', 'Sentry', '__SENTRY__', 'DD_RUM', 'DD_LOGS', 'NREUM', 'newrelic', 'LogRocket', '_fs_namespace', 'Bugsnag',
          'Rollbar', '_rollbarConfig', '_hsq', 'hbspt', 'Intercom', 'drift', '$crisp', 'zE', 'zESettings', 'OneTrust',
          'OptanonWrapper', 'Cookiebot', 'grecaptcha', 'hcaptcha', 'turnstile', '_', 'moment', 'd3', 'THREE', 'gsap', 'Chart',
          'L', 'mapboxgl', 'Backbone', 'ko', 'firebase', 'Modernizr', 'Swiper', 'lottie', 'Ember', 'angular', 'Turbo',
          'Livewire', 'litHtmlVersions', '__REDUX_DEVTOOLS_EXTENSION__', '__VUE_DEVTOOLS_GLOBAL_HOOK__', '__svelte'
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
          ['__astro_dev_toolbar__.version', ['__astro_dev_toolbar__', 'version']],
          ['bootstrap.version', ['bootstrap', 'Tooltip', 'VERSION']],
          ['_.VERSION', ['_', 'VERSION']],
          ['moment.version', ['moment', 'version']],
          ['d3.version', ['d3', 'version']],
          ['THREE.REVISION', ['THREE', 'REVISION']],
          ['gsap.version', ['gsap', 'version']],
          ['Chart.version', ['Chart', 'version']],
          ['L.version', ['L', 'version']],
          ['mapboxgl.version', ['mapboxgl', 'version']],
          ['Backbone.VERSION', ['Backbone', 'VERSION']],
          ['ko.version', ['ko', 'version']],
          ['firebase.SDK_VERSION', ['firebase', 'SDK_VERSION']],
          ['Ember.VERSION', ['Ember', 'VERSION']],
          ['angular.version.full', ['angular', 'version', 'full']]
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

        var pageScan = fw_scanPageElements();
        pageScan.markers.forEach(function(marker) { if (domMarkers.indexOf(marker) < 0) domMarkers.push(marker); });
        try {
          // Svelte 5 records its version in a Set on window.__svelte.
          if (window.__svelte && window.__svelte.v && typeof window.__svelte.v.forEach === 'function') {
            window.__svelte.v.forEach(function(v) { if (!globalVersions['svelte.version']) globalVersions['svelte.version'] = fw_version(v); });
          }
        } catch(e) {}
        try {
          if (pageScan.vueVersion && !globalVersions['Vue.version']) globalVersions['Vue.version'] = pageScan.vueVersion;
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
          classTokens: pageScan.classTokens,
          cssVariablePrefixes: fw_cssVariablePrefixes(),
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

      // The FiberRoot a fibre belongs to, found by climbing to the top of its tree. Works in production, where no DevTools hook exists.
      function fw_rootFromFiber(fiber) {
        if (!fiber) return null;
        try {
          if (fiber.current && typeof fiber.tag !== 'number') return fiber;
          var cur = fiber;
          var guard = 0;
          while (cur.return && guard++ < 50000) cur = cur.return;
          if (cur.stateNode && cur.stateNode.current) return cur.stateNode;
          return cur.tag === 3 ? cur : null;
        } catch(e) { return null; }
      }

      function fw_findReactRoots() {
        var roots = [];
        var seen = new Set();
        function add(root) {
          if (root && !seen.has(root)) { seen.add(root); roots.push(root); }
        }

        // The DevTools hook knows every root, when something installed it before React loaded.
        try {
          var hook = window.__REACT_DEVTOOLS_GLOBAL_HOOK__;
          if (hook && hook.getFiberRoots) {
            hook.getFiberRoots(1).forEach(add);
          } else if (hook && hook.renderers) {
            hook.renderers.forEach(function(renderer) {
              if (renderer.getFiberRoots) renderer.getFiberRoots().forEach(add);
            });
          }
        } catch(e) {}

        // Every React 17+ DOM node carries its fibre and every root container carries its root, so a scan finds roots anywhere in
        // the page, in production builds and with no hook. React 16 and 17 legacy roots live on _reactRootContainer.
        fw_forEachElement(FW_SCAN_LIMIT, function(el) {
          var keys;
          try { keys = Object.keys(el); } catch(e) { return; }
          for (var i = 0; i < keys.length; i++) {
            var k = keys[i];
            if (k.charCodeAt(0) !== 95) continue;
            if (k.indexOf('__reactContainer$') === 0) add(fw_rootFromFiber(el[k]));
            else if (k === '_reactRootContainer') { var legacy = el[k]; add(fw_rootFromFiber(legacy && (legacy._internalRoot || legacy))); }
            else if (k.indexOf('__reactFiber$') === 0 || k.indexOf('__reactInternalInstance$') === 0) add(fw_rootFromFiber(el[k]));
          }
        });
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

      // Accumulates a framework's component nodes into the shape the Components tab reads.
      function fw_makeTree(framework, cap) {
        var nodes = [];
        var byId = {};
        var roots = [];
        var state = { capped: false, minified: false };
        return {
          add: function(spec, parentId) {
            if (nodes.length >= cap) { state.capped = true; return null; }
            var id = nodes.length + 1;
            var node = {
              id: id, name: spec.name || 'Anonymous', isHost: false, key: spec.key == null ? null : fw_str(spec.key),
              domId: spec.domId == null ? null : spec.domId,
              src: spec.src || null, srcLine: spec.srcLine == null ? null : spec.srcLine, srcCol: spec.srcCol == null ? null : spec.srcCol,
              owner: spec.owner || null, props: spec.props || {}, hooks: spec.hooks || [], children: [],
              minified: !!spec.minified, framework: framework
            };
            if (spec.minified) state.minified = true;
            nodes.push(node);
            byId[id] = node;
            if (parentId != null && byId[parentId]) byId[parentId].children.push(id); else roots.push(id);
            return id;
          },
          count: function() { return nodes.length; },
          result: function() {
            if (nodes.length === 0) return null;
            return { framework: framework, nodes: nodes, roots: roots, minified: state.minified, capped: state.capped, cappedAt: cap };
          }
        };
      }

      function fw_previewProps(source, skip) {
        var props = {};
        try {
          if (source && typeof source === 'object') {
            Object.keys(source).filter(function(k) { return k !== skip; }).slice(0, 20).forEach(function(k) {
              try { props[k] = preview(source[k], 2, new WeakSet()); } catch(e) { props[k] = '?'; }
            });
          }
        } catch(e) {}
        return props;
      }

      function fw_basename(path) {
        var text = fw_str(path);
        if (!text) return '';
        var last = text.split(/[\\/]/).pop() || '';
        return last.replace(/\.(vue|svelte|jsx?|tsx?|mjs)(\?.*)?$/, '');
      }

      function fw_elementId(el) {
        try { if (el && el.nodeType === 1) return idOf(el); } catch(e) {}
        return null;
      }

      function fw_isClassFiber(fiber) {
        try { return typeof fiber.type === 'function' && !!(fiber.type.prototype && fiber.type.prototype.isReactComponent); } catch(e) { return false; }
      }

      function fw_walkReactTree() {
        var roots = fw_findReactRoots();
        if (roots.length === 0) return null;
        var tree = fw_makeTree('react', 3000);
        var componentTags = { 0: 1, 1: 1, 2: 1, 11: 1, 14: 1, 15: 1 };

        function walk(fiber, parentId) {
          var guard = 0;
          var cur = fiber;
          while (cur && guard++ < 100000) {
            var passId = parentId;
            var isHost = typeof cur.type === 'string';
            var name = isHost ? null : fw_fiberName(cur);
            if (!name && !isHost && componentTags[cur.tag] && (typeof cur.type === 'function' || typeof cur.type === 'object')) name = 'Anonymous';
            if (name) {
              var spec = { name: name, key: cur.key, props: {}, hooks: [], minified: name.length <= 2 && /^[a-z]/.test(name) };
              try { if (cur.stateNode && cur.stateNode.nodeType) spec.domId = fw_elementId(cur.stateNode); } catch(e) {}
              if (spec.domId == null) {
                // A component renders into its first host descendant.
                try {
                  var host = cur.child;
                  var hostGuard = 0;
                  while (host && typeof host.type !== 'string' && hostGuard++ < 200) host = host.child;
                  if (host && host.stateNode) spec.domId = fw_elementId(host.stateNode);
                } catch(e) {}
              }
              try {
                if (cur._debugSource) {
                  spec.src = fw_str(cur._debugSource.fileName || '');
                  spec.srcLine = finite(cur._debugSource.lineNumber);
                  spec.srcCol = finite(cur._debugSource.columnNumber);
                } else if (cur._debugStack && cur._debugStack.stack) {
                  var line = fw_str(cur._debugStack.stack).split('\n')[1] || '';
                  var m = line.match(/\((.+):(\d+):(\d+)\)$/) || line.match(/at (.+):(\d+):(\d+)$/);
                  if (m) { spec.src = m[1]; spec.srcLine = parseInt(m[2], 10); spec.srcCol = parseInt(m[3], 10); }
                }
              } catch(e) {}
              try { if (cur._debugOwner) spec.owner = fw_fiberName(cur._debugOwner) || null; } catch(e) {}
              spec.props = fw_previewProps(cur.memoizedProps, 'children');
              try {
                if (cur.memoizedState != null) {
                  if (fw_isClassFiber(cur)) spec.hooks = [{ i: 0, l: 'state', v: preview(cur.memoizedState, 2, new WeakSet()) }];
                  else if (cur.tag !== 10 && cur.tag !== 9) spec.hooks = fw_fiberHooks(cur.memoizedState);
                }
              } catch(e) {}
              var id = tree.add(spec, parentId);
              if (id == null) return;
              passId = id;
            }
            if (cur.child) walk(cur.child, passId);
            cur = cur.sibling;
          }
        }

        roots.forEach(function(r) { walk(r.current ? r.current : r, null); });
        return tree.result();
      }

      function fw_findVue3Roots() {
        var instances = [];
        var seen = new Set();
        function add(inst) { if (inst && !seen.has(inst)) { seen.add(inst); instances.push(inst); } }
        try { if (window.__vue_app__ && window.__vue_app__._instance) add(window.__vue_app__._instance); } catch(e) {}
        try {
          var hook = window.__VUE_DEVTOOLS_GLOBAL_HOOK__;
          if (hook && hook.apps) hook.apps.forEach(function(entry) { var app = entry && (entry.app || entry); if (app && app._instance) add(app._instance); });
        } catch(e) {}
        // The root container keeps its vnode in every build, and the vnode points at the root component instance.
        fw_forEachElement(FW_SCAN_LIMIT, function(el) {
          try {
            if (el.__vue_app__ && el.__vue_app__._instance) add(el.__vue_app__._instance);
            else if (el._vnode && el._vnode.component) add(el._vnode.component);
          } catch(e) {}
        });
        return instances;
      }

      function fw_walkVue3Tree() {
        var instances = fw_findVue3Roots();
        if (instances.length === 0) return null;
        var tree = fw_makeTree('vue', 3000);
        var seen = new Set();

        function visitInstance(inst, parentId) {
          if (!inst || seen.has(inst)) return;
          seen.add(inst);
          var type = inst.type || {};
          var file = fw_str(type.__file || '');
          var name = fw_str(type.name || type.__name || fw_basename(file) || (inst.parent ? 'Anonymous' : 'Root'));
          var hooks = [];
          try {
            var setup = inst.setupState;
            if (setup && typeof setup === 'object') {
              Object.keys(setup).slice(0, 30).forEach(function(k, i) {
                var v = setup[k];
                if (typeof v === 'function') return;
                hooks.push({ i: i, l: 'state', v: k + ': ' + preview(v, 2, new WeakSet()) });
              });
            }
            var data = inst.data;
            if (data && typeof data === 'object') {
              Object.keys(data).slice(0, 30).forEach(function(k, i) {
                hooks.push({ i: hooks.length, l: 'data', v: k + ': ' + preview(data[k], 2, new WeakSet()) });
              });
            }
          } catch(e) {}
          var el = null;
          try { el = inst.vnode && inst.vnode.el; if (el && el.nodeType !== 1) el = inst.subTree && inst.subTree.el; } catch(e) {}
          var id = tree.add({
            name: name, key: inst.vnode && inst.vnode.key, domId: fw_elementId(el), src: file,
            props: fw_previewProps(inst.props), hooks: hooks, minified: name.length <= 2 && /^[a-z]/.test(name)
          }, parentId);
          if (id == null) return;
          visitVNode(inst.subTree, id);
        }

        function visitVNode(vnode, parentId) {
          if (!vnode || typeof vnode !== 'object') return;
          if (vnode.component) { visitInstance(vnode.component, parentId); return; }
          try { if (vnode.suspense && vnode.suspense.activeBranch) visitVNode(vnode.suspense.activeBranch, parentId); } catch(e) {}
          var kids = vnode.children;
          if (Array.isArray(kids)) for (var i = 0; i < kids.length; i++) visitVNode(kids[i], parentId);
        }

        instances.forEach(function(inst) { visitInstance(inst, null); });
        return tree.result();
      }

      function fw_walkVue2Roots() {
        var roots = [];
        var seen = new Set();
        fw_forEachElement(FW_SCAN_LIMIT, function(el) {
          try {
            var vm = el.__vue__;
            if (vm && vm.$root && !seen.has(vm.$root)) { seen.add(vm.$root); roots.push(vm.$root); }
          } catch(e) {}
        });
        return roots;
      }

      function fw_walkVue2Tree() {
        var roots = fw_walkVue2Roots();
        if (roots.length === 0) return null;
        var tree = fw_makeTree('vue', 3000);

        function visit(vm, parentId) {
          if (!vm) return;
          var options = vm.$options || {};
          var file = fw_str(options.__file || '');
          var name = fw_str(options.name || options._componentTag || fw_basename(file) || (vm === vm.$root ? 'Root' : 'Anonymous'));
          var hooks = [];
          try {
            var data = vm._data;
            if (data && typeof data === 'object') {
              Object.keys(data).slice(0, 30).forEach(function(k, i) {
                hooks.push({ i: i, l: 'data', v: k + ': ' + preview(data[k], 2, new WeakSet()) });
              });
            }
          } catch(e) {}
          var id = tree.add({
            name: name, domId: fw_elementId(vm.$el), src: file,
            props: fw_previewProps(vm.$props || options.propsData), hooks: hooks, minified: name.length <= 2 && /^[a-z]/.test(name)
          }, parentId);
          if (id == null) return;
          (vm.$children || []).forEach(function(child) { visit(child, id); });
        }
        roots.forEach(function(vm) { visit(vm, null); });
        return tree.result();
      }

      function fw_walkPreactTree() {
        var containers = [];
        fw_forEachElement(FW_SCAN_LIMIT, function(el) {
          try {
            var root = el.__k || el._children;
            if (root && typeof root === 'object' && (Array.isArray(root) || 'type' in root || '__e' in root || '_dom' in root)) containers.push(root);
          } catch(e) {}
        });
        if (containers.length === 0) return null;
        var tree = fw_makeTree('preact', 3000);
        var seen = new Set();

        function visit(vnode, parentId) {
          if (!vnode || typeof vnode !== 'object' || seen.has(vnode)) return;
          seen.add(vnode);
          var passId = parentId;
          var type = vnode.type;
          if (typeof type === 'function') {
            var name = fw_str(type.displayName || type.name || 'Anonymous');
            var inst = vnode.__c || vnode._component;
            var hooks = [];
            try {
              if (inst && inst.state && typeof inst.state === 'object') hooks.push({ i: 0, l: 'state', v: preview(inst.state, 2, new WeakSet()) });
            } catch(e) {}
            var dom = vnode.__e || vnode._dom;
            var id = tree.add({
              name: name, key: vnode.key, domId: fw_elementId(dom), props: fw_previewProps(vnode.props, 'children'),
              hooks: hooks, minified: name.length <= 2 && /^[a-z]/.test(name)
            }, parentId);
            if (id == null) return;
            passId = id;
          }
          var kids = vnode.__k || vnode._children;
          if (Array.isArray(kids)) for (var i = 0; i < kids.length; i++) visit(kids[i], passId);
        }
        containers.forEach(function(root) {
          if (Array.isArray(root)) root.forEach(function(v) { visit(v, null); }); else visit(root, null);
        });
        return tree.result();
      }

      // Angular only exposes its component instances through the ng debugging API, which development builds provide.
      function fw_walkAngularTree() {
        var ng = window.ng;
        if (!ng || typeof ng.getComponent !== 'function') return null;
        var hosts = document.querySelectorAll('[ng-version]');
        if (!hosts.length) return null;
        var tree = fw_makeTree('angular', 2000);
        var budget = FW_SCAN_LIMIT;

        function visit(el, parentId) {
          if (!el || el.nodeType !== 1 || budget-- <= 0) return;
          var passId = parentId;
          var instance = null;
          try { instance = ng.getComponent(el); } catch(e) {}
          if (instance) {
            var ctor = instance.constructor;
            var name = fw_str(ctor && ctor.name || el.localName);
            var props = {};
            var hooks = [];
            try {
              Object.keys(instance).slice(0, 30).forEach(function(k, i) {
                var v = instance[k];
                if (typeof v === 'function') return;
                hooks.push({ i: i, l: 'state', v: k + ': ' + preview(v, 2, new WeakSet()) });
              });
            } catch(e) {}
            props['selector'] = fw_str(el.localName);
            var id = tree.add({ name: name, domId: fw_elementId(el), props: props, hooks: hooks, minified: name.length <= 2 && /^[a-z]/.test(name) }, parentId);
            if (id == null) return;
            passId = id;
          }
          for (var c = el.firstElementChild; c; c = c.nextElementSibling) visit(c, passId);
        }
        for (var i = 0; i < hosts.length; i++) visit(hosts[i], null);
        return tree.result();
      }

      function fw_walkAstroIslands() {
        var islands = document.querySelectorAll('astro-island');
        if (!islands.length) return null;
        var tree = fw_makeTree('astro', 500);
        for (var i = 0; i < islands.length; i++) {
          var el = islands[i];
          var props = {};
          try {
            var rawProps = el.getAttribute('props');
            if (rawProps) props = fw_previewProps(JSON.parse(rawProps));
          } catch(e) {}
          props['client'] = fw_str(el.getAttribute('client') || 'load');
          var url = fw_str(el.getAttribute('component-url') || '');
          tree.add({
            name: fw_str(el.getAttribute('component-export') || fw_basename(url) || 'AstroIsland'),
            domId: fw_elementId(el), src: url, props: props
          }, null);
        }
        return tree.result();
      }

      // Svelte compiles components away. A development build marks each element with the file it came from, which at least
      // names the components in play and where their markup is.
      function fw_walkSvelteDev() {
        var byFile = {};
        var order = [];
        fw_forEachElement(FW_SCAN_LIMIT, function(el) {
          try {
            var meta = el.__svelte_meta;
            if (!meta || !meta.loc || !meta.loc.file) return;
            var file = fw_str(meta.loc.file);
            if (!byFile[file]) { byFile[file] = { count: 0, first: el, line: meta.loc.line }; order.push(file); }
            byFile[file].count++;
          } catch(e) {}
        });
        if (!order.length) return null;
        var tree = fw_makeTree('svelte', 500);
        order.forEach(function(file) {
          var entry = byFile[file];
          tree.add({
            name: fw_basename(file) || file, domId: fw_elementId(entry.first), src: file,
            srcLine: finite(entry.line), props: { elements: String(entry.count) }
          }, null);
        });
        return tree.result();
      }

      // Last resort and the whole story for Lit, Stencil and hand-written components: the custom elements, nested as they are on the page, shadow roots included.
      function fw_walkCustomElements() {
        var tree = fw_makeTree('webcomponents', 1500);
        var budget = FW_SCAN_LIMIT;
        function visit(node, parentId) {
          if (!node || budget-- <= 0) return;
          var passId = parentId;
          if (node.nodeType === 1) {
            var tag = node.localName || '';
            if (tag.indexOf('-') > 0 && tag !== 'astro-island') {
              var props = {};
              try {
                var attrs = node.attributes;
                for (var a = 0; a < attrs.length && a < 20; a++) props[attrs[a].name] = fw_str(attrs[a].value).slice(0, 120);
              } catch(e) {}
              var ctorName = '';
              try { ctorName = fw_str(window.customElements && customElements.get(tag) && customElements.get(tag).name); } catch(e) {}
              if (ctorName && ctorName !== tag) props['class'] = ctorName;
              var id = tree.add({ name: '<' + tag + '>', domId: fw_elementId(node), props: props }, parentId);
              if (id == null) return;
              passId = id;
            }
            if (node.shadowRoot) for (var s = node.shadowRoot.firstElementChild; s; s = s.nextElementSibling) visit(s, passId);
          }
          for (var c = node.firstElementChild; c; c = c.nextElementSibling) visit(c, passId);
        }
        visit(document.documentElement, null);
        return tree.result();
      }

      // Why there is no tree, in terms of what the page actually has.
      function fw_treeNote() {
        var notes = [];
        try {
          var scan = fw_scanPageElements();
          var has = function(m) { return scan.markers.indexOf(m) >= 0; };
          if (document.querySelector('[ng-version]') && !(window.ng && window.ng.getComponent)) {
            notes.push('Angular is running a production build. Angular only exposes its component tree through the ng debugging API, which is present in development builds.');
          }
          if (scan.classTokens.some(function(t) { return /^svelte-[a-z0-9]{4,10}$/.test(t); }) && !has('svelte-meta')) {
            notes.push('Svelte compiles components away. Only development builds mark elements with the component file they came from.');
          }
          if (document.querySelector('[q\\:container]')) notes.push('Qwik resumes from serialised state and has no client component tree to inspect.');
          if (has('data-hk') || window.Solid || window._$getOwner) notes.push('Solid keeps no component tree at runtime.');
          if (!notes.length) notes.push('Scanned the page for React, Vue 2 and 3, Preact, Angular, Svelte, Astro islands and custom elements, and found none mounted.');
        } catch(e) {}
        return notes.join(' ');
      }

      ops['fw.tree'] = function(msg) {
        var walkers = [fw_walkReactTree, fw_walkVue3Tree, fw_walkVue2Tree, fw_walkPreactTree, fw_walkAngularTree,
                       fw_walkAstroIslands, fw_walkSvelteDev, fw_walkCustomElements];
        var result = null;
        for (var i = 0; i < walkers.length && !result; i++) {
          try { result = walkers[i](); } catch(e) {}
        }
        post({ t: 'fw.tree', result: result, note: result ? null : fw_treeNote() });
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


      // JSON.stringify that survives what real pages hold: cycles, DOM nodes, Maps and Sets, functions, proxies, enormous arrays.
      function fw_safeJSON(value) {
        var budget = { nodes: 30000 };
        var active = new WeakSet();
        function keyString(key) { try { return typeof key === 'object' ? '[object]' : String(key); } catch(e) { return '?'; } }
        function copy(v, depth) {
          if (v === undefined) return '[undefined]';
          if (v === null) return null;
          var t = typeof v;
          if (t === 'string') return v.length > 4000 ? v.slice(0, 4000) + '…[' + v.length + ' chars]' : v;
          if (t === 'number') return isFinite(v) ? v : String(v);
          if (t === 'boolean') return v;
          if (t === 'bigint') return String(v) + 'n';
          if (t === 'symbol') return String(v);
          if (t === 'function') return '[Function ' + (v.name || 'anonymous') + ']';
          if (budget.nodes-- <= 0) return '[truncated]';
          if (active.has(v)) return '[Circular]';
          try { if (v.nodeType === 1) return '[Element <' + v.localName + (v.id ? '#' + v.id : '') + '>]'; if (v.nodeType) return '[Node]'; } catch(e) {}
          if (depth <= 0) return Array.isArray(v) ? '[Array(' + v.length + ')]' : '[Object]';
          active.add(v);
          var out;
          try {
            if (v instanceof Date) out = isNaN(v) ? 'Invalid Date' : v.toISOString();
            else if (v instanceof Error) out = { name: v.name, message: v.message };
            else if (v instanceof Map) {
              out = {}; var mi = 0;
              v.forEach(function(val, key) { if (mi++ < 300) out[keyString(key)] = copy(val, depth - 1); });
            } else if (v instanceof Set) {
              out = []; var si = 0;
              v.forEach(function(val) { if (si++ < 300) out.push(copy(val, depth - 1)); });
            } else if (Array.isArray(v)) {
              out = [];
              for (var i = 0; i < v.length && i < 500; i++) out.push(copy(v[i], depth - 1));
              if (v.length > 500) out.push('…' + (v.length - 500) + ' more');
            } else if (ArrayBuffer.isView(v)) {
              out = '[' + v.constructor.name + '(' + v.length + ')]';
            } else {
              out = {};
              var keys = Object.keys(v);
              for (var k = 0; k < keys.length && k < 300; k++) {
                try { out[keys[k]] = copy(v[keys[k]], depth - 1); } catch(e) { out[keys[k]] = '[unreadable]'; }
              }
              if (keys.length > 300) out['…'] = (keys.length - 300) + ' more keys';
            }
          } catch(e) { out = '[unreadable]'; }
          active.delete(v);
          return out;
        }
        try {
          var text = JSON.stringify(copy(value, 14), null, 2);
          if (text && text.length > 4000000) return JSON.stringify({ note: 'Too large to display', characters: text.length }, null, 2);
          return text;
        } catch(e) { return null; }
      }

      // The fibres' context providers, where stores such as Redux, React Query and Apollo are handed down to the tree.
      function fw_reactProviderValues(maxFibers) {
        var values = [];
        var visited = 0;
        try {
          fw_findReactRoots().forEach(function(root) {
            var stack = [root.current ? root.current : root];
            while (stack.length && visited < maxFibers) {
              var fiber = stack.pop();
              visited++;
              if (fiber.tag === 10) {
                try { var v = fiber.memoizedProps && fiber.memoizedProps.value; if (v && typeof v === 'object') values.push(v); } catch(e) {}
              }
              if (fiber.sibling) stack.push(fiber.sibling);
              if (fiber.child) stack.push(fiber.child);
            }
          });
        } catch(e) {}
        return values;
      }

      function fw_pageMetadata() {
        var info = { title: document.title || null, url: location.href, lang: document.documentElement.lang || null, charset: document.characterSet };
        var openGraph = {};
        var twitter = {};
        var other = {};
        var metas = document.querySelectorAll('meta');
        for (var i = 0; i < metas.length; i++) {
          var m = metas[i];
          var key = m.getAttribute('property') || m.getAttribute('name') || m.getAttribute('http-equiv') || (m.hasAttribute('charset') ? 'charset' : '');
          if (!key) continue;
          var content = m.getAttribute('content');
          if (content === null) content = m.getAttribute('charset');
          if (/^(og:|article:|product:|fb:)/.test(key)) openGraph[key] = content;
          else if (/^twitter:/.test(key)) twitter[key] = content;
          else other[key] = content;
        }
        if (Object.keys(openGraph).length) info.openGraph = openGraph;
        if (Object.keys(twitter).length) info.twitter = twitter;
        if (Object.keys(other).length) info.meta = other;
        var canonical = document.querySelector('link[rel~="canonical"]');
        if (canonical) info.canonical = canonical.href;
        var manifest = document.querySelector('link[rel~="manifest"]');
        if (manifest) info.manifest = manifest.href;
        function links(selector, pick) {
          var out = [];
          var list = document.querySelectorAll(selector);
          for (var j = 0; j < list.length && j < 40; j++) out.push(pick(list[j]));
          return out;
        }
        var icons = links('link[rel~="icon"], link[rel="apple-touch-icon"], link[rel="mask-icon"]', function(l) { return { rel: l.rel, href: l.href, sizes: l.sizes && l.sizes.value || undefined, type: l.type || undefined }; });
        if (icons.length) info.icons = icons;
        var alternates = links('link[rel~="alternate"]', function(l) { return { hreflang: l.hreflang || undefined, type: l.type || undefined, title: l.title || undefined, href: l.href }; });
        if (alternates.length) info.alternates = alternates;
        var hints = links('link[rel~="preconnect"], link[rel~="dns-prefetch"], link[rel~="preload"], link[rel~="modulepreload"], link[rel~="prefetch"]', function(l) { return l.rel + ' ' + l.href; });
        if (hints.length) info.resourceHints = hints;
        try {
          var scripts = document.scripts;
          var external = 0, modules = 0, inline = 0;
          for (var s = 0; s < scripts.length; s++) { if (scripts[s].src) external++; else inline++; if (scripts[s].type === 'module') modules++; }
          info.counts = {
            elements: document.getElementsByTagName('*').length, scripts: scripts.length, externalScripts: external, inlineScripts: inline,
            moduleScripts: modules, stylesheets: document.styleSheets.length, images: document.images.length, iframes: document.getElementsByTagName('iframe').length,
            forms: document.forms.length, links: document.links.length
          };
        } catch(e) {}
        return info;
      }

      function fw_extractData() {
        var items = [];
        function add(id, label, json, framework, kind) {
          if (json === null || json === undefined) return;
          items.push({ id: id, label: label, kind: kind || 'json', json: json, framework: framework || null });
        }
        var handled = {};
        function take(name, id, label, framework) {
          handled[name] = true;
          try {
            var v = window[name];
            if (v === undefined || v === null) return;
            add(id, label, fw_safeJSON(v), framework);
          } catch(e) {}
        }

        take('__NEXT_DATA__', 'next-page-data', 'Next.js Page Data', 'nextjs');

        try {
          if (window.__next_f && Array.isArray(window.__next_f) && window.__next_f.length > 0) {
            handled['__next_f'] = true;
            var chunks = window.__next_f.map(function(entry) {
              if (Array.isArray(entry) && entry.length >= 2) return fw_str(entry[1]);
              return fw_str(entry);
            }).filter(Boolean);
            items.push({ id: 'next-flight', label: 'RSC Flight Payload', kind: 'flight', chunks: chunks, framework: 'nextjs' });
          }
        } catch(e) {}

        // Nuxt removes window.__NUXT__ after hydration; the app's payload keeps the same data.
        try {
          var nuxt = window.__NUXT__;
          if (!nuxt && typeof window.useNuxtApp === 'function') { var app = window.useNuxtApp(); nuxt = app && (app.payload || app._payload); }
          handled['__NUXT__'] = true;
          if (nuxt) add('nuxt-payload', 'Nuxt Payload', fw_safeJSON(nuxt), 'nuxt');
        } catch(e) {}

        take('__remixContext', 'remix-context', 'Remix Context', 'remix');
        take('___gatsby', 'gatsby', 'Gatsby', 'gatsby');
        take('__REACT_QUERY_STATE__', 'react-query-state', 'React Query (dehydrated)', 'react-query');

        try {
          var apollo = window.__APOLLO_STATE__ || (window.__APOLLO_CLIENT__ && window.__APOLLO_CLIENT__.cache && window.__APOLLO_CLIENT__.cache.extract());
          handled['__APOLLO_STATE__'] = true; handled['__APOLLO_CLIENT__'] = true;
          if (apollo) add('apollo-state', 'Apollo Cache', fw_safeJSON(apollo), 'apollo');
        } catch(e) {}

        try {
          var redux = window.__REDUX_STATE__ || window.__PRELOADED_STATE__ || window.__INITIAL_STATE__;
          handled['__REDUX_STATE__'] = true; handled['__PRELOADED_STATE__'] = true; handled['__INITIAL_STATE__'] = true;
          if (redux) add('redux-state', 'Redux State (preloaded)', fw_safeJSON(redux), 'redux');
        } catch(e) {}

        // Live stores, read from where the framework keeps them.
        try {
          var vueRoots = fw_findVue3Roots();
          var storeSeen = new Set();
          vueRoots.forEach(function(inst, index) {
            var props = inst.appContext && inst.appContext.config && inst.appContext.config.globalProperties;
            if (!props) return;
            try {
              var pinia = props.$pinia;
              if (pinia && pinia.state && pinia.state.value && !storeSeen.has(pinia)) {
                storeSeen.add(pinia);
                add('pinia-' + index, 'Pinia Stores', fw_safeJSON(pinia.state.value), 'vue');
              }
            } catch(e) {}
            try {
              var vuex = props.$store;
              if (vuex && vuex.state && !storeSeen.has(vuex)) {
                storeSeen.add(vuex);
                add('vuex-' + index, 'Vuex Store', fw_safeJSON(vuex.state), 'vue');
              }
            } catch(e) {}
          });
        } catch(e) {}
        try {
          fw_walkVue2Roots().forEach(function(vm, index) {
            try { if (vm.$store && vm.$store.state) add('vuex2-' + index, 'Vuex Store', fw_safeJSON(vm.$store.state), 'vue'); } catch(e) {}
          });
        } catch(e) {}

        try {
          var reduxSeen = new Set(), queryClients = new Set(), apolloClients = new Set();
          fw_reactProviderValues(8000).forEach(function(value) {
            try {
              var store = (typeof value.getState === 'function' && typeof value.dispatch === 'function') ? value
                : (value.store && typeof value.store.getState === 'function' ? value.store : null);
              if (store && !reduxSeen.has(store)) {
                reduxSeen.add(store);
                add('redux-live-' + reduxSeen.size, 'Redux Store' + (reduxSeen.size > 1 ? ' #' + reduxSeen.size : ''), fw_safeJSON(store.getState()), 'redux');
              }
              var client = typeof value.getQueryCache === 'function' ? value : (value.queryClient && typeof value.queryClient.getQueryCache === 'function' ? value.queryClient : null);
              if (client && !queryClients.has(client)) {
                queryClients.add(client);
                var queries = client.getQueryCache().getAll().slice(0, 150).map(function(q) {
                  var state = q.state || {};
                  return { key: q.queryKey, status: state.status, fetchStatus: state.fetchStatus, updatedAt: state.dataUpdatedAt ? new Date(state.dataUpdatedAt).toISOString() : null, data: state.data, error: state.error ? fw_str(state.error.message || state.error) : null };
                });
                add('react-query-' + queryClients.size, 'React Query Cache' + (queryClients.size > 1 ? ' #' + queryClients.size : ''), fw_safeJSON(queries), 'react-query');
              }
              var apolloClient = value.client && value.client.cache && typeof value.client.cache.extract === 'function' ? value.client : null;
              if (apolloClient && !apolloClients.has(apolloClient)) {
                apolloClients.add(apolloClient);
                add('apollo-live-' + apolloClients.size, 'Apollo Cache (live)', fw_safeJSON(apolloClient.cache.extract()), 'apollo');
              }
            } catch(e) {}
          });
        } catch(e) {}

        try {
          if (Array.isArray(window.dataLayer) && window.dataLayer.length) {
            handled['dataLayer'] = true;
            add('data-layer', 'Tag Manager dataLayer', fw_safeJSON(window.dataLayer), null);
          }
        } catch(e) {}

        // Inertia hands each page's props to the client as JSON in data-page on the app root.
        try {
          var inertiaRoot = document.querySelector('[data-page]');
          if (inertiaRoot) {
            var page = JSON.parse(inertiaRoot.getAttribute('data-page'));
            if (page && typeof page === 'object') add('inertia-page', 'Inertia Page', fw_safeJSON(page), 'inertia');
          }
        } catch(e) {}

        // Every JSON script the page embeds: JSON-LD, Angular's ng-state, Qwik's resumable state, framework hydration payloads.
        try {
          var jsonScripts = document.querySelectorAll('script[type$="json"], script[type$="+json"]');
          for (var i = 0; i < jsonScripts.length && i < 40; i++) {
            var node = jsonScripts[i];
            var text = (node.textContent || '').trim();
            if (!text || node.id === '__NEXT_DATA__') continue;
            var kind = (node.getAttribute('type') || '').toLowerCase();
            var label = kind.indexOf('ld+json') >= 0 ? 'JSON-LD #' + (i + 1)
              : kind.indexOf('qwik') >= 0 ? 'Qwik State'
              : node.id === 'ng-state' ? 'Angular Transfer State'
              : 'JSON Script' + (node.id ? ' #' + node.id : ' #' + (i + 1));
            items.push({ id: 'json-script-' + i, label: label, kind: 'json', json: text, framework: kind.indexOf('qwik') >= 0 ? 'qwik' : (node.id === 'ng-state' ? 'angular' : null) });
          }
        } catch(e) {}

        try {
          var im = document.querySelector('script[type="importmap"]');
          if (im && im.textContent.trim()) items.push({ id: 'importmap', label: 'Import Map', kind: 'json', json: im.textContent.trim(), framework: null });
        } catch(e) {}

        try {
          var sr = document.querySelector('script[type="speculationrules"]');
          if (sr && sr.textContent.trim()) items.push({ id: 'speculationrules', label: 'Speculation Rules', kind: 'json', json: sr.textContent.trim(), framework: null });
        } catch(e) {}

        add('page-metadata', 'Page Metadata', fw_safeJSON(fw_pageMetadata()), null);

        // Global snapshot: non-standard window properties, with the ones that look like embedded application state offered as data of their own.
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
          var embedded = 0;
          try {
            Object.keys(window).forEach(function(k) {
              if (standard.has(k)) return;
              if (k.startsWith('__orbit')) return;
              var v;
              try { v = preview(window[k], 1, new WeakSet()); } catch(e) { v = '?'; }
              globs.push({ name: k, preview: v });
              if (handled[k] || embedded >= 12 || /^on[a-z]/.test(k)) return;
              if (!/(STATE|STORE|DATA|PAYLOAD|PRELOAD|BOOTSTRAP|INITIAL|HYDRAT|SETTINGS|CONFIG)/i.test(k)) return;
              try {
                var value = window[k];
                if (value && typeof value === 'object' && !value.nodeType && value !== window) {
                  var json = fw_safeJSON(value);
                  if (json && json.length > 2) { embedded++; add('embedded-' + k, 'Embedded data: ' + k, json, null); }
                }
              } catch(e) {}
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
