extension OrbitInspectAgent {
    static let animationsSource = ##"""
      // ----- animations (anim_) -----

      var anim_animMap = new WeakMap();   // Animation -> string id
      var anim_dataMap = new Map();       // id -> { data, currentTime, playState, gone }
      var anim_seqN = 0;
      var anim_activeIds = new Set();
      var anim_eventBuf = [];             // ring buffer cap 500
      var anim_pollTimer = null;
      var anim_pendingBatch = null;
      var anim_flushTimer = null;
      var anim_globalRate = 1;
      var anim_paused = false;
      var anim_pausedByUs = new Set();    // ids we paused via pauseAll

      // -- helpers --

      function anim_selectorOf(el) {
        if (!el || el.nodeType !== 1) return '';
        try {
          if (el.id) return '#' + el.id;
          var s = el.tagName.toLowerCase();
          if (typeof el.className === 'string' && el.className.trim()) {
            s += '.' + el.className.trim().split(/\s+/).slice(0, 2).join('.');
          }
          return s;
        } catch (e) { return ''; }
      }

      function anim_getAllLive() {
        try {
          if (typeof document.getAnimations !== 'function') return [];
          var anims;
          try { anims = document.getAnimations({ subtree: true }); }
          catch (e) { anims = document.getAnimations(); }
          var result = Array.prototype.slice.call(anims);
          // include same-origin iframes
          try {
            var frames = document.querySelectorAll('iframe');
            for (var fi = 0; fi < frames.length; fi++) {
              try {
                var fdoc = frames[fi].contentDocument;
                if (fdoc && typeof fdoc.getAnimations === 'function') {
                  var fa;
                  try { fa = fdoc.getAnimations({ subtree: true }); } catch (e) { fa = fdoc.getAnimations(); }
                  Array.prototype.push.apply(result, Array.prototype.slice.call(fa));
                }
              } catch (e) {}
            }
          } catch (e) {}
          return result;
        } catch (e) { return []; }
      }

      function anim_serializeAnimation(anim, id) {
        try {
          var type = 'waapi';
          var name = '';
          var properties = [];
          var nodeId = 0;
          var label = '';
          var selector = '';

          if ('animationName' in anim) { type = 'css'; name = String(anim.animationName || ''); }
          else if ('transitionProperty' in anim) { type = 'transition'; name = String(anim.transitionProperty || ''); }

          var effect = anim.effect;
          if (effect && effect.target) {
            nodeId = idOf(effect.target);
            label = nodeLabel(effect.target);
            selector = anim_selectorOf(effect.target);
          }

          var timing = { duration: 0, delay: 0, endDelay: 0, iterations: 1, iterationStart: 0,
                         direction: 'normal', fill: 'none', easing: 'linear', composite: 'replace' };
          if (effect && typeof effect.getTiming === 'function') {
            try {
              var t = effect.getTiming();
              if (t) {
                if (typeof t.duration === 'number' && isFinite(t.duration)) timing.duration = t.duration;
                else if (typeof t.duration === 'string' && t.duration === 'auto') timing.duration = 0;
                if (typeof t.delay === 'number') timing.delay = finite(t.delay) || 0;
                if (typeof t.endDelay === 'number') timing.endDelay = finite(t.endDelay) || 0;
                if (typeof t.iterations === 'number') timing.iterations = isFinite(t.iterations) ? t.iterations : -1;
                if (typeof t.iterationStart === 'number') timing.iterationStart = finite(t.iterationStart) || 0;
                if (typeof t.direction === 'string') timing.direction = t.direction;
                if (typeof t.fill === 'string') timing.fill = t.fill;
                if (typeof t.easing === 'string') timing.easing = t.easing;
                if (typeof t.composite === 'string') timing.composite = t.composite;
              }
            } catch (e) {}
          }

          var keyframes = [];
          if (effect && typeof effect.getKeyframes === 'function') {
            try {
              var kfs = effect.getKeyframes();
              keyframes = Array.prototype.slice.call(kfs, 0, 60).map(function (kf, i) {
                var props = {};
                Object.keys(kf).forEach(function (k) {
                  if (k !== 'offset' && k !== 'computedOffset' && k !== 'easing' && k !== 'composite') {
                    props[k] = String(kf[k]);
                    if (properties.indexOf(k) < 0) properties.push(k);
                  }
                });
                return {
                  offset: finite(kf.offset),
                  computedOffset: finite(kf.computedOffset) || 0,
                  easing: String(kf.easing || 'linear'),
                  props: props
                };
              });
            } catch (e) {}
          }
          if (type === 'transition' && properties.length === 0 && name) properties = [name];
          if (type === 'waapi' && properties.length > 0 && !name) name = properties[0];

          var timelineKind = 'document';
          try {
            if (typeof ScrollTimeline !== 'undefined' && anim.timeline instanceof ScrollTimeline) timelineKind = 'scroll';
            else if (typeof ViewTimeline !== 'undefined' && anim.timeline instanceof ViewTimeline) timelineKind = 'view';
          } catch (e) {}

          return {
            id: id,
            type: type,
            nodeId: nodeId,
            label: label,
            selector: selector,
            name: name || id,
            props: properties.slice(0, 20),
            playState: String(anim.playState || 'idle'),
            rate: finite(anim.playbackRate) || 1,
            duration: timing.duration,
            delay: timing.delay,
            endDelay: timing.endDelay,
            iterations: timing.iterations,
            iterationStart: timing.iterationStart,
            direction: timing.direction,
            fill: timing.fill,
            easing: timing.easing,
            composite: timing.composite,
            currentTime: finite(typeof anim.currentTime === 'number' ? anim.currentTime : null),
            startTime: finite(typeof anim.startTime === 'number' ? anim.startTime : null),
            keyframes: keyframes,
            timelineKind: timelineKind,
            scrollSource: '',
            gone: false
          };
        } catch (e) { return null; }
      }

