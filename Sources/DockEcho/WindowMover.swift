import AppKit
import ApplicationServices

/// Brings an app's main window to the display whose Dock copy was clicked, when the app has
/// no visible window there. Uses the Accessibility API, so DockEcho must be allowed in
/// System Settings › Privacy & Security › Accessibility (Device Control and Data Access
/// since macOS 27); without it, nothing is moved.
///
/// Accessibility calls are synchronous IPC with the target app: they run on a private
/// queue with a short timeout, so an unresponsive app cannot freeze DockEcho.
/// Everything else (state, NSScreen, completions) lives on the main thread.
enum WindowMover {
    enum Outcome {
        case placed      // a window of the app is now on the target display
        case noWindow    // the app has no usable window yet
        case failed      // temporary error (timeout, window closing…): worth retrying
        case unmovable   // the window cannot be moved: give up

        var shouldRetry: Bool { self == .noWindow || self == .failed }
    }

    private static let enabledKey = "openOnClickedDisplay"
    private static let queue = DispatchQueue(label: "DockEcho.WindowMover", qos: .userInitiated)
    private static let messagingTimeout: Float = 0.25     // seconds, per Accessibility call
    private static let retryInterval = 0.25               // seconds
    private static let maxWait: TimeInterval = 15         // enough for slow launches

    // Main thread only
    private static var didPrompt = false
    private static var generations: [pid_t: Int] = [:]   // latest request per app

