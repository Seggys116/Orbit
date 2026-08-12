// Every item's target must stay nil: macOS injects Writing Tools, AutoFill, Start Dictation and Emoji & Symbols into an Edit menu shaped like AppKit expects (standard selectors, first responder). Reimplementing these as Orbit closures would silently lose those four system features.

import AppKit

@MainActor
enum StandardEditSubmenus {

    static func spellingAndGrammarMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Spelling and Grammar", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Spelling and Grammar")
        menu.addItem(withTitle: "Show Spelling and Grammar", action: #selector(NSText.showGuessPanel(_:)), keyEquivalent: ":")
        menu.addItem(withTitle: "Check Document Now", action: #selector(NSText.checkSpelling(_:)), keyEquivalent: ";")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Check Spelling While Typing", action: #selector(NSTextView.toggleContinuousSpellChecking(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Check Grammar With Spelling", action: #selector(NSTextView.toggleGrammarChecking(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Correct Spelling Automatically", action: #selector(NSTextView.toggleAutomaticSpellingCorrection(_:)), keyEquivalent: "")
        item.submenu = menu
        return item
    }

    static func substitutionsMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Substitutions", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Substitutions")
        menu.addItem(withTitle: "Show Substitutions", action: #selector(NSTextView.orderFrontSubstitutionsPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Smart Copy/Paste", action: #selector(NSTextView.toggleSmartInsertDelete(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Smart Quotes", action: #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Smart Dashes", action: #selector(NSTextView.toggleAutomaticDashSubstitution(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Smart Links", action: #selector(NSTextView.toggleAutomaticLinkDetection(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Data Detectors", action: #selector(NSTextView.toggleAutomaticDataDetection(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Text Replacement", action: #selector(NSTextView.toggleAutomaticTextReplacement(_:)), keyEquivalent: "")
        item.submenu = menu
        return item
    }

    static func transformationsMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Transformations", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Transformations")
        menu.addItem(withTitle: "Make Upper Case", action: #selector(NSResponder.uppercaseWord(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Make Lower Case", action: #selector(NSResponder.lowercaseWord(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Capitalize", action: #selector(NSResponder.capitalizeWord(_:)), keyEquivalent: "")
        item.submenu = menu
        return item
    }

    static func speechMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Speech", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Speech")
        menu.addItem(withTitle: "Start Speaking", action: #selector(NSTextView.startSpeaking(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Stop Speaking", action: #selector(NSTextView.stopSpeaking(_:)), keyEquivalent: "")
        item.submenu = menu
        return item
    }

    static func formatMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Format", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Format")
        menu.addItem(fontMenuItem())
        item.submenu = menu
        return item
    }

    private static func fontMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Font", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Font")

        // Bold/Italic target NSFontManager.shared explicitly: addFontTrait: is its method, not NSTextView's, so left targeting the first responder these rows would be permanently greyed out.
        let bold = NSMenuItem(title: "Bold", action: #selector(NSFontManager.addFontTrait(_:)), keyEquivalent: "b")
        bold.target = NSFontManager.shared
        bold.tag = Int(NSFontTraitMask.boldFontMask.rawValue)
        menu.addItem(bold)

        let italic = NSMenuItem(title: "Italic", action: #selector(NSFontManager.addFontTrait(_:)), keyEquivalent: "i")
        italic.target = NSFontManager.shared
        italic.tag = Int(NSFontTraitMask.italicFontMask.rawValue)
        menu.addItem(italic)

        menu.addItem(withTitle: "Underline", action: #selector(NSText.underline(_:)), keyEquivalent: "u")

        item.submenu = menu
        return item
    }
}
