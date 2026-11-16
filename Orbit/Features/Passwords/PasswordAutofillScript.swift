import Foundation

/// The page half of password autofill. It runs in every frame, in its own content world (`orbit-passwords`), so the page cannot see or call it
/// and its globals are invisible to page scripts. It describes fields and sign-ins to native code and, when native code asks, fills a field;
/// it never holds a saved password until a fill is requested.
///
/// Injected at document start rather than document end: its listeners are on `document` and need no DOM, and starting first keeps its
/// `contextmenu` listener ahead of the context-menu probe's, so a field's description reaches native code before the click's own report.
enum PasswordAutofillScript {

    static let handlerName = "orbitPasswords"
    static let worldName = "orbit-passwords"
    /// What `fill` returns as its `reason` when the frame's live origin is not the one native code expected.
    static let originChangedReason = "origin-changed"
    /// A focus is reported only this soon after real input on or leading to the field.
    static let trustedFocusWindowMs = 1000
    /// A submit is captured only this soon after real input in the form.
    static let trustedSubmitWindowMs = 30_000

    static let source = template
        .replacingOccurrences(of: "__HANDLER__", with: handlerName)
        .replacingOccurrences(of: "__ORIGIN_CHANGED__", with: originChangedReason)
        .replacingOccurrences(of: "__FOCUS_WINDOW__", with: String(trustedFocusWindowMs))
        .replacingOccurrences(of: "__SUBMIT_WINDOW__", with: String(trustedSubmitWindowMs))

