import AppKit
import Carbon.HIToolbox
import Foundation

// MARK: - Identity

enum ShortcutCommandID: String, CaseIterable, Codable, Sendable {
    case newTabCommandBar
    case addressBarCommandBar
    case newWindow
    case newIncognitoWindow
    case closeTabOrWindow
    case reopenLastClosedTab
    case hideOrbit
    case hideOthers
    case minimize
    case quit
    case toggleSidebar
    case toggleFullScreen
    case openSettings
    case askChatGPTCommandBar
    // Ships unbound: Arc's own key equivalent for this row is a glyph no Mac keyboard layout produces.
    case setAsDefaultBrowser
    case shareCurrentPage

    case pinUnpinTab
    case clearTodayTabs
    case previousTab
    case nextTab
    case jumpToSidebarItem1
    case jumpToSidebarItem2
    case jumpToSidebarItem3
    case jumpToSidebarItem4
    case jumpToSidebarItem5
    case jumpToSidebarItem6
    case jumpToSidebarItem7
    case jumpToSidebarItem8
    case jumpToSidebarItem9
    case cycleRecentTabs
    case pasteAsNewTab
    case duplicateTab
    case renameCurrentItem
    case newFolder
    case collapseAllFolders
    case expandAllFolders
    case revealTabInSidebar
    case expandPinnedSection
    case collapsePinnedSection
    case resetTabToOriginalURL

    case goBack
    case goForward
    case refresh
    case hardRefresh
    case stopLoading
    case zoomIn
    case zoomOut
    case resetZoom

    case findOnPage
    case findNext
    case findPrevious
    case findAndReplace
    case jumpToSelection
    case printPage
    case savePageAs
    case pasteAndMatchStyle
    case copyURL
    case copyURLAsMarkdown
    case screenCaptureRegion
    case viewSource
    case inspectElement
    case javaScriptConsole
    case toggleDeveloperMode
    // F12 carries no modifier, the one exception in this table — GlobalKeyEventMonitor
    // still ignores it as plain typing because it's a symbolic function key, not a character.
    case openDeveloperTools
    case captureFullPage
    case clearCookiesAndRefresh
    case clearCacheAndRefresh
    case newBoost
    case editBoost

    case nextSpace
    case previousSpace
    case jumpToSpace1
    case jumpToSpace2
    case jumpToSpace3
    case jumpToSpace4
    case jumpToSpace5
    case jumpToSpace6
    case jumpToSpace7
    case jumpToSpace8
    case jumpToSpace9
    case newSpace
    case renameSpace
    case editSpaceTheme

    case newLittleOrbit
    case openTabInLittleOrbit
    case openIntoMainWindow
    case openInSpacePicker

    case newNote
    case newNoteInSplitView
    case newEasel

    case library
    case downloads
    case archivedTabs
    case history
    // Raw value kept as the old "extensionsPopover" spelling: the remap
    // store persists this as its JSON key, and renaming it would silently
    // drop any custom binding an existing install already saved.
    case siteControls = "extensionsPopover"
    case readerMode
    case mediaLibrary
    case easelsAndNotesLibrary
    case boostsLibrary
    case clearArchive

    case addSplit
    case closeSplit
    case splitPane1
    case splitPane2
    case splitPane3
    case splitPane4
    case focusPreviousPane
    case focusNextPane
    case separateFromSplitView
    case expandCurrentSplit
}

enum ShortcutCategory: String, CaseIterable, Hashable, Sendable {
    case essentials = "Essentials & Window"
    case tabs = "Tabs & Pinning"
    case navigation = "Page Navigation"
    case findAndTools = "Find & Page Tools"
    case spaces = "Spaces"
    case littleOrbit = "Little Orbit"
    case notesEasels = "Notes & Easels"
    case library = "Library & History"
    case splitView = "Split View"
}

// MARK: - Key binding

struct KeyBinding: Codable, Hashable, Sendable {
    var key: String
    var modifiers: UInt

    // Not deviceIndependentFlagsMask: that keeps .capsLock/.function/.numericPad,
    // which took every shortcut down with Caps Lock on and killed every arrow-key
    // binding, since macOS sets .function/.numericPad on every arrow-key event.
    static let significantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    init(key: String, modifiers: NSEvent.ModifierFlags) {
        self.key = key
        self.modifiers = modifiers.intersection(KeyBinding.significantModifiers).rawValue
    }

