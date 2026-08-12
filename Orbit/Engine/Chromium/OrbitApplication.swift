//  SwiftUI instantiates its own private NSApplication subclass and ignores
//  NSPrincipalClass, so conformance is added by extension, not subclassing.

import AppKit
import ObjectiveC

/// Registers opaque content::NativeEventProcessorObserver* values; file-scope
/// because there is at most one process-wide NSApp.
enum OrbitNativeEventState {
    static var handlingSendEvent = false
    static var observers: [UnsafeMutableRawPointer] = []
}

extension NSApplication {

    @objc func isHandlingSendEvent() -> Bool {
        OrbitNativeEventState.handlingSendEvent
    }

    @objc func setHandlingSendEvent(_ handlingSendEvent: Bool) {
        OrbitNativeEventState.handlingSendEvent = handlingSendEvent
    }

    @objc func addNativeEventProcessorObserver(_ observer: UnsafeMutableRawPointer) {
        OrbitNativeEventState.observers.append(observer)
    }

    @objc func removeNativeEventProcessorObserver(_ observer: UnsafeMutableRawPointer) {
        OrbitNativeEventState.observers.removeAll { $0 == observer }
    }

    // method_exchangeImplementations swapped this selector's IMP with -sendEvent:'s,
    // so calling orbitSendEvent(_:) here by name reaches the original -sendEvent:.
    // Only reached once OrbitChromiumBridge's swizzle has run; not meant to be called directly.
    @objc func orbitSendEvent(_ event: NSEvent) {
        let previous = OrbitNativeEventState.handlingSendEvent
        OrbitNativeEventState.handlingSendEvent = true

        // The NSEvent's own pointer value, reinterpreted, never dereferenced.
        let identifier = UInt(bitPattern: Unmanaged.passUnretained(event).toOpaque())
        let bridge = OrbitChromiumBridge.shared
        for observer in OrbitNativeEventState.observers {
            bridge.notifyWillRunNativeEvent(observer, identifier)
        }

        // Post-swizzle, this selector holds NSApplication's original
        // -sendEvent: implementation.
        self.orbitSendEvent(event)

        for observer in OrbitNativeEventState.observers {
            bridge.notifyDidRunNativeEvent(observer, identifier)
        }

        OrbitNativeEventState.handlingSendEvent = previous
    }
}