      function anim_getPendingBatch() {
        if (!anim_pendingBatch) {
          anim_pendingBatch = { add: [], update: [], events: [] };
          if (!anim_flushTimer) {
            anim_flushTimer = setTimeout(anim_flush, 100);
          }
        }
        return anim_pendingBatch;
      }

      function anim_flush() {
        anim_flushTimer = null;
        if (!anim_pendingBatch) return;
        var batch = anim_pendingBatch;
        anim_pendingBatch = null;
        if (batch.add.length || batch.update.length || batch.events.length) {
          post({ t: 'anim.batch', add: batch.add, update: batch.update, events: batch.events, clear: false });
        }
      }

      function anim_findById(id) {
        var all = anim_getAllLive();
        for (var i = 0; i < all.length; i++) {
          if (anim_animMap.get(all[i]) === id) return all[i];
        }
        return null;
      }

      function anim_poll() {
        try {
          var allAnims = anim_getAllLive();
          var newActiveIds = new Set();
          var batch = anim_getPendingBatch();

          for (var i = 0; i < allAnims.length; i++) {
            var anim = allAnims[i];
            try {
              var id = anim_animMap.get(anim);
              var currentTime = finite(typeof anim.currentTime === 'number' ? anim.currentTime : null);
              var playState = String(anim.playState || 'idle');

              if (!id) {
                id = 'a' + (++anim_seqN);
                anim_animMap.set(anim, id);
                var data = anim_serializeAnimation(anim, id);
                if (data) {
                  anim_dataMap.set(id, { data: data, currentTime: currentTime, playState: playState, gone: false });
                  // Cap map at 500, evict oldest gone
                  if (anim_dataMap.size > 500) {
                    var oldest = null;
                    anim_dataMap.forEach(function (v, k) { if (!oldest && v.gone) oldest = k; });
                    if (oldest) anim_dataMap.delete(oldest);
                  }
                  // Apply current global rate and pause state
                  try { if (anim_globalRate !== 1) anim.playbackRate = anim_globalRate; } catch (e) {}
                  if (anim_paused) { try { anim.pause(); anim_pausedByUs.add(id); } catch (e) {} }
                  batch.add.push(data);
                }
              } else {
                var entry = anim_dataMap.get(id);
                if (entry) {
                  var changed = entry.playState !== playState || entry.currentTime !== currentTime;
                  entry.playState = playState;
                  entry.currentTime = currentTime;
                  if (changed) {
                    batch.update.push({ id: id, playState: playState, currentTime: currentTime });
                  }
                }
              }
              newActiveIds.add(id);
            } catch (e) {}
          }

          // Mark disappeared animations as gone
          anim_activeIds.forEach(function (id) {
            if (!newActiveIds.has(id)) {
              var entry = anim_dataMap.get(id);
              if (entry && !entry.gone) {
                entry.gone = true;
                batch.update.push({ id: id, playState: 'finished', currentTime: entry.currentTime, gone: true });
              }
            }
          });
          anim_activeIds = newActiveIds;
        } catch (e) {}
      }

