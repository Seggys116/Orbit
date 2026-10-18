import AppKit
import WebKit

/// The page side of a right-click: a trusted `contextmenu` listener in every frame, in its own world,
/// describes the real target (link, image, video, audio, selection, editable field, frame, title)
/// before WebKit asks for its menu, so cross-origin frames report like any other.
@MainActor
enum WebKitContextMenuProbe {
    static let worldName = "orbit-contextmenu"
    static let handlerName = "orbitContextMenu"

    private static let instrumented = NSHashTable<WKUserContentController>.weakObjects()

    static var world: WKContentWorld { WKContentWorld.world(name: worldName) }

    /// Idempotent: safe after the engine's own script reinstall, and for controllers a popup shares with its opener.
    static func install(on controller: WKUserContentController) {
        if !instrumented.contains(controller) {
            controller.add(WebKitContextMenuBridge.shared, contentWorld: world, name: handlerName)
            instrumented.add(controller)
        }
        guard !controller.userScripts.contains(where: { $0.source == listenerSource }) else { return }
        controller.addUserScript(WKUserScript(
            source: listenerSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: world
        ))
    }

    /// Defines `orbitDescribe(doc, chain, clientX, clientY)`, shared by the listener and the point probe.
    static let describeSource = """
    function orbitDescribe(doc, chain, clientX, clientY) {
      var win = doc.defaultView;
      var TEXT_TYPES = ['text', 'search', 'url', 'tel', 'email', 'password', 'number'];
      function tag(node) { return String(node.localName || '').toLowerCase(); }
      function absolute(raw) { try { return new URL(String(raw), doc.baseURI).href; } catch (e) { return ''; } }
      function find(test) {
        for (var i = 0; i < chain.length; i++) { if (test(chain[i])) { return chain[i]; } }
        return null;
      }
      function expand(text, index) {
        var letter = /[\\p{L}\\p{M}\\p{N}'\\u2019]/u;
        if (index == null) { index = text.length; }
        var start = index, end = index;
        while (start > 0 && letter.test(text[start - 1])) { start--; }
        while (end < text.length && letter.test(text[end])) { end++; }
        return text.slice(start, end).replace(/^['\\u2019]+|['\\u2019]+$/g, '');
      }
      var link = find(function (n) {
        var t = tag(n);
        return (t === 'a' || t === 'area') && (n.hasAttribute('href') || n.hasAttribute('xlink:href'));
      });
      var href = '';
      if (link) {
        var raw = link.href;
        if (raw && typeof raw === 'object' && 'baseVal' in raw) { raw = raw.baseVal; }
        href = absolute(raw || link.getAttribute('href') || link.getAttribute('xlink:href') || '');
      }
      var media = find(function (n) { var t = tag(n); return t === 'video' || t === 'audio' || t === 'img' || t === 'canvas'; });
      var kind = '', src = '';
      if (media) {
        kind = tag(media) === 'img' ? 'image' : tag(media);
        if (kind !== 'canvas') { src = absolute(media.currentSrc || media.src || ''); }
      }
      var selection = '';
      try { selection = String(win.getSelection ? win.getSelection() : ''); } catch (e) {}
      var field = find(function (n) { var t = tag(n); return t === 'input' || t === 'textarea'; });
      if (!selection && field) {
        try { selection = field.value.substring(field.selectionStart, field.selectionEnd); } catch (e) {}
      }
      var editable = find(function (n) {
        var t = tag(n);
        if (t === 'textarea') { return !n.readOnly && !n.disabled; }
        if (t === 'input') { return TEXT_TYPES.indexOf(String(n.type || 'text').toLowerCase()) !== -1 && !n.readOnly && !n.disabled; }
        return n.isContentEditable === true;
      });
      var titled = find(function (n) { return !!(n.getAttribute && n.getAttribute('title')); });
      var word = '';
      if (editable && editable.spellcheck !== false && String(editable.type || '').toLowerCase() !== 'password') {
        if (selection) {
          if (selection.length < 64 && !/\\s/.test(selection)) { word = selection; }
        } else if (tag(editable) === 'input' || tag(editable) === 'textarea') {
          try { word = expand(editable.value, editable.selectionStart); } catch (e) {}
        } else {
          try {
            var caret = doc.caretRangeFromPoint ? doc.caretRangeFromPoint(clientX, clientY) : null;
            if (caret && caret.startContainer.nodeType === 3) { word = expand(caret.startContainer.data, caret.startOffset); }
          } catch (e) {}
        }
      }
      return {
        href: href,
        src: src,
        media: kind,
        selection: selection,
        editable: !!editable,
        title: titled ? titled.getAttribute('title') : '',
        frame: String(win.location.href || ''),
        word: word
      };
    }
    """

