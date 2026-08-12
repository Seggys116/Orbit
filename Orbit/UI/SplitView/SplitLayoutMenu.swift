import AppKit
import SwiftUI

enum SplitLayoutOption: Hashable, CaseIterable {
    case splitRight, splitLeft, splitDown, splitUp
    case movePaneBackward
    case movePaneForward
    case addSplitTrailing
    case addSplitLeading
    case flipToHorizontal
    case flipToVertical
    case separateThisTab
    case separateAllTabs
    case expandThisPane
    case shareSplitView

    // axis is nil for a pane not yet in a split; direction words name a direction on screen, and "Move Left" is not one on a stacked split.
    func title(inGroupWith axis: SplitGroup.Axis?) -> String {
        let isStacked = axis == .vertical
        switch self {
        case .splitRight: return "Split Right"
        case .splitLeft: return "Split Left"
        case .splitDown: return "Split Down"
        case .splitUp: return "Split Up"
        case .movePaneBackward: return isStacked ? "Move Up" : "Move Left"
        case .movePaneForward: return isStacked ? "Move Down" : "Move Right"
        case .addSplitTrailing: return isStacked ? "Add Bottom Split" : "Add Right Split"
        case .addSplitLeading: return isStacked ? "Add Top Split" : "Add Left Split"
        case .flipToHorizontal: return "Convert to Horizontal Split View"
        case .flipToVertical: return "Convert to Vertical Split View"
        case .separateThisTab: return "Separate Tab from Split"
        case .separateAllTabs: return "Separate All Tabs"
        case .expandThisPane: return "Expand to Full Width"
        case .shareSplitView: return "Share Split View…"
        }
    }

    func symbolName(inGroupWith axis: SplitGroup.Axis?) -> String {
        let isStacked = axis == .vertical
        switch self {
        case .splitRight: return "rectangle.righthalf.inset.filled"
        case .splitLeft: return "rectangle.lefthalf.inset.filled"
        case .splitDown: return "rectangle.bottomhalf.inset.filled"
        case .splitUp: return "rectangle.tophalf.inset.filled"
        case .movePaneBackward: return isStacked ? "arrow.up.square" : "rectangle.lefthalf.inset.filled.arrow.left"
        case .movePaneForward: return isStacked ? "arrow.down.square" : "rectangle.righthalf.inset.filled.arrow.right"
        case .addSplitTrailing: return isStacked ? "rectangle.bottomhalf.inset.filled" : "rectangle.righthalf.inset.filled"
        case .addSplitLeading: return isStacked ? "rectangle.tophalf.inset.filled" : "rectangle.lefthalf.inset.filled"
        case .flipToHorizontal: return "rectangle.split.2x1"
        case .flipToVertical: return "rectangle.split.1x2"
        case .separateThisTab: return "arrow.down.left.square"
        case .separateAllTabs: return "rectangle.split.2x1.slash"
        case .expandThisPane: return "arrow.up.left.and.arrow.down.right"
        case .shareSplitView: return "square.and.arrow.up"
        }
    }

    var flipTarget: SplitGroup.Axis? {
        switch self {
        case .flipToHorizontal: return .horizontal
        case .flipToVertical: return .vertical
        default: return nil
        }
    }

    var startsNewGroup: Bool {
        self == .addSplitTrailing || self == .separateThisTab || self == .shareSplitView
    }

    static func options(forPaneOf tab: Tab, in env: AppEnvironment) -> [SplitLayoutOption] {
        guard let group = env.splitGroup(for: tab.id) else {
            return [.splitRight, .splitLeft, .splitDown, .splitUp]
        }
        var options: [SplitLayoutOption] = [.movePaneBackward, .movePaneForward]
        if group.tabIDs.count < SplitGroup.maximumPanes {
            options.append(contentsOf: [.addSplitTrailing, .addSplitLeading])
        }
        options.append(.separateThisTab)
        options.append(group.axis == .horizontal ? .flipToVertical : .flipToHorizontal)
        options.append(contentsOf: [.separateAllTabs, .expandThisPane])
        options.append(.shareSplitView)
        return options
    }

