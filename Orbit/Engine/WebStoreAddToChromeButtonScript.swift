import Foundation

/// Finds the store's Add/Remove button and drives installs through
/// `window.__orbitWebStorePrivate`, not `chrome.webstorePrivate`. Must be
/// injected after WebStorePrivateBridgeScript.
public enum WebStoreAddToChromeButtonScript {

    public static let scriptID = UUID(uuidString: "3B7E1C42-9F5A-4E71-8B3D-6A1F2C9E4D50")!

    public static let source = """
    (function() {
      if (window.__orbitOwnsAddToChromeButton) { return; }
      window.__orbitOwnsAddToChromeButton = true;

      var STATE_ADD = 'add', STATE_INSTALLED = 'installed';
      var currentButton = null;
      var currentState = STATE_ADD;

      function norm(s) { return (s || '').replace(/\\s+/g, ' ').trim().toLowerCase(); }
      function accessibleName(el) { return norm(el.getAttribute('aria-label') || el.textContent || ''); }

      function extensionIdFromPath() {
        var m = location.pathname.match(/[a-p]{32}/);
        return m ? m[0] : null;
      }

      function findButton() {
        var candidates = document.querySelectorAll('button, [role="button"]');
        for (var i = 0; i < candidates.length; i++) {
          var name = accessibleName(candidates[i]);
          if (name.indexOf('add to chrome') !== -1 || name.indexOf('remove from chrome') !== -1) {
            return candidates[i];
          }
        }
        return null;
      }

      function enableButton(button) {
        button.removeAttribute('disabled');
        button.disabled = false;
        if (button.getAttribute('aria-disabled') === 'true') { button.setAttribute('aria-disabled', 'false'); }
      }

      // Only the button's own text node is rewritten, so its icons/padding/layout stay Google's.
      function setLabel(button, text) {
        var walker = document.createTreeWalker(button, NodeFilter.SHOW_TEXT, null);
        var best = null, bestLen = 0, node;
        while ((node = walker.nextNode())) {
          var len = (node.nodeValue || '').trim().length;
          if (len > bestLen) { best = node; bestLen = len; }
        }
        if (best) { best.nodeValue = text; } else { button.appendChild(document.createTextNode(text)); }
        if (button.hasAttribute('aria-label')) { button.setAttribute('aria-label', text); }
      }

      function updateState(state) {
        currentState = state;
        if (!currentButton) return;
        enableButton(currentButton);
        setLabel(currentButton, state === STATE_INSTALLED ? 'Remove from Chrome' : 'Add to Chrome');
      }

      function refreshStatus() {
        var id = extensionIdFromPath();
        var button = currentButton;
        var api = window.__orbitWebStorePrivate;
        if (!id || !button || !api) return;
        api.getExtensionStatus(id, function(status) {
          if (currentButton !== button) return;
          updateState(status === 'installable' ? STATE_ADD : STATE_INSTALLED);
        });
      }

      function doInstall(id) {
        var api = window.__orbitWebStorePrivate;
        if (!api) return;
        // This manifest is a feasibility placeholder only, never shown to the user: the native side
        // consents from the downloaded, verified manifest inside completeInstall.
        var manifest = JSON.stringify({ name: document.title || id, version: '0.0.0', manifest_version: 3 });
        // beginInstallWithManifest3's success token is an empty string; every rejection (a named
        // failure token, or undefined on an outright protocol error) is some other value.
        api.beginInstallWithManifest3({ id: id, manifest: manifest }, function(result) {
          if (result !== '') { return; }
          api.completeInstall(id, function() {});
        });
      }

      function doUninstall(id) {
        var api = window.__orbitManagement;
        if (!api) return;
        api.uninstall(id, { showConfirmDialog: false }, function() {});
      }

      function onManagementEvent(id, state) {
        if (!id || id !== extensionIdFromPath()) return;
        updateState(state);
      }

      // A capture-phase listener on document, not the button, fires before any listener Google
      // attached directly to the button; stopImmediatePropagation also blocks any other
      // document-level capture listener registered after this one (stopPropagation alone would not).
      function onCapturedClick(event) {
        if (!currentButton) return;
        if (event.target !== currentButton && !currentButton.contains(event.target)) return;
        event.stopImmediatePropagation();
        event.preventDefault();
        var id = extensionIdFromPath();
        if (!id) return;
        if (currentState === STATE_INSTALLED) { doUninstall(id); } else { doInstall(id); }
      }

      function scan() {
        var button = findButton();
        if (!button) return;
        if (button !== currentButton) {
          currentButton = button;
          refreshStatus();
        }
      }

      // queueMicrotask, not requestAnimationFrame: rAF is suspended for occluded/inactive windows,
      // which would leave the button stuck disabled in exactly that case.
      var scheduled = false;
      function schedule() {
        if (scheduled) return;
        scheduled = true;
        queueMicrotask(function() { scheduled = false; scan(); });
      }

      // Belt-and-suspenders poll for the button's lazily-loaded chunk finishing after the
      // MutationObserver's own callbacks have already settled down.
      var pollCount = 0;
      var pollTimer = setInterval(function() {
        pollCount += 1;
        scan();
        if (pollCount >= 20) { clearInterval(pollTimer); }
      }, 500);

      function bindManagementEventsWhenReady() {
        var api = window.__orbitManagement;
        if (!api) { setTimeout(bindManagementEventsWhenReady, 100); return; }
        api.onInstalled.addListener(function(info) { onManagementEvent(info && info.id, STATE_INSTALLED); });
        api.onEnabled.addListener(function(info) { onManagementEvent(info && info.id, STATE_INSTALLED); });
        api.onDisabled.addListener(function(info) { onManagementEvent(info && info.id, STATE_INSTALLED); });
        api.onUninstalled.addListener(function(id) { onManagementEvent(id, STATE_ADD); });
      }
      bindManagementEventsWhenReady();

      document.addEventListener('click', onCapturedClick, true);
      var observer = new MutationObserver(schedule);
      // Observes document, not document.documentElement: at document start the latter can still
      // be null (the parser has not created <html> yet), which would throw and abort the rest of this IIFE.
      observer.observe(document, {
        childList: true, subtree: true, attributes: true,
        attributeFilter: ['disabled', 'aria-disabled', 'aria-label']
      });
      document.addEventListener('DOMContentLoaded', schedule);
      schedule();
    })();
    """

    public static var chromiumUserScript: UserScript {
        UserScript(
            id: scriptID,
            kind: .javaScript,
            source: source,
            injectionTime: .documentStart,
            matchPatterns: [
                "https://chromewebstore.google.com/*",
                "https://chrome.google.com/webstore/*"
            ],
            allFrames: false
        )
    }
}
