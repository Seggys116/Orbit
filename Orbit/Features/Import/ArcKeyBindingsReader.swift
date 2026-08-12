//  ~/Library/Application Support/Arc/StorableKeyBindings.json: {"version": Int, "userOverrides": [...]} — only user overrides are stored, not Arc's full default table.
//  The exact userOverrides element shape and Arc's action-identifier vocabulary are unverified (every observed file has an empty list); decode() accepts several equivalent spellings per concept rather than betting on one.

import AppKit
import Foundation

// MARK: - What comes out

public struct ArcKeyBinding: Sendable, Hashable {
    public var action: String
    /// Lowercased, or one of Orbit's symbolic key names ("left", "return", ...) when the stored character is a function key.
    public var key: String
    public var modifiers: UInt

    public init(action: String, key: String, modifiers: UInt) {
        self.action = action
        self.key = key
        self.modifiers = modifiers
    }

    public var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers)
    }
}

public struct ArcKeyBindingImport: Sendable, Hashable {
    public var bindings: [ArcKeyBinding]
    /// Named, not counted — a number the user cannot act on is not worth reporting.
    public var unmappedActions: [String]
    public var undecodableEntryCount: Int

    public init(
        bindings: [ArcKeyBinding] = [],
        unmappedActions: [String] = [],
        undecodableEntryCount: Int = 0
    ) {
        self.bindings = bindings
        self.unmappedActions = unmappedActions
        self.undecodableEntryCount = undecodableEntryCount
    }

    public var isEmpty: Bool {
        bindings.isEmpty && unmappedActions.isEmpty && undecodableEntryCount == 0
    }
}

// MARK: - Reader

public enum ArcKeyBindingsReader {

    public static func documentURL(homeDirectory: URL) -> URL {
        ArcImportReader.dataDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent("StorableKeyBindings.json", isDirectory: false)
    }

    public static func read(homeDirectory: URL, browser: ImportableBrowser = .arc) throws -> ArcKeyBindingImport {
        let url = documentURL(homeDirectory: homeDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else { return ArcKeyBindingImport() }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            if BrowserImportError.isPermissionDenied(error) {
                throw BrowserImportError.permissionDenied(browser, path: url.path)
            }
            throw BrowserImportError.unreadable(browser, reason: "Couldn't read StorableKeyBindings.json: \(error.localizedDescription)")
        }

        return try parse(data: data, browser: browser)
    }

    static func parse(data: Data, browser: ImportableBrowser) throws -> ArcKeyBindingImport {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw BrowserImportError.unreadable(browser, reason: "StorableKeyBindings.json isn't valid JSON: \(error.localizedDescription)")
        }
        guard let document = json as? [String: Any] else {
            throw BrowserImportError.unreadable(browser, reason: "StorableKeyBindings.json's root isn't a JSON object.")
        }

        let entries = (document["userOverrides"] as? [Any]) ?? (document["overrides"] as? [Any]) ?? []