    /// Menu bar option, off by default (the real Dock never moves windows).
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            if newValue { _ = isAllowed }      // ask for the permission right away
        }
    }

    /// True when the option is on and DockEcho may move windows.
    /// Asks for the Accessibility permission once per run.
    static var isActive: Bool { isEnabled && isAllowed }

    /// The option is on but cannot work: the permission is missing (or was invalidated,
    /// e.g. by an ad-hoc re-signature).
    /// Uses the effective access (see Permissions): AXIsProcessTrusted alone can be wrong.
    static var needsPermission: Bool { isEnabled && !Permissions.accessibility }

    private static var isAllowed: Bool {
        if Permissions.accessibility { return true }
        if !didPrompt {
            didPrompt = true
            Permissions.requestAccessibility()
        }
        return false
    }

    // MARK: Requests (main thread)

    /// One attempt; `completion` is called on the main thread.
    /// Cancels any pending retries for the same app.
    static func place(pid: pid_t, on screen: NSScreen, completion: @escaping (Outcome) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        _ = newGeneration(for: pid)
        attempt(pid: pid, on: screen, completion: completion)
    }

    /// Retries until the app shows a window (just launched, or reopened with no window).
    /// Stops when a newer request is made for the app, when the option is turned off,
    /// or when the display goes away.
    static func bringWhenReady(pid: pid_t, to screen: NSScreen) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let display = displayID(of: screen) else { return }
        let generation = newGeneration(for: pid)
        schedule(pid: pid, display: display, generation: generation, deadline: Date() + maxWait)
    }

    private static func newGeneration(for pid: pid_t) -> Int {
        let g = (generations[pid] ?? 0) + 1
        generations[pid] = g
        return g
    }

    private static func schedule(pid: pid_t, display: CGDirectDisplayID, generation: Int, deadline: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + retryInterval) {
            // Re-checked at every attempt: stale requests and a disabled option stop here.
            // A wall-clock deadline: each attempt also spends time in Accessibility calls.
            guard generations[pid] == generation else { return }
            guard isEnabled, Date() < deadline,
                  let screen = NSScreen.screens.first(where: { displayID(of: $0) == display }) else {
                generations[pid] = nil
                return
            }
            attempt(pid: pid, on: screen) { outcome in
                guard generations[pid] == generation else { return }
                if outcome.shouldRetry {
                    schedule(pid: pid, display: display, generation: generation, deadline: deadline)
                } else {
                    generations[pid] = nil
                }
            }
        }
    }

    private static func attempt(pid: pid_t, on screen: NSScreen, completion: @escaping (Outcome) -> Void) {
        // NSScreen is read here, on the main thread; the queue only gets plain rects.
        let full = axRect(screen.frame)
        let visible = axRect(screen.visibleFrame)
        queue.async {
            let outcome = move(pid: pid, full: full, visible: visible)
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    // MARK: Accessibility work (private queue)

    private static func move(pid: pid_t, full: CGRect, visible: CGRect) -> Outcome {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)

        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) {
        case .success: break
        case .apiDisabled: return .unmovable
        default: return .failed                 // timeout, app still launching…
        }
        let windows = ((value as? [AXUIElement]) ?? []).filter(isUsable)
        guard !windows.isEmpty else { return .noWindow }

        let main = element(app, kAXMainWindowAttribute).flatMap { m in windows.first { CFEqual($0, m) } }
            ?? element(app, kAXFocusedWindowAttribute).flatMap { f in windows.first { CFEqual($0, f) } }
            ?? windows[0]

        // A window is already there: raise it, so the activation that follows brings this
        // one forward rather than the key window on the other display.
        let onTarget = windows.filter { w in frame(of: w).map { full.contains(center($0)) } ?? false }
        if let w = onTarget.first(where: { CFEqual($0, main) }) ?? onTarget.first {
            raise(w)
            return .placed
        }

        guard isSettable(main, kAXPositionAttribute) else { return .unmovable }
        guard let start = frame(of: main) else { return .failed }

        // Shrink to the visible area if needed, then use the size the app actually accepted
        // (minimum sizes, fixed-size windows).
        if start.width > visible.width || start.height > visible.height,
           isSettable(main, kAXSizeAttribute) {
            set(main, kAXSizeAttribute,
                CGSize(width: min(start.width, visible.width), height: min(start.height, visible.height)))
        }
        guard let sized = frame(of: main) else { return .failed }

        // Centered, but the top-left corner (title bar) always stays inside the visible area.
        let origin = CGPoint(x: max(visible.minX, min(visible.midX - sized.width / 2, visible.maxX - sized.width)),
                             y: max(visible.minY, min(visible.midY - sized.height / 2, visible.maxY - sized.height)))
        guard set(main, kAXPositionAttribute, origin) == .success,
              let moved = frame(of: main), full.contains(center(moved)) else { return .failed }

        raise(main)
        return .placed
    }

    private static func isUsable(_ w: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(w, messagingTimeout)
        return string(w, kAXSubroleAttribute) == kAXStandardWindowSubrole as String
            && !bool(w, kAXMinimizedAttribute)
            && !bool(w, "AXFullScreen")
    }

    private static func raise(_ w: AXUIElement) {
        AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
    }

    // MARK: Accessibility helpers

    private static func element(_ e: AXUIElement, _ attr: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func string(_ e: AXUIElement, _ attr: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func bool(_ e: AXUIElement, _ attr: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }

    private static func isSettable(_ e: AXUIElement, _ attr: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(e, attr as CFString, &settable) == .success && settable.boolValue
    }

    private static func frame(of w: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size,
              CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pos as! AXValue, .cgPoint, &p),
              AXValueGetValue(size as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    @discardableResult
    private static func set(_ w: AXUIElement, _ attr: String, _ point: CGPoint) -> AXError {
        var p = point
        return set(w, attr, AXValueCreate(.cgPoint, &p))
    }

    @discardableResult
    private static func set(_ w: AXUIElement, _ attr: String, _ size: CGSize) -> AXError {
        var s = size
        return set(w, attr, AXValueCreate(.cgSize, &s))
    }

    private static func set(_ w: AXUIElement, _ attr: String, _ value: AXValue?) -> AXError {
        guard let value else { return .failure }
        return AXUIElementSetAttributeValue(w, attr as CFString, value)
    }

    private static func center(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Cocoa coordinates (origin bottom-left of the primary display) → Accessibility
    /// coordinates (origin top-left of the primary display).
    private static func axRect(_ r: NSRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
}