      function anim_sendSnapshot() {
        var all = anim_getAllLive();
        var addList = [];
        var newIds = new Set();

        for (var i = 0; i < all.length; i++) {
          var anim = all[i];
          try {
            var id = anim_animMap.get(anim);
            if (!id) {
              id = 'a' + (++anim_seqN);
              anim_animMap.set(anim, id);
            }
            var data = anim_serializeAnimation(anim, id);
            if (data) {
              anim_dataMap.set(id, { data: data, currentTime: data.currentTime, playState: data.playState, gone: false });
              addList.push(data);
              newIds.add(id);
            }
          } catch (e) {}
        }
        // Include gone animations
        anim_dataMap.forEach(function (entry, id) {
          if (entry.gone) {
            addList.push(Object.assign({}, entry.data, { playState: 'finished', gone: true }));
          }
        });
        anim_activeIds = newIds;

        var recentEvents = anim_eventBuf.slice(-100);
        post({ t: 'anim.batch', add: addList, update: [], events: recentEvents, clear: true });
      }

      // -- event listeners (always-on, installed at document start) --

      inits.push(function () {
        var anim_eventTypes = [
          'animationstart', 'animationend', 'animationcancel', 'animationiteration',
          'transitionrun', 'transitionstart', 'transitionend', 'transitioncancel'
        ];

        function anim_onDOMEvent(e) {
          try {
            var label = (e.target && e.target.nodeType === 1) ? nodeLabel(e.target) : '';
            var name = String(e.animationName || e.propertyName || '');
            var elapsed = finite(e.elapsedTime) || 0;
            var ev = {
              id: 'ev' + Date.now() + '_' + (++anim_seqN),
              ts: Date.now(),
              type: e.type,
              label: label,
              name: name,
              elapsed: elapsed
            };
            anim_eventBuf.push(ev);
            if (anim_eventBuf.length > 500) anim_eventBuf.shift();
            var batch = anim_getPendingBatch();
            batch.events.push(ev);
          } catch (err) {}
        }

        for (var ei = 0; ei < anim_eventTypes.length; ei++) {
          document.addEventListener(anim_eventTypes[ei], anim_onDOMEvent, { capture: true, passive: true });
        }

        disposers.push(function () {
          for (var ei = 0; ei < anim_eventTypes.length; ei++) {
            document.removeEventListener(anim_eventTypes[ei], anim_onDOMEvent, { capture: true, passive: true });
          }
          if (anim_pollTimer) { clearInterval(anim_pollTimer); anim_pollTimer = null; }
          if (anim_flushTimer) { clearTimeout(anim_flushTimer); anim_flushTimer = null; }
        });
      });

      // -- ops --

      ops['anim.start'] = function (msg) {
        if (!anim_pollTimer) {
          anim_pollTimer = setInterval(anim_poll, 100);
        }
        anim_sendSnapshot();
      };

      ops['anim.stop'] = function (msg) {
        if (anim_pollTimer) { clearInterval(anim_pollTimer); anim_pollTimer = null; }
      };

      ops['anim.pauseAll'] = function (msg) {
        anim_paused = true;
        var all = anim_getAllLive();
        for (var i = 0; i < all.length; i++) {
          try {
            var id = anim_animMap.get(all[i]);
            if (id && all[i].playState === 'running') {
              all[i].pause();
              anim_pausedByUs.add(id);
            }
          } catch (e) {}
        }
      };

      ops['anim.resumeAll'] = function (msg) {
        anim_paused = false;
        var all = anim_getAllLive();
        for (var i = 0; i < all.length; i++) {
          try {
            var id = anim_animMap.get(all[i]);
            if (id && anim_pausedByUs.has(id)) {
              all[i].play();
              anim_pausedByUs.delete(id);
            }
          } catch (e) {}
        }
      };

      ops['anim.replayAll'] = function (msg) {
        var all = anim_getAllLive();
        for (var i = 0; i < all.length; i++) {
          try {
            var anim = all[i];
            if ('animationName' in anim) {
              // CSS animation: reset and play
              anim.currentTime = 0;
              anim.play();
            } else if ('transitionProperty' in anim) {
              // CSS transition: only replay if still active (not finished)
              if (anim.playState !== 'finished') {
                anim.currentTime = 0;
                anim.play();
              }
              // Finished transitions cannot be replayed without re-triggering via CSS
            } else {
              // WAAPI
              anim.cancel();
              anim.play();
            }
          } catch (e) {}
        }
      };