    private init(key: String, rawModifiers: UInt) {
        self.key = key
        self.modifiers = rawModifiers & KeyBinding.significantModifiers.rawValue
    }

    // Repairs an override persisted by an earlier build under the old
    // deviceIndependentFlagsMask, which could store bits command(matching:) never produces again.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try container.decode(String.self, forKey: .key)
        let stored = try container.decode(UInt.self, forKey: .modifiers)
        self.modifiers = stored & KeyBinding.significantModifiers.rawValue
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case modifiers
    }

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers)
    }

    static func cmd(_ key: String) -> KeyBinding { KeyBinding(key: key, modifiers: .command) }
    static func cmdShift(_ key: String) -> KeyBinding { KeyBinding(key: key, modifiers: [.command, .shift]) }
    static func cmdOption(_ key: String) -> KeyBinding { KeyBinding(key: key, modifiers: [.command, .option]) }
    static func cmdOptionShift(_ key: String) -> KeyBinding {
        KeyBinding(key: key, modifiers: [.command, .option, .shift])
    }
    static func ctrl(_ key: String) -> KeyBinding { KeyBinding(key: key, modifiers: .control) }
    static func ctrlShift(_ key: String) -> KeyBinding { KeyBinding(key: key, modifiers: [.control, .shift]) }

    var displayString: String {
        var out = ""
        let flags = modifierFlags
        if flags.contains(.control) { out += "⌃" }
        if flags.contains(.option) { out += "⌥" }
        if flags.contains(.shift) { out += "⇧" }
        if flags.contains(.command) { out += "⌘" }
        out += KeyBinding.displayName(for: key)
        return out
    }

    var menuKeyEquivalent: String {
        KeyBinding.menuEquivalent(for: key)
    }

    private static func displayName(for key: String) -> String {
        switch key {
        case "left": return "←"
        case "right": return "→"
        case "up": return "↑"
        case "down": return "↓"
        case "return": return "⏎"
        case "delete": return "⌫"
        case "escape": return "⎋"
        case "tab": return "⇥"
        case "space": return "Space"
        case "f12": return "F12"
        case "[": return "["
        case "]": return "]"
        case "{": return "{"
        case "}": return "}"
        case ",": return ","
        case ".": return "."
        case "-": return "-"
        case "=": return "="
        default: return key.uppercased()
        }
    }

    // Must use the identical normalisation ShortcutRegistry.command(matching:)
    // applies at dispatch — recording and dispatch disagreeing means the UI
    // accepts a shortcut that can never fire.
    nonisolated init?(recording event: NSEvent) {
        let resolved = ShortcutRegistry.symbolicKey(for: event)
            ?? event.charactersIgnoringModifiers?.lowercased()
        guard let key = resolved, !key.isEmpty else { return nil }
        self.init(key: key, modifiers: event.modifierFlags)
    }

    private static func menuEquivalent(for key: String) -> String {
        switch key {
        case "left": return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case "right": return String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case "up": return String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case "down": return String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case "return": return "\r"
        case "delete": return String(UnicodeScalar(NSBackspaceCharacter)!)
        case "escape": return "\u{1B}"
        case "tab": return "\t"
        case "space": return " "
        case "f12": return String(UnicodeScalar(NSF12FunctionKey)!)
        default: return key
        }
    }
}

// MARK: - Command descriptor

struct ShortcutCommand: Identifiable, Sendable {
    var id: ShortcutCommandID
    var title: String
    var category: ShortcutCategory
    /// nil means the command ships intentionally unbound.
    var defaultBinding: KeyBinding?
}

// MARK: - Registry

@MainActor
@Observable
final class ShortcutRegistry {

    static let shared = ShortcutRegistry()

    private(set) var commands: [ShortcutCommand]

    // Empty entry (no key) means explicitly unbound by the user, distinct from "uses default".
    private var overrides: [ShortcutCommandID: KeyBinding?] = [:]

    static let defaultsKey = "OrbitShortcutOverrides.v1"

