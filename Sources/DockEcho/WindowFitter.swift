import AppKit
import ApplicationServices

/// Space taken by a copy on its display, along the Dock's edge.
struct DockReservation {
    let screenFrame: NSRect      // Cocoa coordinates
    let visibleFrame: NSRect     // what macOS considers usable (it ignores the copies)
    let orientation: DockOrientation
    let inset: CGFloat           // depth of the copy's shelf from the screen edge
}

/// macOS only keeps zoomed, filled and tiled windows clear of the real Dock: on the other
/// displays they end up under DockEcho's copy. This shortens the windows of the active app that
/// are snapped to the Dock's edge of a display with a copy so they stop at the shelf, like the
/// real Dock does.
final class WindowFitter {
    private static let enabledKey = "keepWindowsClearOfDock"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Current reservations, one per display with a visible (not auto-hidden) copy.
    var reservations: (() -> [DockReservation])?

    private var timer: Timer?
    private let queue = DispatchQueue(label: "DockEcho.WindowFitter", qos: .userInitiated)
    private var busy = false

    func start() {
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    @objc private func appActivated() { tick() }

    private func tick() {
        guard Self.isEnabled, !busy, Permissions.accessibility,
              NSEvent.pressedMouseButtons == 0,          // never fight a drag or a live resize
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              let list = reservations?(), !list.isEmpty else { return }
        let pid = app.processIdentifier
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        busy = true
        // Accessibility calls can block on a busy app: keep them off the main thread.
        queue.async { [weak self] in
            Self.fit(pid: pid, reservations: list, primaryHeight: primaryHeight)
            DispatchQueue.main.async { self?.busy = false }
        }
    }

    private static func fit(pid: pid_t, reservations: [DockReservation], primaryHeight: CGFloat) {
        for w in AX.windows(of: pid) {
            guard AX.string(w, kAXSubroleAttribute) == kAXStandardWindowSubrole,
                  AX.bool(w, kAXMinimizedAttribute) != true,
                  AX.bool(w, "AXFullScreen") != true,
                  let q = AX.frame(w) else { continue }
            // Cocoa frame (y up from the bottom of the primary display).
            let f = NSRect(x: q.minX, y: primaryHeight - q.maxY, width: q.width, height: q.height)
            guard let r = reservation(for: f, in: reservations) else { continue }
            let s = r.screenFrame
            let tolerance: CGFloat = 2
            let minLength: CGFloat = 120

            switch r.orientation {
            case .bottom:
                let limit = s.minY + r.inset
                guard abs(f.minY - r.visibleFrame.minY) <= tolerance, f.minY < limit - 1,
                      f.maxY - limit >= minLength else { continue }
                // The top edge stays put: in Quartz coordinates only the height changes.
                AX.set(w, size: CGSize(width: f.width, height: f.maxY - limit))
            case .left:
                let limit = s.minX + r.inset
                guard abs(f.minX - r.visibleFrame.minX) <= tolerance, f.minX < limit - 1,
                      f.maxX - limit >= minLength else { continue }
                AX.set(w, position: CGPoint(x: limit, y: q.minY))
                AX.set(w, size: CGSize(width: f.maxX - limit, height: f.height))
            case .right:
                let limit = s.maxX - r.inset
                guard abs(f.maxX - r.visibleFrame.maxX) <= tolerance, f.maxX > limit + 1,
                      limit - f.minX >= minLength else { continue }
                AX.set(w, size: CGSize(width: limit - f.minX, height: f.height))
            }
        }
    }

    /// The reservation of the display showing most of the window.
    private static func reservation(for f: NSRect, in list: [DockReservation]) -> DockReservation? {
        func area(_ r: NSRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
        guard let best = list.max(by: { area($0.screenFrame.intersection(f)) < area($1.screenFrame.intersection(f)) }),
              area(best.screenFrame.intersection(f)) > area(f) / 2 else { return nil }
        return best
    }
}
