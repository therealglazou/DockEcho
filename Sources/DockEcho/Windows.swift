import AppKit
import ApplicationServices

/// Private but long-standing API (used by most window managers): the CGWindowID behind an AX window.
@_silgen_name("_AXUIElementGetWindow")
@discardableResult
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

extension AX {
    static func attribute(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success ? value : nil
    }

    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let value = attribute(el, attr), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        attribute(el, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    static func url(_ el: AXUIElement) -> URL? {
        guard let value = attribute(el, kAXURLAttribute) else { return nil }
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }

    /// Frame in Quartz coordinates (top-left origin).
    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = point(el), let s = size(el) else { return nil }
        return CGRect(origin: p, size: s)
    }

    static func setBool(_ el: AXUIElement, _ attr: String, _ value: Bool) {
        AXUIElementSetAttributeValue(el, attr as CFString, NSNumber(value: value))
    }

    @discardableResult
    static func perform(_ el: AXUIElement, _ action: String) -> Bool {
        AXUIElementPerformAction(el, action as CFString) == .success
    }

    static func windowID(_ el: AXUIElement) -> CGWindowID {
        var id: CGWindowID = 0
        _AXUIElementGetWindow(el, &id)
        return id
    }
}

/// A window shown in the previews.
struct WindowInfo {
    let element: AXUIElement
    let windowID: CGWindowID      // 0 when unknown
    let pid: pid_t
    let title: String
    let isMinimized: Bool

    func isSame(as other: WindowInfo) -> Bool { CFEqual(element, other.element) }
}

enum WindowList {
    /// Standard windows and dialogs of an app, minimized ones included.
    /// The Accessibility API only exposes the windows of the current Space.
    static func windows(of app: NSRunningApplication) -> [WindowInfo] {
        let pid = app.processIdentifier
        var candidates: [(id: CGWindowID, bounds: CGRect)]?   // loaded only if needed
        var used = Set<CGWindowID>()
        return AX.windows(of: pid).compactMap { w in
            guard AX.string(w, kAXRoleAttribute) == kAXWindowRole else { return nil }
            let subrole = AX.string(w, kAXSubroleAttribute)
            guard subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole,
                  let size = AX.size(w), size.width >= 60, size.height >= 40 else { return nil }
            let minimized = AX.bool(w, kAXMinimizedAttribute) ?? false

            // The window id comes from a private call; if it gives nothing, match the window
            // with the window server's list by owner and frame (both use Quartz coordinates).
            var id = AX.windowID(w)
            if id == 0, !minimized, let frame = AX.frame(w) {
                if candidates == nil { candidates = serverWindows(of: pid) }
                if let match = candidates?.first(where: { c in
                    !used.contains(c.id)
                        && abs(c.bounds.minX - frame.minX) < 2 && abs(c.bounds.minY - frame.minY) < 2
                        && abs(c.bounds.width - frame.width) < 2 && abs(c.bounds.height - frame.height) < 2
                }) {
                    id = match.id
                }
            }
            if id != 0 { used.insert(id) }

            return WindowInfo(element: w,
                              windowID: id,
                              pid: pid,
                              title: AX.string(w, kAXTitleAttribute) ?? "",
                              isMinimized: minimized)
        }
    }

    /// Normal-level windows of a process, as the window server lists them (needs no permission
    /// for ids and bounds).
    private static func serverWindows(of pid: pid_t) -> [(id: CGWindowID, bounds: CGRect)] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = info[kCGWindowNumber as String] as? NSNumber,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            return (number.uint32Value, bounds)
        }
    }

    static func contains(_ window: WindowInfo) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: window.pid) else { return false }
        return windows(of: app).contains { $0.isSame(as: window) }
    }
}

enum WindowActions {
    /// Presses the window's close button. Returns false if it has none.
    @discardableResult
    static func close(_ window: WindowInfo) -> Bool {
        guard let button = AX.element(window.element, kAXCloseButtonAttribute) else { return false }
        return AX.perform(button, kAXPressAction)
    }

    /// Brings the window to the front on `screen`: un-minimizes it, moves it there if it is on
    /// another display, activates its app and raises it above the app's other windows.
    static func focus(_ window: WindowInfo, onto screen: NSScreen) {
        let app = NSRunningApplication(processIdentifier: window.pid)
        if app?.isHidden == true { app?.unhide() }
        if AX.bool(window.element, kAXMinimizedAttribute) == true {
            AX.setBool(window.element, kAXMinimizedAttribute, false)
        }
        if AX.bool(window.element, "AXFullScreen") != true {
            move(window.element, onto: screen)
        }
        AX.setBool(AXUIElementCreateApplication(window.pid), kAXFrontmostAttribute, true)
        raise(window.element)
        // Some apps reorder their windows while they activate: raise once more when that has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { raise(window.element) }
    }

    private static func raise(_ el: AXUIElement) {
        AX.perform(el, kAXRaiseAction)
        AX.setBool(el, kAXMainAttribute, true)
        AX.setBool(el, kAXFocusedAttribute, true)
    }

    /// Moves a window to `screen`, keeping its size (shrunk if needed) and its relative place.
    private static func move(_ el: AXUIElement, onto screen: NSScreen) {
        guard let q = AX.frame(el) else { return }
        let current = ScreenGeometry.cocoa(fromQuartz: q)
        let source = ScreenGeometry.screen(for: current)
        if let source, ScreenGeometry.displayID(source) == ScreenGeometry.displayID(screen) { return }

        let from = source?.visibleFrame ?? screen.visibleFrame
        let to = screen.visibleFrame
        let w = min(current.width, to.width)
        let h = min(current.height, to.height)
        let rx = from.width > 0 ? (current.midX - from.minX) / from.width : 0.5
        let ry = from.height > 0 ? (current.midY - from.minY) / from.height : 0.5
        let x = min(max(to.minX + rx * to.width - w / 2, to.minX), to.maxX - w)
        let y = min(max(to.minY + ry * to.height - h / 2, to.minY), to.maxY - h)
        let target = ScreenGeometry.quartz(fromCocoa: NSRect(x: x, y: y, width: w, height: h))
        AX.set(el, position: target.origin)
        AX.set(el, size: target.size)
        AX.set(el, position: target.origin)   // the size may have been clamped on the old display
    }
}