    // ExtensionCommandRegistry republishes Orbit's reserved accelerators from
    // this; posted rather than called so Core keeps no dependency on Engine.
    static let bindingsChanged = Notification.Name("OrbitShortcutBindingsChanged")

    #if DEBUG
    static var defaults: UserDefaults = OrbitDefaults.standard
    #else
    static let defaults: UserDefaults = OrbitDefaults.standard
    #endif

    private init() {
        self.commands = ShortcutRegistry.buildCommandTable()
        loadOverrides()
    }

    #if DEBUG
    // Never touches persistent storage — ArcImportCoordinator's tests use
    // this so importing Arc's bindings doesn't rebind the developer's own copy of Orbit.
    init(inMemoryForTesting: Bool) {
        precondition(inMemoryForTesting)
        self.commands = ShortcutRegistry.buildCommandTable()
        self.persistsOverrides = false
    }

    private var persistsOverrides = true
    #endif

    func binding(for id: ShortcutCommandID) -> KeyBinding? {
        if let override = overrides[id] {
            return override
        }
        return commands.first(where: { $0.id == id })?.defaultBinding
    }

    func command(for id: ShortcutCommandID) -> ShortcutCommand? {
        commands.first(where: { $0.id == id })
    }

    // Pass the factory default again to clear the override and revert to it.
    func setBinding(_ binding: KeyBinding?, for id: ShortcutCommandID) {
        let factoryDefault = commands.first(where: { $0.id == id })?.defaultBinding
        if binding == factoryDefault {
            overrides.removeValue(forKey: id)
        } else {
            overrides[id] = binding
        }
        persistOverrides()
        NotificationCenter.default.post(name: ShortcutRegistry.bindingsChanged, object: nil)
    }

    // Falls back to the ASCII-capable key if the active layout finds nothing, or shortcuts go dead under non-Latin layouts.
    func command(matching event: NSEvent) -> ShortcutCommandID? {
        let flags = event.modifierFlags.intersection(KeyBinding.significantModifiers)
        let symbolic = ShortcutRegistry.symbolicKey(for: event)
        if let primaryKey = symbolic ?? event.charactersIgnoringModifiers?.lowercased(),
           let found = firstCommand(boundTo: primaryKey, modifierFlags: flags) {
            return found
        }
        // A symbolic key has no non-Latin-layout translation to retry.
        guard symbolic == nil else { return nil }
        guard let asciiKey = ShortcutRegistry.asciiCapableCharacter(forKeyCode: event.keyCode, modifiers: event.modifierFlags) else { return nil }
        return firstCommand(boundTo: asciiKey, modifierFlags: flags)
    }

    private func firstCommand(boundTo key: String, modifierFlags: NSEvent.ModifierFlags) -> ShortcutCommandID? {
        for command in commands {
            guard let binding = binding(for: command.id) else { continue }
            if binding.key == key && binding.modifierFlags == modifierFlags {
                return command.id
            }
        }
        return nil
    }

    // MARK: Conflict detection

    func commands(conflictingWith candidate: KeyBinding, excluding excludedID: ShortcutCommandID? = nil) -> [ShortcutCommandID] {
        commands
            .filter { $0.id != excludedID }
            .filter { binding(for: $0.id) == candidate }
            .map(\.id)
    }

    // Structural comparison only; a binding that only conflicts via the ASCII-fallback pass in command(matching:) is not reported here.
    func conflicts(for id: ShortcutCommandID) -> [ShortcutCommandID] {
        guard let effective = binding(for: id) else { return [] }
        return commands(conflictingWith: effective, excluding: id)
    }

    // Do not delete this in favour of calling conflicts(for:) per row again —
    // that reopens the O(n²) hot path this single-pass method exists to replace.
    func conflictGroups() -> [KeyBinding: [ShortcutCommandID]] {
        var byBinding: [KeyBinding: [ShortcutCommandID]] = [:]
        for command in commands {
            let effective: KeyBinding?
            if let override = overrides[command.id] {
                effective = override
            } else {
                effective = command.defaultBinding
            }
            guard let effective else { continue }
            byBinding[effective, default: []].append(command.id)
        }
        return byBinding.filter { $0.value.count > 1 }
    }