    static let listenerSource = """
    (function () {
      if (window.__orbitContextProbe) { return; }
      window.__orbitContextProbe = true;
      \(describeSource)
      document.addEventListener('contextmenu', function (event) {
        if (!event.isTrusted) { return; }
        try {
          var path = event.composedPath ? event.composedPath() : [];
          var chain = path.filter(function (n) { return n && n.nodeType === 1; });
          if (chain.length === 0) {
            for (var n = event.target; n; n = n.parentElement) { if (n.nodeType === 1) { chain.push(n); } }
          }
          var info = orbitDescribe(document, chain, event.clientX, event.clientY);
          window.webkit.messageHandlers.\(handlerName).postMessage(JSON.stringify(info));
        } catch (e) {}
      }, true);
    })();
    """

    /// Reads the same description at a point, descending into same-origin frames.
    /// Cross-origin frames cannot be entered from outside, so those are reported as the frame element itself.
    static func pointSource(x: Double, y: Double) -> String {
        """
        (function (x, y) {
          \(describeSource)
          var doc = document;
          var el = doc.elementFromPoint(x, y);
          for (var depth = 0; el && depth < 8 && (el.localName === 'iframe' || el.localName === 'frame'); depth++) {
            var inner = null;
            try { inner = el.contentDocument; } catch (e) {}
            if (!inner) { break; }
            var box = el.getBoundingClientRect();
            x -= box.left + el.clientLeft;
            y -= box.top + el.clientTop;
            var next = inner.elementFromPoint(x, y);
            if (!next) { break; }
            doc = inner;
            el = next;
          }
          var chain = [];
          for (var node = el; node; node = node.parentElement) { chain.push(node); }
          var info = orbitDescribe(doc, chain, x, y);
          if (!info.frame && el && el.src) { info.frame = String(el.src); }
          return JSON.stringify(info);
        })(\(x), \(y))
        """
    }
}

extension WebKitWebContents {

    // MARK: - Native right-click