      ops['anim.setRate'] = function (msg) {
        var rate = (typeof msg.rate === 'number' && isFinite(msg.rate) && msg.rate > 0) ? msg.rate : 1;
        anim_globalRate = rate;
        var all = anim_getAllLive();
        for (var i = 0; i < all.length; i++) {
          try { all[i].playbackRate = rate; } catch (e) {}
        }
      };

      ops['anim.scrub'] = function (msg) {
        var time = finite(msg.time);
        if (time === null) return;
        var all = anim_getAllLive();
        for (var i = 0; i < all.length; i++) {
          try {
            if (all[i].playState !== 'finished') {
              all[i].currentTime = time;
            }
          } catch (e) {}
        }
      };

      ops['anim.clear'] = function (msg) {
        anim_dataMap.clear();
        anim_activeIds.clear();
        anim_eventBuf = [];
        post({ t: 'anim.batch', add: [], update: [], events: [], clear: true });
      };

      ops['anim.playOne'] = function (msg) {
        var anim = anim_findById(msg.id);
        if (anim) { try { anim.play(); } catch (e) {} }
      };

      ops['anim.pauseOne'] = function (msg) {
        var anim = anim_findById(msg.id);
        if (anim) { try { anim.pause(); } catch (e) {} }
      };

      ops['anim.replayOne'] = function (msg) {
        var anim = anim_findById(msg.id);
        if (!anim) return;
        try {
          if ('animationName' in anim) {
            anim.currentTime = 0;
            anim.play();
          } else if ('transitionProperty' in anim) {
            if (anim.playState !== 'finished') {
              anim.currentTime = 0;
              anim.play();
            }
          } else {
            anim.cancel();
            anim.play();
          }
        } catch (e) {}
      };

      ops['anim.finishOne'] = function (msg) {
        var anim = anim_findById(msg.id);
        if (anim) { try { anim.finish(); } catch (e) {} }
      };

      ops['anim.reverseOne'] = function (msg) {
        var anim = anim_findById(msg.id);
        if (anim) { try { anim.reverse(); } catch (e) {} }
      };

      ops['anim.cancelOne'] = function (msg) {
        var anim = anim_findById(msg.id);
        if (anim) { try { anim.cancel(); } catch (e) {} }
      };

      ops['anim.updateTiming'] = function (msg) {
        var anim = anim_findById(msg.id);
        if (!anim || !anim.effect || typeof anim.effect.updateTiming !== 'function') return;
        try {
          var update = {};
          if (typeof msg.duration === 'number' && isFinite(msg.duration)) update.duration = msg.duration;
          if (typeof msg.delay    === 'number' && isFinite(msg.delay))    update.delay    = msg.delay;
          if (typeof msg.endDelay === 'number' && isFinite(msg.endDelay)) update.endDelay = msg.endDelay;
          if (typeof msg.iterations === 'number') {
            update.iterations = (msg.iterations < 0) ? Infinity : msg.iterations;
          }
          if (typeof msg.easing    === 'string') update.easing    = msg.easing;
          if (typeof msg.direction === 'string') update.direction = msg.direction;
          if (typeof msg.fill      === 'string') update.fill      = msg.fill;
          if (Object.keys(update).length) anim.effect.updateTiming(update);
        } catch (e) {}
      };

      ops['anim.setKeyframes'] = function (msg) {
        var anim = anim_findById(msg.id);
        if (!anim || !anim.effect || typeof anim.effect.setKeyframes !== 'function') return;
        try {
          if (Array.isArray(msg.keyframes)) anim.effect.setKeyframes(msg.keyframes);
        } catch (e) {}
      };

      ops['anim.svgPause'] = function (msg) {
        try {
          if (document.documentElement && typeof document.documentElement.pauseAnimations === 'function') {
            document.documentElement.pauseAnimations();
          }
        } catch (e) {}
      };

      ops['anim.svgResume'] = function (msg) {
        try {
          if (document.documentElement && typeof document.documentElement.unpauseAnimations === 'function') {
            document.documentElement.unpauseAnimations();
          }
        } catch (e) {}
      };

    """##
}
