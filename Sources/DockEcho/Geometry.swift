import AppKit

/// Screen helpers. Two coordinate systems meet here: Cocoa (origin at the bottom-left of the
/// primary display, y up) and Quartz / Accessibility (origin at the top-left, y down).
enum ScreenGeometry {
    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func cocoa(fromQuartz r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func quartz(fromCocoa r: NSRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Stable identifier of a display (survives reordering of NSScreen.screens).
    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
    }

    static func screen(withID id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { displayID($0) == id }
    }

    private static func area(_ r: NSRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }

    /// Fraction of `rect` that lies on `screen` (0...1).
    static func coverage(of rect: NSRect, on screen: NSScreen) -> CGFloat {
        let a = area(rect)
        return a > 0 ? area(screen.frame.intersection(rect)) / a : 0
    }

    /// The screen showing most of `rect`, or the nearest one.
    static func screen(for rect: NSRect) -> NSScreen? {
        let screens = NSScreen.screens
        if let best = screens.max(by: { area($0.frame.intersection(rect)) < area($1.frame.intersection(rect)) }),
           area(best.frame.intersection(rect)) > 0 {
            return best
        }
        let c = NSPoint(x: rect.midX, y: rect.midY)
        func distance(_ s: NSScreen) -> CGFloat { hypot(s.frame.midX - c.x, s.frame.midY - c.y) }
        return screens.min { distance($0) < distance($1) }
    }
}
