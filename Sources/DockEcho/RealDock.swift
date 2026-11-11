import AppKit
import ApplicationServices

/// Watches the real macOS Dock through the Accessibility API: which icon the pointer is on
/// (to show window previews above it) and which display the Dock is currently on.
final class RealDockWatcher {
    var onHover: ((DockHover) -> Void)?
    var onDockDisplayChange: (() -> Void)?

    /// Display currently showing the real Dock, when it could be determined.
    private(set) var dockDisplay: CGDirectDisplayID?

    private var pid: pid_t = 0
    private var observer: AXObserver?
    private var list: AXUIElement?
    private var timer: Timer?

    func start() {
        refresh()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Also re-attaches when the Dock restarts (its process changes on every `killall Dock`).
    private func refresh() {
        attachIfNeeded()
        updateDockDisplay()
    }

    private func attachIfNeeded() {
        guard Permissions.accessibility,
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return }
        if dock.processIdentifier == pid && observer != nil { return }
        detach()

        let dockPid = dock.processIdentifier
        let app = AXUIElementCreateApplication(dockPid)
        guard let list = AX.children(app).first(where: { AX.string($0, kAXRoleAttribute) == kAXListRole }) else { return }
        var created: AXObserver?
        guard AXObserverCreate(dockPid, Self.callback, &created) == .success, let observer = created else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, list, kAXSelectedChildrenChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)

        self.pid = dockPid
        self.observer = observer
        self.list = list
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        list = nil
        pid = 0
    }

    private static let callback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        Unmanaged<RealDockWatcher>.fromOpaque(refcon).takeUnretainedValue().selectionChanged()
    }

    /// The Dock "selects" the icon under the pointer.
    private func selectionChanged() {
        guard let list,
              let selected = AX.attribute(list, kAXSelectedChildrenAttribute) as? [AXUIElement],
              let item = selected.first else {
            onHover?(.away)
            return
        }
        guard AX.string(item, kAXSubroleAttribute) == "AXApplicationDockItem",
              let url = AX.url(item),
              let bundleID = Bundle(url: url)?.bundleIdentifier,
              let frame = AX.frame(item) else {
            onHover?(.other)
            return
        }
        let rect = ScreenGeometry.cocoa(fromQuartz: frame)
        guard let screen = ScreenGeometry.screen(for: rect) else { onHover?(.other); return }
        setDockDisplay(ScreenGeometry.displayID(screen))
        onHover?(.app(HoverTarget(bundleID: bundleID, anchor: rect, screen: screen,
                                  orientation: DockSettings.load().orientation)))
    }

    private func updateDockDisplay() {
        guard let list, let frame = AX.frame(list) else { return }
        let rect = ScreenGeometry.cocoa(fromQuartz: frame)
        // A hidden Dock sits just past the screen edge: only trust a frame that is mostly on screen.
        guard let screen = ScreenGeometry.screen(for: rect),
              ScreenGeometry.coverage(of: rect, on: screen) > 0.5 else { return }
        setDockDisplay(ScreenGeometry.displayID(screen))
    }

    private func setDockDisplay(_ id: CGDirectDisplayID) {
        guard id != dockDisplay else { return }
        dockDisplay = id
        onDockDisplayChange?()
    }
}