        var result = ArcKeyBindingImport()
        for entry in entries {
            guard let object = entry as? [String: Any], let binding = decode(object) else {
                result.undecodableEntryCount += 1
                continue
            }
            result.bindings.append(binding)
        }
        return result
    }

    /// An entry with an action but no shortcut is not treated as "unbind" (Arc has an explicit resetToDefault) — more likely a misread shape than a deliberate unbinding.
    static func decode(_ object: [String: Any]) -> ArcKeyBinding? {
        guard let action = string(object, keys: ["action", "actionID", "actionIdentifier", "id", "keyBindingID"]),
              !action.isEmpty
        else { return nil }

        let shortcut = (object["shortcut"] as? [String: Any])
            ?? (object["keyBinding"] as? [String: Any])
            ?? (object["binding"] as? [String: Any])
            ?? object

        guard let rawKey = string(shortcut, keys: ["chars", "characters", "key", "keyEquivalent"]),
              let key = normalisedKey(rawKey)
        else { return nil }

        let rawFlags = integer(shortcut, keys: ["flags", "modifiers", "modifierFlags", "deviceIndependentModifierFlags"]) ?? 0

        return ArcKeyBinding(action: action, key: key, modifiers: UInt(bitPattern: rawFlags))
    }

    static func normalisedKey(_ raw: String) -> String? {
        guard let scalar = raw.unicodeScalars.first, raw.unicodeScalars.count <= 1 || symbolicName(raw) != nil else {
            return symbolicName(raw)
        }
        if let named = symbolicName(raw) { return named }
        if let functionKey = symbolicNameForFunctionKey(scalar) { return functionKey }
        let lowered = raw.lowercased()
        return lowered.isEmpty ? nil : lowered
    }

    static func symbolicName(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "left", "leftarrow", "arrowleft": return "left"
        case "right", "rightarrow", "arrowright": return "right"
        case "up", "uparrow", "arrowup": return "up"
        case "down", "downarrow", "arrowdown": return "down"
        case "return", "enter": return "return"
        case "delete", "backspace": return "delete"
        case "escape", "esc": return "escape"
        case "tab": return "tab"
        case "space", "spacebar": return "space"
        default: return nil
        }
    }

    static func symbolicNameForFunctionKey(_ scalar: Unicode.Scalar) -> String? {
        switch Int(scalar.value) {
        case NSLeftArrowFunctionKey: return "left"
        case NSRightArrowFunctionKey: return "right"
        case NSUpArrowFunctionKey: return "up"
        case NSDownArrowFunctionKey: return "down"
        default: break
        }
        switch scalar {
        case "\r", "\n": return "return"
        case "\u{7F}", "\u{8}": return "delete"
        case "\u{1B}": return "escape"
        case "\t": return "tab"
        case " ": return "space"
        default: return nil
        }
    }

    // MARK: JSON helpers

    private static func string(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String { return value }
        }
        return nil
    }

    private static func integer(_ object: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = object[key] as? NSNumber { return value.intValue }
            if let value = object[key] as? String, let parsed = Int(value) { return parsed }
        }
        return nil
    }
}

// MARK: - Mapping Arc's actions onto Orbit's commands

enum ArcShortcutCommandMap {

