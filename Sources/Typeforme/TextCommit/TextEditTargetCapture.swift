import AppKit
import ApplicationServices

enum TextEditTargetKind {
    case selection
    case focusedValue
}

struct TextEditTargetSnapshot {
    let kind: TextEditTargetKind
    let element: AXUIElement
    let targetText: String
    let contextBefore: String
    let contextAfter: String
}

enum TextEditTargetCapture {
    private static let contextLimit = 600

    @MainActor
    static func snapshot(
        in appSnapshot: FrontmostAppSnapshot?,
        allowFocusedValue: Bool
    ) -> TextEditTargetSnapshot? {
        guard AccessibilityPermissions.isTrusted else { return nil }
        guard let appSnapshot else { return nil }
        let app = AXUIElementCreateApplication(appSnapshot.pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let focused = focusedElement(in: app) else { return nil }
        AXUIElementSetMessagingTimeout(focused, 0.25)

        if let selected = stringAttribute(kAXSelectedTextAttribute, from: focused),
           !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let context = contextAroundSelection(in: focused)
            return TextEditTargetSnapshot(
                kind: .selection,
                element: focused,
                targetText: selected,
                contextBefore: context.before,
                contextAfter: context.after
            )
        }

        guard allowFocusedValue,
              let value = stringAttribute(kAXValueAttribute, from: focused),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        return TextEditTargetSnapshot(
            kind: .focusedValue,
            element: focused,
            targetText: value,
            contextBefore: "",
            contextAfter: ""
        )
    }

    static func currentSelectedText(in appSnapshot: FrontmostAppSnapshot?) -> String? {
        guard AccessibilityPermissions.isTrusted else { return nil }
        guard let appSnapshot else { return nil }
        let app = AXUIElementCreateApplication(appSnapshot.pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let focused = focusedElement(in: app) else { return nil }
        AXUIElementSetMessagingTimeout(focused, 0.25)
        return stringAttribute(kAXSelectedTextAttribute, from: focused)
    }

    @MainActor
    static func focusedTextContext(in appSnapshot: FrontmostAppSnapshot?) -> (before: String, after: String) {
        guard AccessibilityPermissions.isTrusted else { return ("", "") }
        guard let appSnapshot else { return ("", "") }
        let app = AXUIElementCreateApplication(appSnapshot.pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let focused = focusedElement(in: app) else { return ("", "") }
        AXUIElementSetMessagingTimeout(focused, 0.25)
        return contextAroundSelection(in: focused)
    }

    static func currentValue(of target: TextEditTargetSnapshot) -> String? {
        stringAttribute(kAXValueAttribute, from: target.element)
    }

    static func setFocusedValue(_ text: String, target: TextEditTargetSnapshot) -> Bool {
        var settable = DarwinBoolean(false)
        let check = AXUIElementIsAttributeSettable(target.element, kAXValueAttribute as CFString, &settable)
        guard check == .success, settable.boolValue else { return false }
        return AXUIElementSetAttributeValue(target.element, kAXValueAttribute as CFString, text as CFTypeRef) == .success
    }

    private static func focusedElement(in app: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success else {
            return nil
        }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func contextAroundSelection(in element: AXUIElement) -> (before: String, after: String) {
        guard let fullValue = stringAttribute(kAXValueAttribute, from: element) else {
            return ("", "")
        }
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef,
              CFGetTypeID(rangeRef) == AXValueGetTypeID()
        else {
            return ("", "")
        }
        let axValue = rangeRef as! AXValue

        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range), range.location >= 0, range.length >= 0 else {
            return ("", "")
        }
        let ns = fullValue as NSString
        guard range.location <= ns.length else { return ("", "") }
        let start = max(0, range.location - contextLimit)
        let beforeLength = range.location - start
        let afterStart = min(ns.length, range.location + range.length)
        let afterLength = min(contextLimit, ns.length - afterStart)
        return (
            ns.substring(with: NSRange(location: start, length: beforeLength)),
            ns.substring(with: NSRange(location: afterStart, length: afterLength))
        )
    }
}