    static func isEnabled(_ option: SplitLayoutOption, forPaneOf tab: Tab, in env: AppEnvironment) -> Bool {
        switch option {
        case .movePaneBackward, .movePaneForward:
            guard let group = env.splitGroup(for: tab.id),
                  let index = group.tabIDs.firstIndex(of: tab.id) else { return false }
            return option == .movePaneBackward ? index > 0 : index < group.tabIDs.count - 1
        case .shareSplitView:
            return !shareItems(forPaneOf: tab, in: env).isEmpty
        default:
            return true
        }
    }

    // Only http/https: an orbit:// blank pane's URL means nothing outside this process and would share a dead string.
    static func shareItems(forPaneOf tab: Tab, in env: AppEnvironment) -> [URL] {
        env.splitPanes(containing: tab.id)
            .map(\.url)
            .filter { $0.scheme == "http" || $0.scheme == "https" }
    }

    // Every branch operates on tab.id, never env.activeTabID, so picking an option from an unfocused pane's menu still acts on the pane the menu was opened from.
    static func perform(_ option: SplitLayoutOption, forPaneOf tab: Tab, in env: AppEnvironment) {
        switch option {
        case .splitRight: startSplit(tab: tab, edge: .right, in: env)
        case .splitLeft: startSplit(tab: tab, edge: .left, in: env)
        case .splitDown: startSplit(tab: tab, edge: .bottom, in: env)
        case .splitUp: startSplit(tab: tab, edge: .top, in: env)
        case .movePaneBackward: env.movePane(tab.id, by: -1)
        case .movePaneForward: env.movePane(tab.id, by: 1)
        case .addSplitTrailing, .addSplitLeading:
            guard let group = env.splitGroup(for: tab.id) else { return }
            // Edge stays on the group's own axis: SplitGroup cannot represent a perpendicular pane.
            let edge: SplitEdge
            switch (group.axis, option) {
            case (.horizontal, .addSplitLeading): edge = .left
            case (.horizontal, _): edge = .right
            case (.vertical, .addSplitLeading): edge = .top
            case (.vertical, _): edge = .bottom
            }
            let blankTabID = env.openTab(url: URL(string: "orbit://new-tab")!, in: tab.spaceID, section: .today, activate: false)
            env.addToSplit(tabID: blankTabID, groupID: group.id, edge: edge)
        case .flipToHorizontal, .flipToVertical:
            guard let group = env.splitGroup(for: tab.id), let axis = option.flipTarget else { return }
            env.setSplitAxis(axis, forGroup: group.id)
        case .separateAllTabs:
            guard let group = env.splitGroup(for: tab.id) else { return }
            env.separateAllTabs(group.id)
        case .expandThisPane:
            guard let group = env.splitGroup(for: tab.id) else { return }
            env.separateAllTabs(group.id)
            env.activateTab(tab.id)
        case .separateThisTab:
            env.closeSplitPane(tab.id)
        case .shareSplitView:
            presentShareSheet(forPaneOf: tab, in: env)
        }
    }

    private static func presentShareSheet(forPaneOf tab: Tab, in env: AppEnvironment) {
        let items = shareItems(forPaneOf: tab, in: env)
        guard !items.isEmpty, let anchor = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: items)
        picker.show(relativeTo: .zero, of: anchor, preferredEdge: .minY)
    }

    private static func startSplit(tab: Tab, edge: SplitEdge, in env: AppEnvironment) {
        let blankTabID = env.openTab(url: URL(string: "orbit://new-tab")!, in: tab.spaceID, section: .today, activate: false)
        env.createSplit(existingTabID: tab.id, newTabID: blankTabID, edge: edge)
    }

    static func buildNSMenu(forPaneOf tab: Tab, in env: AppEnvironment) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let axis = env.splitGroup(for: tab.id)?.axis
        for option in options(forPaneOf: tab, in: env) {
            if option.startsNewGroup {
                menu.addItem(.separator())
            }
            let title = option.title(inGroupWith: axis)
            let item = ClosureMenuItem(title: title, enabled: isEnabled(option, forPaneOf: tab, in: env)) {
                perform(option, forPaneOf: tab, in: env)
            }
            let image = NSImage(systemSymbolName: option.symbolName(inGroupWith: axis), accessibilityDescription: title)
            image?.isTemplate = true
            item.image = image
            menu.addItem(item)
        }
        return menu
    }
}