    // swiftlint:disable line_length
    private static let template = #"""
    (function () {
      'use strict';
      if (window.__orbitPasswords) { return; }
      var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.__HANDLER__;
      if (!bridge) { return; }

      var IDLE_MS = 15000;
      var FOCUS_WINDOW_MS = __FOCUS_WINDOW__;
      var SUBMIT_WINDOW_MS = __SUBMIT_WINDOW__;
      var HONEYPOT = /honey|\bhp[-_]?(field|input)?\b|\btrap\b|bot[-_]?(field|trap)|do[-_]?not[-_]?(fill|enter)|leave[-_]?(blank|empty)/i;
      var USERNAME = /user|login|log[-_ ]?in|e[-_ ]?mail|account|identifier|sign[-_ ]?in|member|customer|uname|handle|phone|mobile/;
      var NOT_USERNAME = /search|query|coupon|promo|captcha|street|billing|shipping|zip|postal|city|country|first[-_ ]?name|last[-_ ]?name|full[-_ ]?name|company|gift|card|quantity|cvv|cvc|verif/;
      var OTP = /otp|one[-_ ]?time|verification[-_ ]?code|verify[-_ ]?code|2fa|mfa|totp|sms[-_ ]?code|passcode|security[-_ ]?code|authenticator|\bpin\b/;
      var REVEALED_PASSWORD = /pass(word|wd)?\b|pwd/;
      var CONFIRM = /confirm|repeat|retype|verify|again|re[-_ ]?enter|match|password2|pass2/;
      var NEW_PASSWORD = /new[-_ ]?pass|create[-_ ]?pass|choose[-_ ]?pass|set[-_ ]?pass|\bnew\b/;
      var CURRENT_PASSWORD = /current|\bold\b|existing|previous|\bcur[-_ ]?pass/;
      var SIGNUP = /sign[-_ ]?up|regist|create[-_ ]?account|join|enroll|new[-_ ]?account/;
      var SIGNIN = /log[-_ ]?in|sign[-_ ]?in|authenticate|session/;
      var NOT_LOGIN_FORM = /newsletter|subscribe|subscription|search|contact|coupon|promo|feedback|comment|waitlist/;
      var SUBMIT_TEXT = /log[-_ ]?in|sign[-_ ]?in|submit|continue|next|register|sign[-_ ]?up|create|join|save|update|change|verify/i;

      var tokens = new Map();
      var elementTokens = new WeakMap();
      var seen = new WeakSet();
      var hooked = new WeakSet();
      var active = null;
      var watch = null;
      var filling = false;
      var lastSent = { sig: '', time: 0 };
      var childRelayed = false;
      var scrollScheduled = false;
      var watchTimer = 0;
      var attributeObserver = null;
      // Page script can call focus() and dispatch events, so only input the browser itself produced (isTrusted) counts as a person acting.
      var lastPointer = { time: 0, path: [] };
      var lastKeyTime = 0;
      var formInput = new WeakMap();

      function send(message) { try { bridge.postMessage(message); } catch (e) {} }
      function lower(value) { return String(value == null ? '' : value).toLowerCase(); }
      function attr(el, name) { return el.getAttribute(name) || ''; }
      function ref(el) { return typeof WeakRef === 'function' ? new WeakRef(el) : { deref: function () { return el; } }; }

      function newToken() {
        var words = new Uint32Array(4);
        crypto.getRandomValues(words);
        var text = '';
        for (var i = 0; i < words.length; i++) { text += ('00000000' + words[i].toString(16)).slice(-8); }
        return 'f' + text;
      }

      function tokenFor(el) {
        var token = elementTokens.get(el);
        if (!token) {
          token = newToken();
          elementTokens.set(el, token);
          tokens.set(token, ref(el));
          if (tokens.size > 256) {
            tokens.forEach(function (value, key) { if (!value.deref()) { tokens.delete(key); } });
          }
        }
        return token;
      }

      function elementFor(token) {
        var entry = tokens.get(token);
        return entry ? entry.deref() || null : null;
      }

      function eventTarget(event) {
        var path = typeof event.composedPath === 'function' ? event.composedPath() : null;
        var target = path && path.length ? path[0] : event.target;
        return target && target.nodeType === 1 ? target : null;
      }

      function deepActive() {
        var node = document.activeElement;
        while (node && node.shadowRoot && node.shadowRoot.activeElement) { node = node.shadowRoot.activeElement; }
        return node;
      }

      function isPasswordInput(el) { return el.type === 'password'; }

      function isCandidate(el) {
        if (!el || el.nodeType !== 1 || el.localName !== 'input') { return false; }
        var type = el.type;
        return type === 'password' || type === 'text' || type === 'email' || type === 'tel';
      }

      function isShown(el) {
        if (!el.isConnected || el.getClientRects().length === 0) { return false; }
        var style = window.getComputedStyle(el);
        return style.visibility !== 'hidden' && style.visibility !== 'collapse' && style.display !== 'none';
      }

      // Hidden, collapsed, transparent, off the page, aria-hidden or honeypot-named fields are never offered or filled.
      function isUsable(el) {
        if (!el.isConnected || el.disabled || el.readOnly) { return false; }
        if (HONEYPOT.test(attr(el, 'name') + ' ' + el.id + ' ' + String(el.className || ''))) { return false; }
        var tab = el.getAttribute('tabindex');
        if (tab !== null && Number(tab) < 0 && lower(attr(el, 'aria-hidden')) === 'true') { return false; }
        if (!isShown(el)) { return false; }
        var box = el.getBoundingClientRect();
        if (box.width < 6 || box.height < 6) { return false; }
        if (box.right + window.pageXOffset < 0 || box.bottom + window.pageYOffset < 0) { return false; }
        if (parseFloat(window.getComputedStyle(el).opacity) < 0.05) { return false; }
        var ancestor = el.parentElement;
        for (var depth = 0; ancestor && depth < 8; depth++) {
          if (lower(ancestor.getAttribute('aria-hidden')) === 'true') { return false; }
          if (parseFloat(window.getComputedStyle(ancestor).opacity) < 0.05) { return false; }
          ancestor = ancestor.parentElement;
        }
        return true;
      }

      function hintText(el) {
        var parts = [attr(el, 'name'), el.id, attr(el, 'placeholder'), attr(el, 'aria-label'), attr(el, 'title'), attr(el, 'autocomplete'), attr(el, 'data-testid'), attr(el, 'data-test')];
        try { if (el.labels && el.labels.length) { parts.push(String(el.labels[0].textContent).slice(0, 80)); } } catch (e) {}
        return parts.join(' ');
      }

      function autocompleteTokens(el) { return lower(attr(el, 'autocomplete')).split(/\s+/); }

      function inputsIn(root) {
        try { return Array.prototype.slice.call(root.querySelectorAll('input')); } catch (e) { return []; }
      }

      function scopeHint(scope) {
        if (!scope || scope.nodeType !== 1) { return ''; }
        return lower([scope.id, String(scope.className || ''), attr(scope, 'name'), attr(scope, 'action'), attr(scope, 'role')].join(' ')).slice(0, 240);
      }

      // The form, or for formless pages the smallest container that holds the login fields together.
      function scopeOf(el) {
        if (el.form) { return el.form; }
        var node = el.parentElement;
        var best = node || el;
        for (var depth = 0; node && depth < 10; depth++) {
          var list = inputsIn(node).filter(isCandidate);
          if (list.length > 8) { break; }
          best = node;
          var hasPassword = list.some(isPasswordInput);
          if (hasPassword && list.length >= 2) { break; }
          if (!hasPassword && depth >= 3) { break; }
          node = node.parentElement;
        }
        return best;
      }

      function fieldsIn(scope) {
        return inputsIn(scope).filter(isCandidate).filter(isUsable);
      }

      function isOneTimeCode(el) {
        if (autocompleteTokens(el).indexOf('one-time-code') >= 0) { return true; }
        if (el.maxLength === 1) { return true; }
        return OTP.test(lower(hintText(el)));
      }

      // 'username', 'otp' or '' for a text-like field.
      function textRole(el, fields, passwords, scope) {
        var tokensList = autocompleteTokens(el);
        if (isOneTimeCode(el)) { return 'otp'; }
        if (tokensList.indexOf('username') >= 0) { return 'username'; }
        var hint = lower(hintText(el));
        if (REVEALED_PASSWORD.test(hint) && !USERNAME.test(hint)) { return ''; }
        if (NOT_USERNAME.test(hint)) { return ''; }
        if (passwords.length > 0) {
          var first = passwords[0];
          var before = fields.filter(function (field) {
            return !isPasswordInput(field) && (field.compareDocumentPosition(first) & Node.DOCUMENT_POSITION_FOLLOWING) !== 0
              && !isOneTimeCode(field) && !NOT_USERNAME.test(lower(hintText(field)));
          });
          if (before.indexOf(el) < 0) { return ''; }
          if (USERNAME.test(hint) || tokensList.indexOf('email') >= 0) { return 'username'; }
          return before[before.length - 1] === el ? 'username' : '';
        }
        var context = scopeHint(scope);
        if (NOT_LOGIN_FORM.test(context)) { return ''; }
        if (tokensList.indexOf('email') >= 0 || USERNAME.test(hint)) { return 'username'; }
        return '';
      }

      function isConfirmField(el) { return CONFIRM.test(lower(hintText(el))); }

      function passwordKind(el, passwords, scope) {
        var tokensList = autocompleteTokens(el);
        if (tokensList.indexOf('new-password') >= 0) { return 'newPassword'; }
        if (tokensList.indexOf('current-password') >= 0) { return 'currentPassword'; }
        var hint = lower(hintText(el));
        if (CURRENT_PASSWORD.test(hint)) { return 'currentPassword'; }
        if (CONFIRM.test(hint) || NEW_PASSWORD.test(hint)) { return 'newPassword'; }
        if (passwords.length >= 2) {
          return passwords.length >= 3 && passwords.indexOf(el) === 0 ? 'currentPassword' : 'newPassword';
        }
        var context = scopeHint(scope);
        if (SIGNUP.test(context) && !SIGNIN.test(context)) { return 'newPassword'; }
        return 'currentPassword';
      }

      // { kind, scope, fields } for a field this script acts on, null for anything else.
      function classify(el) {
        if (!isCandidate(el) || !isUsable(el)) { return null; }
        var scope = scopeOf(el);
        var fields = fieldsIn(scope);
        if (fields.indexOf(el) < 0) { fields = [el]; }
        var passwords = fields.filter(isPasswordInput);
        if (isPasswordInput(el)) { return { kind: passwordKind(el, passwords, scope), scope: scope, fields: fields }; }
        return textRole(el, fields, passwords, scope) === 'username' ? { kind: 'username', scope: scope, fields: fields } : null;
      }

      function rectOf(el) {
        var box = el.getBoundingClientRect();
        return { x: box.left, y: box.top, w: box.width, h: box.height };
      }

      // What the scope's fields currently hold: one password (a new one in preference to the one being replaced) and one username.
      function collect(scope) {
        var fields = fieldsIn(scope);
        var passwords = fields.filter(isPasswordInput);
        var kinds = passwords.map(function (field) { return passwordKind(field, passwords, scope); });
        var out = { username: '', password: '', newPassword: false, step: 'full', usernameEl: null, passwordEl: null };
        var pick = -1;
        for (var i = 0; i < passwords.length; i++) {
          if (kinds[i] === 'newPassword' && passwords[i].value && !isConfirmField(passwords[i])) { pick = i; break; }
        }
        if (pick < 0) {
          for (var j = 0; j < passwords.length; j++) { if (passwords[j].value) { pick = j; break; } }
        }
        if (pick >= 0) {
          out.password = passwords[pick].value;
          out.newPassword = kinds[pick] === 'newPassword';
          out.passwordEl = passwords[pick];
        }
        var users = fields.filter(function (field) {
          return !isPasswordInput(field) && field.value && textRole(field, fields, passwords, scope) === 'username';
        });
        if (users.length) { out.username = String(users[0].value).trim(); out.usernameEl = users[0]; }
        if (passwords.length === 0) { out.step = 'username'; }
        else if (!out.username) { out.step = 'password'; }
        return out;
      }

      function emit(via, data) {
        if (!data) { return; }
        if (data.step === 'username') { if (!data.username) { return; } }
        else if (!data.password) { return; }
        var now = Date.now();
        var signature = data.step + '\u0000' + data.username + '\u0000' + data.password;
        if (via !== 'removed' && lastSent.sig === signature && now - lastSent.time < 400) { return; }
        lastSent = { sig: signature, time: now };
        if (watch) { watch.submitted = true; watch.time = now; }
        send({ t: 'submit', via: via, username: data.username, password: data.password, newPassword: !!data.newPassword, step: data.step });
      }

      // MARK: - Reporting fields

      function report(el, trigger) {
        var info = classify(el);
        if (!info) { return; }
        var token = tokenFor(el);
        var rect = rectOf(el);
        active = { el: el, token: token, kind: info.kind };
        send({ t: 'focus', token: token, kind: info.kind, trigger: trigger, rect: rect });
        relay(token, rect);
      }

      // A frame's field is placed by the top frame: each ancestor adds its frame element's offset and passes the box up.
      function relay(token, rect) {
        if (window === window.top) { return; }
        try { window.parent.postMessage({ __orbitPwRect: 1, token: token, rect: rect }, '*'); } catch (e) {}
      }

      function scheduleReport(el, trigger) {
        setTimeout(function () {
          if (!el.isConnected || deepActive() !== el) { return; }
          report(el, trigger);
        }, 30);
      }

      function formOf(node) {
        return node.form || (typeof node.closest === 'function' ? node.closest('form') : null);
      }

      function noteInput(event) {
        if (!event.isTrusted) { return; }
        var now = Date.now();
        var type = event.type;
        if (type === 'keydown') {
          lastKeyTime = now;
        } else if (type === 'pointerdown' || type === 'mousedown' || type === 'touchstart' || type === 'click') {
          lastPointer = { time: now, path: typeof event.composedPath === 'function' ? event.composedPath() : [event.target] };
        }
        var target = eventTarget(event);
        var form = target ? formOf(target) : null;
        if (form) { formInput.set(form, now); }
      }

      // True when real input moments ago was on this field (or its label) or a key press that can move focus to it.
      function focusFollowsInput(el) {
        var now = Date.now();
        if (now - lastKeyTime <= FOCUS_WINDOW_MS) { return true; }
        if (now - lastPointer.time > FOCUS_WINDOW_MS) { return false; }
        var path = lastPointer.path;
        if (path.indexOf(el) >= 0) { return true; }
        try {
          var labels = el.labels;
          for (var i = 0; labels && i < labels.length; i++) {
            if (path.indexOf(labels[i]) >= 0) { return true; }
          }
        } catch (e) {}
        return false;
      }

      function hadTrustedInput(form) {
        var at = formInput.get(form);
        return !!at && Date.now() - at <= SUBMIT_WINDOW_MS;
      }

      // A focus is reported only when it follows trusted input: el.focus() from page script must not raise the suggestion panel.
      function onFocusIn(event) {
        if (filling || seen.has(event)) { return; }
        seen.add(event);
        var target = eventTarget(event);
        if (isCandidate(target) && focusFollowsInput(target)) { scheduleReport(target, 'focus'); }
      }

      function onFocusOut(event) {
        if (filling) { return; }
        var target = eventTarget(event);
        if (active && target === active.el) {
          send({ t: 'blur', token: active.token });
          active = null;
        }
      }

      function frameElementFor(source) {
        function search(root) {
          var frames = root.querySelectorAll('iframe,frame');
          for (var i = 0; i < frames.length; i++) {
            try { if (frames[i].contentWindow === source) { return frames[i]; } } catch (e) {}
          }
          return null;
        }
        var found = search(document);
        if (found) { return found; }
        // Only a frame inside an open shadow root is left, which needs the whole tree walked.
        var all = document.querySelectorAll('*');
        for (var j = 0; j < all.length; j++) {
          if (all[j].shadowRoot) {
            found = search(all[j].shadowRoot);
            if (found) { return found; }
          }
        }
        return null;
      }

      function onFrameMessage(event) {
        var data = event.data;
        if (!data || data.__orbitPwRect !== 1 || typeof data.token !== 'string' || !data.rect) { return; }
        var frame = frameElementFor(event.source);
        if (!frame) { return; }
        var box = frame.getBoundingClientRect();
        var style = window.getComputedStyle(frame);
        var x = Number(data.rect.x), y = Number(data.rect.y), w = Number(data.rect.w), h = Number(data.rect.h);
        if (!isFinite(x) || !isFinite(y) || !isFinite(w) || !isFinite(h)) { return; }
        var rect = {
          x: x + box.left + frame.clientLeft + (parseFloat(style.paddingLeft) || 0),
          y: y + box.top + frame.clientTop + (parseFloat(style.paddingTop) || 0),
          w: w,
          h: h
        };
        if (window === window.top) {
          childRelayed = true;
          send({ t: 'rect', token: data.token, rect: rect });
        } else {
          try { window.parent.postMessage({ __orbitPwRect: 1, token: data.token, rect: rect }, '*'); } catch (e) {}
        }
      }

      function onScroll() {
        if (scrollScheduled) { return; }
        scrollScheduled = true;
        requestAnimationFrame(function () {
          scrollScheduled = false;
          if (window === window.top && childRelayed) { send({ t: 'scrolled' }); }
          if (!active) { return; }
          if (!active.el.isConnected) { send({ t: 'blur', token: active.token }); active = null; return; }
          var rect = rectOf(active.el);
          var away = rect.y + rect.h <= 0 || rect.y >= window.innerHeight || rect.x + rect.w <= 0 || rect.x >= window.innerWidth;
          if (away) {
            send({ t: 'blur', token: active.token });
            active = null;
            return;
          }
          send({ t: 'move', token: active.token, rect: rect });
          relay(active.token, rect);
        });
      }

      function onContextMenu(event) {
        if (!event.isTrusted || seen.has(event)) { return; }
        seen.add(event);
        var target = eventTarget(event);
        if (!isCandidate(target)) { return; }
        var info = classify(target);
        if (!info) { return; }
        send({ t: 'contextField', token: tokenFor(target), kind: info.kind, rect: rectOf(target) });
      }

      // MARK: - Capturing sign-ins

      function clearWatch() {
        watch = null;
        if (attributeObserver) { attributeObserver.disconnect(); attributeObserver = null; }
      }

      function startWatch(info, el) {
        var data = collect(info.scope);
        var userEl = data.usernameEl || (isPasswordInput(el) ? null : el);
        var passEl = data.passwordEl || (isPasswordInput(el) ? el : null);
        if (!userEl && !passEl) { return; }
        watch = {
          scope: info.scope, usernameEl: userEl, passwordEl: passEl, newPassword: data.newPassword,
          last: { username: data.username, password: data.password }, time: Date.now(), submitted: false
        };
        if (!attributeObserver) {
          attributeObserver = new MutationObserver(scheduleWatchCheck);
          attributeObserver.observe(document, { attributes: true, subtree: true, attributeFilter: ['style', 'class', 'hidden', 'aria-hidden'] });
        }
      }

      function onInput(event) {
        if (!event.isTrusted || filling || seen.has(event)) { return; }
        seen.add(event);
        var target = eventTarget(event);
        if (!isCandidate(target)) { return; }
        var info = classify(target);
        if (info) { startWatch(info, target); }
      }

      function scheduleWatchCheck() {
        if (watchTimer) { return; }
        watchTimer = setTimeout(function () { watchTimer = 0; checkWatch(); }, 60);
      }

      // A script-driven sign-in ends by removing or hiding its password field, with no navigation and no submit event.
      function checkWatch() {
        if (!watch) { return; }
        if (Date.now() - watch.time > IDLE_MS) { clearWatch(); return; }
        var target = watch.passwordEl || watch.usernameEl;
        if (!target || (target.isConnected && isShown(target))) {
          if (watch.passwordEl && watch.passwordEl.value) { watch.last.password = watch.passwordEl.value; }
          if (watch.usernameEl && watch.usernameEl.value) { watch.last.username = String(watch.usernameEl.value).trim(); }
          return;
        }
        var finished = watch;
        clearWatch();
        var username = finished.usernameEl && finished.usernameEl.value ? String(finished.usernameEl.value).trim() : finished.last.username;
        var password = finished.passwordEl && finished.passwordEl.value ? finished.passwordEl.value : finished.last.password;
        emit('removed', {
          username: username, password: password, newPassword: finished.newPassword,
          step: finished.passwordEl ? (username ? 'full' : 'password') : 'username'
        });
      }

      function onSubmit(event) {
        if (seen.has(event)) { return; }
        seen.add(event);
        var form = event.target;
        if (!form || form.localName !== 'form') { return; }
        // A script-driven sign-in (requestSubmit after a real keypress or click) still counts; one with no real input in the form does not.
        if (!hadTrustedInput(form)) { return; }
        emit('submit', collect(form));
      }

      function scopeAround(node) {
        var current = node.parentElement;
        for (var depth = 0; current && depth < 10; depth++) {
          if (fieldsIn(current).length > 0) { return current; }
          current = current.parentElement;
        }
        return null;
      }

      function submitControl(event) {
        var path = typeof event.composedPath === 'function' ? event.composedPath() : [event.target];
        for (var i = 0; i < path.length && i < 6; i++) {
          var node = path[i];
          if (!node || node.nodeType !== 1) { continue; }
          var name = node.localName;
          var type = lower(node.getAttribute('type'));
          if (name === 'button') {
            if (type === 'submit' || (type === '' && node.form) || SUBMIT_TEXT.test(node.textContent || '')) { return node; }
          } else if (name === 'input' && (type === 'submit' || type === 'image' || type === 'button')) {
            return node;
          } else if (lower(node.getAttribute('role')) === 'button' || name === 'a') {
            if (SUBMIT_TEXT.test(node.textContent || '')) { return node; }
          }
        }
        return null;
      }

      function onClick(event) {
        if (!event.isTrusted || filling || seen.has(event)) { return; }
        seen.add(event);
        var target = eventTarget(event);
        if (isCandidate(target)) { scheduleReport(target, 'click'); return; }
        var control = submitControl(event);
        if (!control) { return; }
        var scope = control.form || scopeAround(control);
        if (scope) { emit('click', collect(scope)); }
      }

      function onKeyDown(event) {
        if (!event.isTrusted || event.key !== 'Enter' || seen.has(event)) { return; }
        seen.add(event);
        var target = eventTarget(event);
        if (!isCandidate(target)) { return; }
        emit('enter', collect(target.form || scopeOf(target)));
      }

      function onPageHide() {
        if (!watch || watch.submitted || Date.now() - watch.time > IDLE_MS) { return; }
        var finished = watch;
        var username = finished.usernameEl && finished.usernameEl.value ? String(finished.usernameEl.value).trim() : finished.last.username;
        var password = finished.passwordEl && finished.passwordEl.value ? finished.passwordEl.value : finished.last.password;
        emit('navigate', {
          username: username, password: password, newPassword: finished.newPassword,
          step: finished.passwordEl ? (username ? 'full' : 'password') : 'username'
        });
      }

      // MARK: - Shadow roots, added nodes, removal

      function hookRoot(root) {
        if (hooked.has(root)) { return; }
        hooked.add(root);
        // Registered before the handlers below, so a click or key is noted before anything reacts to it.
        ['pointerdown', 'mousedown', 'touchstart', 'click', 'keydown', 'input'].forEach(function (type) {
          root.addEventListener(type, noteInput, { capture: true, passive: true });
        });
        root.addEventListener('focusin', onFocusIn, true);
        root.addEventListener('focusout', onFocusOut, true);
        root.addEventListener('click', onClick, true);
        root.addEventListener('input', onInput, true);
        root.addEventListener('keydown', onKeyDown, true);
        root.addEventListener('submit', onSubmit, true);
        root.addEventListener('contextmenu', onContextMenu, true);
      }

      var observer = new MutationObserver(function (records) {
        var removed = false;
        for (var i = 0; i < records.length; i++) {
          var added = records[i].addedNodes;
          for (var j = 0; j < added.length; j++) { adopt(added[j]); }
          if (records[i].removedNodes.length) { removed = true; }
        }
        if (removed && watch) { scheduleWatchCheck(); }
      });

      function adopt(node) {
        if (!node || node.nodeType !== 1) { return; }
        var all = [node].concat(Array.prototype.slice.call(node.querySelectorAll('*')));
        for (var i = 0; i < all.length; i++) {
          var root = all[i].shadowRoot;
          if (root && !hooked.has(root)) {
            hookRoot(root);
            observer.observe(root, { childList: true, subtree: true });
            adopt2(root);
          }
        }
      }

      function adopt2(root) {
        var children = root.children;
        for (var i = 0; i < children.length; i++) { adopt(children[i]); }
      }

      function announce() {
        if (window !== window.top) { return; }
        var first = inputsIn(document).filter(isPasswordInput).filter(isUsable)[0];
        if (!first) { return; }
        var info = classify(first);
        if (info && info.kind !== 'newPassword') { send({ t: 'page', loginForm: true }); }
      }

      hookRoot(document);
      document.addEventListener('scroll', onScroll, { capture: true, passive: true });
      window.addEventListener('resize', onScroll, { passive: true });
      window.addEventListener('pagehide', onPageHide, true);
      window.addEventListener('message', onFrameMessage, true);
      observer.observe(document, { childList: true, subtree: true });

      function afterParse() {
        if (document.documentElement) { adopt(document.documentElement); }
      }
      if (document.readyState === 'loading') { document.addEventListener('DOMContentLoaded', afterParse, { once: true }); }
      else { afterParse(); }

      function afterLoad() { setTimeout(announce, 700); }
      if (document.readyState === 'complete') { afterLoad(); } else { window.addEventListener('load', afterLoad, { once: true }); }

      // MARK: - Filling and inspection, called by native code only

      function setValue(el, value) {
        var setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
        el.dispatchEvent(new FocusEvent('focus', { bubbles: true }));
        el.dispatchEvent(new FocusEvent('focusin', { bubbles: true }));
        setter.call(el, value);
        el.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertReplacementText', data: value }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        el.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true, key: 'Unidentified' }));
      }

      // The frame's origin as native code spells it: scheme, lower-case host without a trailing dot, non-default port. '' for anything but http(s).
      function liveOrigin() {
        var protocol = location.protocol;
        if (protocol !== 'http:' && protocol !== 'https:') { return ''; }
        return protocol + '//' + location.hostname.toLowerCase().replace(/\.$/, '') + (location.port ? ':' + location.port : '');
      }

      // Fills only the fields present and usable right now, so the first step of a multi-step sign-in takes the username alone.
      // A frame that has navigated since the field was reported is checked here, in the frame itself, before any field is touched.
      function fill(token, username, password, mode, expectedOrigin) {
        if (typeof expectedOrigin !== 'string' || liveOrigin() !== expectedOrigin) { return { ok: false, reason: '__ORIGIN_CHANGED__' }; }
        var el = elementFor(token);
        if (!el || !el.isConnected) { return { ok: false, reason: 'gone' }; }
        var info = classify(el);
        if (!info) { return { ok: false, reason: 'unclassified' }; }
        var passwords = info.fields.filter(isPasswordInput);
        var result = { ok: true, username: false, password: false, confirm: false };
        filling = true;
        try {
          if (mode === 'generated') {
            var targets = passwords.filter(function (field) { return passwordKind(field, passwords, info.scope) === 'newPassword'; });
            targets.forEach(function (field) { setValue(field, password); });
            result.password = targets.length > 0;
            result.confirm = targets.length > 1;
          } else {
            var userField = info.kind === 'username' ? el : null;
            if (!userField) {
              var named = info.fields.filter(function (field) {
                return !isPasswordInput(field) && textRole(field, info.fields, passwords, info.scope) === 'username';
              });
              userField = named[0] || null;
            }
            var passField = passwords.filter(function (field) { return passwordKind(field, passwords, info.scope) === 'currentPassword'; })[0] || null;
            if (userField && username) { setValue(userField, username); result.username = true; }
            if (passField && password) { setValue(passField, password); result.password = true; }
          }
        } finally {
          filling = false;
        }
        // Choosing a login or a strong password is the person acting, so a sign-in that follows counts as one with real input.
        var filledForm = formOf(el);
        if (filledForm) { formInput.set(filledForm, Date.now()); }
        startWatch(info, el);
        return result;
      }

      function allInputs(root, out) {
        inputsIn(root).forEach(function (input) { out.push(input); });
        var all = root.querySelectorAll('*');
        for (var i = 0; i < all.length; i++) { if (all[i].shadowRoot) { allInputs(all[i].shadowRoot, out); } }
        return out;
      }

      // Every input with the kind this script gives it, '' for one it ignores. For diagnostics and tests; reveals no values.
      function inspect() {
        return allInputs(document, []).map(function (input) {
          var info = classify(input);
          return { id: input.id || '', name: attr(input, 'name'), type: input.type, kind: info ? info.kind : '' };
        });
      }

      window.__orbitPasswords = { fill: fill, inspect: inspect };
    })();
    """#
    // swiftlint:enable line_length
}