    // internal, not private: the Shortcuts recorder must normalise a
    // recorded key-down through this same table, or it would store the left
    // arrow as its raw character while dispatch looks up "left".
    nonisolated static func symbolicKey(for event: NSEvent) -> String? {
        switch Int(event.keyCode) {
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        case 36: return "return"
        case 51: return "delete"
        case 53: return "escape"
        case 48: return "tab"
        case 49: return "space"
        case 111: return "f12"
        default: return nil
        }
    }

    // Same ASCII-capable fallback NSMenuItem's key-equivalent matching uses, since a non-Latin layout key produces no ASCII character.
    nonisolated static func asciiCapableCharacter(forKeyCode keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String? {
        guard let sourceUnmanaged = TISCopyCurrentASCIICapableKeyboardLayoutInputSource() else { return nil }
        let source = sourceUnmanaged.takeRetainedValue()
        guard let layoutDataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPointer).takeUnretainedValue() as Data

        return layoutData.withUnsafeBytes { rawBuffer -> String? in
            guard let keyLayoutPtr = rawBuffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            // Only Shift affects the plain character produced; the >> 8 & 0xFF
            // packing is UCKeyTranslate's own documented keyModifiers convention.
            let shiftFlag: UInt32 = modifiers.contains(.shift) ? UInt32(shiftKey) : 0
            let modifierKeyState = (shiftFlag >> 8) & 0xFF
            let status = UCKeyTranslate(
                keyLayoutPtr,
                keyCode,
                UInt16(kUCKeyActionDown),
                modifierKeyState,
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length).lowercased()
        }
    }

    func resetToDefaults() {
        overrides.removeAll()
        persistOverrides()
        NotificationCenter.default.post(name: ShortcutRegistry.bindingsChanged, object: nil)
    }

    // MARK: Persistence

    func reloadOverridesFromStore() {
        overrides = [:]
        loadOverrides()
    }

    private func loadOverrides() {
        guard let data = Self.defaults.data(forKey: Self.defaultsKey) else { return }
        guard let decoded = try? JSONDecoder().decode([String: KeyBinding?].self, from: data) else { return }
        var result: [ShortcutCommandID: KeyBinding?] = [:]
        for (key, value) in decoded {
            guard let id = ShortcutCommandID(rawValue: key) else { continue }
            result[id] = value
        }
        overrides = result
    }

    private func persistOverrides() {
        #if DEBUG
        guard persistsOverrides else { return }
        #endif
        var encodable: [String: KeyBinding?] = [:]
        for (id, binding) in overrides {
            encodable[id.rawValue] = binding
        }
        guard let data = try? JSONEncoder().encode(encodable) else { return }
        Self.defaults.set(data, forKey: Self.defaultsKey)
    }

    // MARK: Table