    /// Only commands both browsers have appear; anything else is reported unmapped rather than bent onto a nearby command.
    static let table: [String: ShortcutCommandID] = {
        var map: [String: ShortcutCommandID] = [:]
        func add(_ identifiers: [String], _ command: ShortcutCommandID) {
            for identifier in identifiers { map[normalise(identifier)] = command }
        }

        add(["newTab", "openNewTab", "commandBar", "openCommandBar"], .newTabCommandBar)
        add(["focusURLBar", "openAddressBar", "addressBar", "focusAddressBar"], .addressBarCommandBar)
        add(["newWindow"], .newWindow)
        add(["newIncognitoWindow", "newPrivateWindow", "newIncognitoTab"], .newIncognitoWindow)
        add(["closeTab", "closeCurrentTab", "closeWindow"], .closeTabOrWindow)
        add(["reopenLastClosedTab", "restoreLastClosedTab", "reopenClosedTab"], .reopenLastClosedTab)
        add(["hideArc", "hideApplication"], .hideOrbit)
        add(["hideOthers"], .hideOthers)
        add(["minimize", "miniaturize"], .minimize)
        add(["quit", "quitArc"], .quit)
        add(["toggleSidebar", "showHideSidebar"], .toggleSidebar)
        add(["toggleFullScreen", "enterFullScreen"], .toggleFullScreen)
        add(["openPreferences", "openSettings", "showSettings", "openPreferencePane"], .openSettings)

        add(["pinTab", "pinUnpinTab", "togglePinTab", "replacePinnedTab"], .pinUnpinTab)
        add(["clearTodayTabs", "closeTodayTabs", "archiveAllTabs"], .clearTodayTabs)
        add(["previousTab", "selectPreviousTab"], .previousTab)
        add(["nextTab", "selectNextTab"], .nextTab)
        add(["cycleRecentTabs", "switchToLastActiveTab", "toggleRecentTabs"], .cycleRecentTabs)
        add(["pasteAsNewTab", "pasteAndGo"], .pasteAsNewTab)
        for index in 1...9 {
            add(
                ["switchTo\(index)thSidebarItem", "sidebarItem\(index)", "jumpToSidebarItem\(index)", "switchToTab\(index)"],
                sidebarItemCommand(index)
            )
        }

        add(["goBack", "back"], .goBack)
        add(["goForward", "forward"], .goForward)
        add(["reload", "refresh", "reloadPage"], .refresh)
        add(["hardReload", "forceReload", "hardRefresh"], .hardRefresh)
        add(["stopLoading", "stop"], .stopLoading)
        add(["zoomIn", "increaseZoom"], .zoomIn)
        add(["zoomOut", "decreaseZoom"], .zoomOut)
        add(["resetZoom", "actualSize"], .resetZoom)

        add(["findOnPage", "find"], .findOnPage)
        add(["findNext"], .findNext)
        add(["findPrevious"], .findPrevious)
        add(["jumpToSelection"], .jumpToSelection)
        add(["print", "printPage"], .printPage)
        add(["savePageAs", "save"], .savePageAs)
        add(["pasteAndMatchStyle"], .pasteAndMatchStyle)
        add(["copyURL", "copyCurrentURL"], .copyURL)
        add(["copyURLAsMarkdown", "copyMarkdownLink"], .copyURLAsMarkdown)
        add(["captureRegion", "screenshot", "captureScreenshot"], .screenCaptureRegion)
        add(["viewSource", "viewPageSource"], .viewSource)
        add(["inspectElement", "openDevTools", "toggleDevTools"], .inspectElement)
        add(["javaScriptConsole", "openConsole"], .javaScriptConsole)
        add(["toggleReaderMode", "readerMode"], .readerMode)

        add(["nextSpace", "goToNextSpace"], .nextSpace)
        add(["previousSpace", "goToPreviousSpace"], .previousSpace)
        for index in 1...9 {
            add(["switchToSpace\(index)", "space\(index)", "jumpToSpace\(index)"], spaceCommand(index))
        }

        add(["newLittleArc", "openLittleArc", "littleArc"], .newLittleOrbit)
        add(["openInMainWindow", "openIntoMainWindow", "expandLittleArc"], .openIntoMainWindow)

        add(["newNote", "newArcNote"], .newNote)
        add(["newNoteInSplitView", "newNoteSplit"], .newNoteInSplitView)
        add(["newEasel", "newArcEasel"], .newEasel)

        add(["toggleDeveloperMode", "developerMode"], .toggleDeveloperMode)
        add(["openDeveloperTools", "developerTools"], .openDeveloperTools)
        add(["findAndReplace", "replace"], .findAndReplace)
        add(["openInSpacePicker", "moveToSpacePicker"], .openInSpacePicker)

        add(["focusSplitPane1", "splitPane1"], .splitPane1)
        add(["focusSplitPane2", "splitPane2"], .splitPane2)
        add(["focusSplitPane3", "splitPane3"], .splitPane3)
        add(["focusSplitPane4", "splitPane4"], .splitPane4)

        add(["openLibrary", "toggleLibrary", "library"], .library)
        add(["openDownloads", "showDownloads", "downloads"], .downloads)
        add(["showArchive", "viewArchive", "archivedTabs"], .archivedTabs)
        add(["openHistory", "showHistory", "history"], .history)

        add(["addSplitView", "newSplitView", "addSplit"], .addSplit)
        add(["closeSplitView", "closeSplit"], .closeSplit)
        add(["focusPreviousPane", "previousSplitPane"], .focusPreviousPane)
        add(["focusNextPane", "nextSplitPane"], .focusNextPane)

        return map
    }()

    static func normalise(_ identifier: String) -> String {
        identifier.lowercased().filter { $0 != "-" && $0 != "_" && $0 != "." }
    }

    static func command(for arcAction: String) -> ShortcutCommandID? {
        table[normalise(arcAction)]
    }

    private static func sidebarItemCommand(_ index: Int) -> ShortcutCommandID {
        switch index {
        case 1: return .jumpToSidebarItem1
        case 2: return .jumpToSidebarItem2
        case 3: return .jumpToSidebarItem3
        case 4: return .jumpToSidebarItem4
        case 5: return .jumpToSidebarItem5
        case 6: return .jumpToSidebarItem6
        case 7: return .jumpToSidebarItem7
        case 8: return .jumpToSidebarItem8
        default: return .jumpToSidebarItem9
        }
    }

    private static func spaceCommand(_ index: Int) -> ShortcutCommandID {
        switch index {
        case 1: return .jumpToSpace1
        case 2: return .jumpToSpace2
        case 3: return .jumpToSpace3
        case 4: return .jumpToSpace4
        case 5: return .jumpToSpace5
        case 6: return .jumpToSpace6
        case 7: return .jumpToSpace7
        case 8: return .jumpToSpace8
        default: return .jumpToSpace9
        }
    }
}