    /// Called as the click is handed to WebKit, which dispatches the page's `contextmenu` event
    /// and then asks for its own menu; Orbit's menu is shown in its place once both have arrived.
    func willForwardContextClick(_ event: NSEvent) {
        extras.contextMenuGeneration += 1
        extras.extensionMenu = nil
        extras.proposedContextMenu = nil
        let generation = extras.contextMenuGeneration
        extras.pendingContextMenu = WebKitContentsExtras.PendingContextMenu(
            location: viewPoint(forWindowPoint: event.locationInWindow), generation: generation
        )
        // A page that cannot be scripted never reports, and WebKit still shows nothing of its own: probe the point.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated { self?.contextMenuTimedOut(generation) }
        }
    }

    func contextMenuInfoArrived(_ info: [String: Any]) {
        guard var pending = extras.pendingContextMenu, !isClosed else { return }
        pending.info = info
        extras.pendingContextMenu = pending
        if pending.menuRequested { presentPendingContextMenu() }
    }

    // WebKit's own menu is suppressed (nil) and Orbit's is shown. This private selector is the only hook between a right-click and WebKit's menu.
    @objc(_webView:getContextMenuFromProposedMenu:forElement:userInfo:completionHandler:)
    func webViewProposedContextMenu(
        _ webView: WKWebView,
        proposedMenu: NSMenu,
        element: AnyObject,
        userInfo: AnyObject?,
        completionHandler: @escaping (NSMenu?) -> Void
    ) {
        completionHandler(nil)
        guard !isClosed else { return }
        // The snapshot keeps the items a click fires. The proposed menu itself also
        // holds WebKit's own items, and nothing reads it after this capture.
        extras.proposedContextMenu = nil
        extras.extensionMenu = extensionMenuSnapshot(from: proposedMenu)
        if extras.pendingContextMenu == nil {
            // A keyboard-invoked menu has no click behind it: use the pointer, or the view's centre.
            extras.contextMenuGeneration += 1
            let window = webView.window
            let point = window.map { webView.convert($0.mouseLocationOutsideOfEventStream, from: nil) }
                .flatMap { webView.bounds.contains($0) ? $0 : nil }
                ?? CGPoint(x: webView.bounds.midX, y: webView.bounds.midY)
            extras.pendingContextMenu = WebKitContentsExtras.PendingContextMenu(
                location: CGPoint(x: point.x, y: webView.isFlipped ? point.y : webView.bounds.height - point.y),
                generation: extras.contextMenuGeneration
            )
        }
        extras.pendingContextMenu?.menuRequested = true
        if extras.pendingContextMenu?.info != nil {
            presentPendingContextMenu()
            return
        }
        let generation = extras.contextMenuGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated { self?.contextMenuTimedOut(generation) }
        }
    }

    /// Click-specific items come from the menu WebKit already built. `menuItems(for:)` builds
    /// another menu and is only needed when two extensions' bare items cannot be told apart.
    private func extensionMenuSnapshot(from menu: NSMenu) -> WebKitExtensionContextMenuCapture.Snapshot? {
        let loaded = engine.loadedExtensionContexts()
        guard !loaded.isEmpty else { return nil }
        let owners = loaded.map { entry in
            let web = entry.context.webExtension
            return WebKitExtensionContextMenuCapture.Owner(
                id: entry.id,
                name: entry.name,
                wrapperTitles: Set([entry.name, web.displayName, web.displayShortName].compactMap { $0 }),
                tabTitles: []
            )
        }
        let snapshot = WebKitExtensionContextMenuCapture.capture(from: menu, owners: owners)
        if snapshot.groups.contains(where: { $0.extensionID == WebKitExtensionContextMenuCapture.unattributedID }) {
            return captureExtensionMenu(from: menu)
        }
        return snapshot.groups.isEmpty ? nil : snapshot
    }

    /// Fires the captured item, then drops it. A newer gesture that started during the action keeps its own snapshot.
    func performCapturedExtensionContextMenuItem(_ id: ExtensionContextMenuItemID) {
        let generation = extras.contextMenuGeneration
        performExtensionContextMenuItem(id)
        guard extras.contextMenuGeneration == generation else { return }
        extras.extensionMenu = nil
        extras.proposedContextMenu = nil
    }

    private func contextMenuTimedOut(_ generation: Int) {
        guard let pending = extras.pendingContextMenu, pending.generation == generation, !isClosed else { return }
        extras.proposedContextMenu = nil
        if pending.info == nil {
            extras.pendingContextMenu = nil
            openContextMenu(atCSS: pending.location)
        } else if !pending.menuRequested {
            // The page reported the click but WebKit never offered a menu: the page cancelled it.
            extras.pendingContextMenu = nil
        }
    }

    private func presentPendingContextMenu() {
        guard let pending = extras.pendingContextMenu else { return }
        extras.pendingContextMenu = nil
        let context = Self.contextMenuContext(
            from: pending.info ?? [:],
            pageURL: navigationState.url ?? webView.url,
            location: pending.location
        )
        _ = delegate?.webContents(self, showContextMenu: context)
        extras.proposedContextMenu = nil
    }

    /// Top-left origin, in view points: what `ContextMenuContext.location` carries.
    private func viewPoint(forWindowPoint windowPoint: CGPoint) -> CGPoint {
        let local = webView.convert(windowPoint, from: nil)
        return CGPoint(x: local.x, y: webView.isFlipped ? local.y : webView.bounds.height - local.y)
    }

    // MARK: - Point probe

    /// Describes whatever is at `point` (top-left origin, view points) without a click behind it.
    func openContextMenu(atCSS point: CGPoint) {
        let zoom = max(webView.pageZoom, 0.01)
        let script = WebKitContextMenuProbe.pointSource(x: Double(point.x / zoom), y: Double(point.y / zoom))
        webView.evaluateJavaScript(script, in: nil, in: WebKitContextMenuProbe.world) { [weak self] result in
            guard let self, !self.isClosed else { return }
            let json: String? = {
                if case .success(let value) = result { return value as? String }
                return nil
            }()
            let info = json.flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let context = Self.contextMenuContext(from: info, pageURL: self.navigationState.url ?? self.webView.url, location: point)
            _ = self.delegate?.webContents(self, showContextMenu: context)
        }
    }

    // MARK: - Context construction

    /// Pure but for the spell checker; `spelling` is injectable so the mapping can be tested without it.
    static func contextMenuContext(
        from info: [String: Any],
        pageURL: URL?,
        location: CGPoint,
        spelling: (String) -> (word: String, suggestions: [String])? = WebKitWebContents.spellingVerdict(for:)
    ) -> ContextMenuContext {
        func text(_ key: String) -> String? {
            guard let value = info[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        let href = text("href")
        let src = text("src")
        let media: ContextMenuContext.MediaKind
        switch text("media") {
        case "image": media = .image
        case "video": media = .video
        case "audio": media = .audio
        case "canvas": media = .canvas
        default: media = .none
        }
        let isEditable = info["editable"] as? Bool ?? false
        var misspelled: String?
        var suggestions: [String] = []
        if isEditable, let word = text("word"), let verdict = spelling(word) {
            misspelled = verdict.word
            suggestions = verdict.suggestions
        }
        return ContextMenuContext(
            pageURL: pageURL,
            frameURL: text("frame").flatMap { URL(string: $0) },
            linkURL: href.flatMap { URL(string: $0) },
            unfilteredLinkURL: href.flatMap { URL(string: $0) },
            sourceURL: src.flatMap { URL(string: $0) },
            titleText: text("title"),
            selectionText: text("selection"),
            mediaKind: media,
            isEditable: isEditable,
            misspelledWord: misspelled,
            dictionarySuggestions: suggestions,
            location: location
        )
    }

    /// nil when the word is spelled correctly.
    static func spellingVerdict(for word: String) -> (word: String, suggestions: [String])? {
        let checker = NSSpellChecker.shared
        // A right-click has no spell-document language. The no-language check then reports nothing.
        let language = checker.availableLanguages.first { $0.hasPrefix("en") } ?? checker.availableLanguages.first
        let range = checker.checkSpelling(
            of: word, startingAt: 0, language: language, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil
        )
        guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= (word as NSString).length else { return nil }
        let misspelled = (word as NSString).substring(with: range)
        let guesses = checker.guesses(forWordRange: range, in: word, language: language, inSpellDocumentWithTag: 0) ?? []
        return (misspelled, guesses)
    }
}