    private static func buildCommandTable() -> [ShortcutCommand] {
        [
            .init(id: .newTabCommandBar, title: "New Tab", category: .essentials, defaultBinding: .cmd("t")),
            .init(id: .addressBarCommandBar, title: "Address Bar / Command Bar", category: .essentials, defaultBinding: .cmd("l")),
            .init(id: .newWindow, title: "New Window", category: .essentials, defaultBinding: .cmd("n")),
            .init(id: .newIncognitoWindow, title: "New Incognito Window", category: .essentials, defaultBinding: .cmdShift("n")),
            .init(id: .closeTabOrWindow, title: "Close Tab / Window", category: .essentials, defaultBinding: .cmd("w")),
            .init(id: .reopenLastClosedTab, title: "Reopen Last Closed Tab", category: .essentials, defaultBinding: .cmdShift("t")),
            .init(id: .hideOrbit, title: "Hide Orbit", category: .essentials, defaultBinding: .cmd("h")),
            .init(id: .hideOthers, title: "Hide Others", category: .essentials, defaultBinding: .cmdShift("h")),
            .init(id: .minimize, title: "Minimize", category: .essentials, defaultBinding: .cmd("m")),
            .init(id: .quit, title: "Quit Orbit", category: .essentials, defaultBinding: .cmd("q")),
            .init(id: .toggleSidebar, title: "Show/Hide Sidebar", category: .essentials, defaultBinding: .cmd("s")),
            .init(id: .toggleFullScreen, title: "Toggle Full Screen", category: .essentials, defaultBinding: KeyBinding(key: "f", modifiers: [.command, .control])),
            .init(id: .openSettings, title: "Settings…", category: .essentials, defaultBinding: .cmd(",")),
            .init(id: .askChatGPTCommandBar, title: "Ask ChatGPT", category: .essentials, defaultBinding: .cmdOption("g")),
            .init(id: .setAsDefaultBrowser, title: "Set as Default Browser", category: .essentials, defaultBinding: nil),

            .init(id: .pinUnpinTab, title: "Pin / Unpin Current Tab", category: .tabs, defaultBinding: .cmd("d")),
            .init(id: .clearTodayTabs, title: "Clear All Today Tabs", category: .tabs, defaultBinding: .cmdShift("k")),
            .init(id: .previousTab, title: "Previous Open Tab", category: .tabs, defaultBinding: .cmdOption("up")),
            .init(id: .nextTab, title: "Next Open Tab", category: .tabs, defaultBinding: .cmdOption("down")),
            .init(id: .jumpToSidebarItem1, title: "Jump to Sidebar Item 1", category: .tabs, defaultBinding: .cmd("1")),
            .init(id: .jumpToSidebarItem2, title: "Jump to Sidebar Item 2", category: .tabs, defaultBinding: .cmd("2")),
            .init(id: .jumpToSidebarItem3, title: "Jump to Sidebar Item 3", category: .tabs, defaultBinding: .cmd("3")),
            .init(id: .jumpToSidebarItem4, title: "Jump to Sidebar Item 4", category: .tabs, defaultBinding: .cmd("4")),
            .init(id: .jumpToSidebarItem5, title: "Jump to Sidebar Item 5", category: .tabs, defaultBinding: .cmd("5")),
            .init(id: .jumpToSidebarItem6, title: "Jump to Sidebar Item 6", category: .tabs, defaultBinding: .cmd("6")),
            .init(id: .jumpToSidebarItem7, title: "Jump to Sidebar Item 7", category: .tabs, defaultBinding: .cmd("7")),
            .init(id: .jumpToSidebarItem8, title: "Jump to Sidebar Item 8", category: .tabs, defaultBinding: .cmd("8")),
            .init(id: .jumpToSidebarItem9, title: "Jump to Sidebar Item 9", category: .tabs, defaultBinding: .cmd("9")),
            .init(id: .cycleRecentTabs, title: "Cycle 5 Most Recent Tabs", category: .tabs, defaultBinding: .ctrl("tab")),
            .init(id: .pasteAsNewTab, title: "Paste Clipboard as New Tab", category: .tabs, defaultBinding: .cmdOption("v")),
            .init(id: .duplicateTab, title: "Duplicate Tab", category: .tabs, defaultBinding: nil),
            .init(id: .renameCurrentItem, title: "Rename Current Item", category: .tabs, defaultBinding: nil),
            .init(id: .newFolder, title: "New Folder", category: .tabs, defaultBinding: nil),
            .init(id: .collapseAllFolders, title: "Collapse All Folders", category: .tabs, defaultBinding: nil),
            .init(id: .expandAllFolders, title: "Expand All Folders", category: .tabs, defaultBinding: nil),
            .init(id: .revealTabInSidebar, title: "Reveal Tab in Sidebar", category: .tabs, defaultBinding: .ctrl("space")),
            .init(id: .expandPinnedSection, title: "Expand Pinned Section", category: .tabs, defaultBinding: nil),
            .init(id: .collapsePinnedSection, title: "Collapse Pinned Section", category: .tabs, defaultBinding: nil),
            .init(id: .resetTabToOriginalURL, title: "Reset Tab to Original URL", category: .tabs, defaultBinding: nil),

            .init(id: .goBack, title: "Back", category: .navigation, defaultBinding: .cmd("[")),
            .init(id: .goForward, title: "Forward", category: .navigation, defaultBinding: .cmd("]")),
            .init(id: .refresh, title: "Refresh", category: .navigation, defaultBinding: .cmd("r")),
            .init(id: .hardRefresh, title: "Hard Refresh", category: .navigation, defaultBinding: .cmdShift("r")),
            .init(id: .stopLoading, title: "Stop Loading", category: .navigation, defaultBinding: .cmd(".")),
            .init(id: .zoomIn, title: "Zoom In", category: .navigation, defaultBinding: .cmd("=")),
            .init(id: .zoomOut, title: "Zoom Out", category: .navigation, defaultBinding: .cmd("-")),
            .init(id: .resetZoom, title: "Reset Zoom", category: .navigation, defaultBinding: .cmd("0")),

            .init(id: .findOnPage, title: "Find or Ask", category: .findAndTools, defaultBinding: .cmd("f")),
            .init(id: .findNext, title: "Find Next", category: .findAndTools, defaultBinding: .cmd("g")),
            .init(id: .findPrevious, title: "Find Previous", category: .findAndTools, defaultBinding: .cmdShift("g")),
            .init(id: .findAndReplace, title: "Find and Replace", category: .findAndTools, defaultBinding: .cmdOption("f")),
            .init(id: .jumpToSelection, title: "Jump to Selection", category: .findAndTools, defaultBinding: .cmd("j")),
            .init(id: .printPage, title: "Print", category: .findAndTools, defaultBinding: .cmd("p")),
            .init(id: .savePageAs, title: "Save Page As", category: .findAndTools, defaultBinding: .cmdShift("s")),
            .init(id: .pasteAndMatchStyle, title: "Paste and Match Style", category: .findAndTools, defaultBinding: .cmdOptionShift("v")),
            .init(id: .copyURL, title: "Copy URL (Trackers Stripped)", category: .findAndTools, defaultBinding: .cmdShift("c")),
            .init(id: .copyURLAsMarkdown, title: "Copy URL as Markdown", category: .findAndTools, defaultBinding: .cmdOptionShift("c")),
            .init(id: .screenCaptureRegion, title: "Screen Capture (Region)", category: .findAndTools, defaultBinding: .cmdShift("2")),
            .init(id: .viewSource, title: "View Source", category: .findAndTools, defaultBinding: .cmdOption("u")),
            .init(id: .inspectElement, title: "Inspect Element", category: .findAndTools, defaultBinding: .cmdOption("i")),
            .init(id: .javaScriptConsole, title: "JavaScript Console", category: .findAndTools, defaultBinding: .cmdOption("j")),
            .init(id: .toggleDeveloperMode, title: "Toggle Developer Mode", category: .findAndTools, defaultBinding: .ctrl("d")),
            .init(id: .openDeveloperTools, title: "Open Developer Tools", category: .findAndTools, defaultBinding: KeyBinding(key: "f12", modifiers: [])),
            .init(id: .captureFullPage, title: "Capture Full Page", category: .findAndTools, defaultBinding: nil),
            .init(id: .clearCookiesAndRefresh, title: "Clear Cookies and Refresh", category: .findAndTools, defaultBinding: nil),
            .init(id: .clearCacheAndRefresh, title: "Clear Cache (Entire Session) and Refresh", category: .findAndTools, defaultBinding: nil),
            .init(id: .shareCurrentPage, title: "Share Page", category: .findAndTools, defaultBinding: nil),
            .init(id: .newBoost, title: "New Boost", category: .findAndTools, defaultBinding: nil),
            .init(id: .editBoost, title: "Edit Boost", category: .findAndTools, defaultBinding: nil),

            .init(id: .nextSpace, title: "Next Space", category: .spaces, defaultBinding: .cmdOption("right")),
            .init(id: .previousSpace, title: "Previous Space", category: .spaces, defaultBinding: .cmdOption("left")),
            .init(id: .jumpToSpace1, title: "Jump to Space 1", category: .spaces, defaultBinding: .ctrl("1")),
            .init(id: .jumpToSpace2, title: "Jump to Space 2", category: .spaces, defaultBinding: .ctrl("2")),
            .init(id: .jumpToSpace3, title: "Jump to Space 3", category: .spaces, defaultBinding: .ctrl("3")),
            .init(id: .jumpToSpace4, title: "Jump to Space 4", category: .spaces, defaultBinding: .ctrl("4")),
            .init(id: .jumpToSpace5, title: "Jump to Space 5", category: .spaces, defaultBinding: .ctrl("5")),
            .init(id: .jumpToSpace6, title: "Jump to Space 6", category: .spaces, defaultBinding: .ctrl("6")),
            .init(id: .jumpToSpace7, title: "Jump to Space 7", category: .spaces, defaultBinding: .ctrl("7")),
            .init(id: .jumpToSpace8, title: "Jump to Space 8", category: .spaces, defaultBinding: .ctrl("8")),
            .init(id: .jumpToSpace9, title: "Jump to Space 9", category: .spaces, defaultBinding: .ctrl("9")),
            .init(id: .newSpace, title: "New Space", category: .spaces, defaultBinding: nil),
            .init(id: .renameSpace, title: "Rename Space", category: .spaces, defaultBinding: nil),
            .init(id: .editSpaceTheme, title: "Edit Space Theme", category: .spaces, defaultBinding: nil),

            .init(id: .newLittleOrbit, title: "New Little Orbit", category: .littleOrbit, defaultBinding: .cmdOption("n")),
            .init(id: .openTabInLittleOrbit, title: "Open Tab in Little Orbit", category: .littleOrbit, defaultBinding: .cmdOptionShift("n")),
            .init(id: .openIntoMainWindow, title: "Open Into Main Window", category: .littleOrbit, defaultBinding: .cmd("o")),
            .init(id: .openInSpacePicker, title: "Open In… (Space Picker)", category: .littleOrbit, defaultBinding: .cmdShift("o")),

            .init(id: .newNote, title: "New Note", category: .notesEasels, defaultBinding: .ctrl("n")),
            .init(id: .newNoteInSplitView, title: "New Note in Split View", category: .notesEasels, defaultBinding: KeyBinding(key: "n", modifiers: [.control, .option])),
            .init(id: .newEasel, title: "New Easel", category: .notesEasels, defaultBinding: .ctrlShift("l")),

            .init(id: .library, title: "Library", category: .library, defaultBinding: .cmdShift("l")),
            .init(id: .downloads, title: "Downloads", category: .library, defaultBinding: .cmdShift("j")),
            .init(id: .archivedTabs, title: "Show Archived Tabs", category: .library, defaultBinding: nil),
            .init(id: .history, title: "History", category: .library, defaultBinding: .cmd("y")),
            .init(id: .siteControls, title: "Site Controls", category: .library, defaultBinding: .cmd("e")),
            .init(id: .readerMode, title: "Reader Mode", category: .library, defaultBinding: nil),
            .init(id: .mediaLibrary, title: "Media", category: .library, defaultBinding: nil),
            .init(id: .easelsAndNotesLibrary, title: "Easels & Notes", category: .library, defaultBinding: nil),
            .init(id: .boostsLibrary, title: "Boosts", category: .library, defaultBinding: nil),
            .init(id: .clearArchive, title: "Clear Archive", category: .library, defaultBinding: nil),

            .init(id: .addSplit, title: "Add Split", category: .splitView, defaultBinding: .ctrlShift("=")),
            .init(id: .closeSplit, title: "Close Focused Split", category: .splitView, defaultBinding: .ctrlShift("-")),
            .init(id: .splitPane1, title: "Jump to Split Pane 1", category: .splitView, defaultBinding: .ctrlShift("1")),
            .init(id: .splitPane2, title: "Jump to Split Pane 2", category: .splitView, defaultBinding: .ctrlShift("2")),
            .init(id: .splitPane3, title: "Jump to Split Pane 3", category: .splitView, defaultBinding: .ctrlShift("3")),
            .init(id: .splitPane4, title: "Jump to Split Pane 4", category: .splitView, defaultBinding: .ctrlShift("4")),
            .init(id: .focusPreviousPane, title: "Focus Previous Pane", category: .splitView, defaultBinding: .ctrlShift("[")),
            .init(id: .focusNextPane, title: "Focus Next Pane", category: .splitView, defaultBinding: .ctrlShift("]")),
            .init(id: .separateFromSplitView, title: "Separate Page from Split View", category: .splitView, defaultBinding: nil),
            .init(id: .expandCurrentSplit, title: "Expand Current Split", category: .splitView, defaultBinding: nil),
        ]
    }
}
