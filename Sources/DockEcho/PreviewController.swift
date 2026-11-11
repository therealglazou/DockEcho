import AppKit

/// An icon hovered in the real Dock or in one of its copies.
struct HoverTarget {
    let bundleID: String
    let anchor: NSRect              // screen area the panel sits next to
    let screen: NSScreen            // display of the Dock that was used
    let orientation: DockOrientation

    func sameIcon(as other: HoverTarget?) -> Bool {
        guard let other else { return false }
        return other.bundleID == bundleID
            && ScreenGeometry.displayID(other.screen) == ScreenGeometry.displayID(screen)
    }
}

/// What the pointer is on, in the real Dock or one of its copies.
enum DockHover {
    case app(HoverTarget)   // a running app's icon
    case other              // another icon (not running, folder, Trash...): previews go away
    case away               // no icon: the pointer may be on its way to the previews
}

/// Shows the window thumbnails of the hovered app, above its Dock icon.
final class PreviewController {
    private static let enabledKey = "showWindowPreviews"

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            if newValue { requestPermissionsIfNeeded() } else { hideNow() }
        }
    }

    private let panel = PreviewPanel()
    private var target: HoverTarget?
    private var pendingShow: DispatchWorkItem?
    private var tracker: Timer?
    private var outsideSince: Date?
    private var generation = 0
    private var clickMonitor: Any?

    init() {
        panel.content.onSelect = { [weak self] info in self?.select(info) }
        panel.content.onClose = { [weak self] info in self?.close(info) }
        // A click anywhere else (on the real Dock too) dismisses the previews. Clicks in
        // DockEcho's own windows are not seen here; the copies report them separately.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hideNow()
        }
    }

    func requestPermissionsIfNeeded() {
        if !Permissions.accessibility { Permissions.requestAccessibility() }
        if !Permissions.screenRecording { Permissions.requestScreenRecording() }
    }

    func hover(_ hover: DockHover) {
        pendingShow?.cancel()
        pendingShow = nil
        guard isEnabled else { return }
        let newTarget: HoverTarget
        switch hover {
        case .away: return                  // the tracker decides when to hide
        case .other: hideNow(); return
        case .app(let t): newTarget = t
        }
        if panel.isVisible {
            if newTarget.sameIcon(as: target) { target = newTarget } else { show(newTarget) }
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.show(newTarget) }
        pendingShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func hideNow() {
        pendingShow?.cancel()
        pendingShow = nil
        generation += 1                      // late thumbnails are ignored
        tracker?.invalidate()
        tracker = nil
        outsideSince = nil
        target = nil
        panel.orderOut(nil)
    }

    // MARK: Showing

    private func show(_ newTarget: HoverTarget) {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: newTarget.bundleID)
        guard let app = apps.first(where: { $0.activationPolicy == .regular }) ?? apps.first else {
            hideNow()
            return
        }
        let windows = WindowList.windows(of: app)
        guard !windows.isEmpty else { hideNow(); return }

        generation += 1
        let current = generation
        target = newTarget
        let maxWidth = (newTarget.orientation == .bottom ? newTarget.screen.frame.width
                                                         : newTarget.screen.frame.width / 2) - 40
        let icon = app.icon ?? NSWorkspace.shared.icon(forFile: app.bundleURL?.path ?? "/")
        let size = panel.content.show(appName: app.localizedName ?? "", windows: windows,
                                      placeholder: icon, maxWidth: maxWidth)
        place(size)
        panel.orderFrontRegardless()
        startTracking()

        let ids = windows.filter { !$0.isMinimized }.map(\.windowID)
        Thumbnailer.capture(ids, maxPoints: 220) { [weak self] id, image in
            guard let self, self.generation == current else { return }
            self.panel.content.setThumbnail(image, for: id)
        }
    }

    /// Next to the icon, on the side away from the screen edge, kept on the same display.
    private func place(_ size: NSSize) {
        guard let t = target else { return }
        let bounds = t.screen.frame.insetBy(dx: 8, dy: 8)
        let gap: CGFloat = 8
        var origin: NSPoint
        switch t.orientation {
        case .bottom: origin = NSPoint(x: t.anchor.midX - size.width / 2, y: t.anchor.maxY + gap)
        case .left:   origin = NSPoint(x: t.anchor.maxX + gap, y: t.anchor.midY - size.height / 2)
        case .right:  origin = NSPoint(x: t.anchor.minX - gap - size.width, y: t.anchor.midY - size.height / 2)
        }
        origin.x = min(max(origin.x, bounds.minX), bounds.maxX - size.width)
        origin.y = min(max(origin.y, bounds.minY), bounds.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.content.layoutTiles()
    }

    // MARK: Hiding when the pointer leaves

    private func startTracking() {
        outsideSince = nil
        guard tracker == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.track() }
        RunLoop.main.add(timer, forMode: .common)
        tracker = timer
    }

    /// Keeps the panel while the pointer is on it, on the icon, or between the two.
    private func track() {
        guard panel.isVisible, let t = target else { hideNow(); return }
        let zone = panel.frame.union(t.anchor).insetBy(dx: -6, dy: -6)
        if zone.contains(NSEvent.mouseLocation) {
            outsideSince = nil
        } else if let since = outsideSince {
            if Date().timeIntervalSince(since) > 0.25 { hideNow() }
        } else {
            outsideSince = Date()
        }
    }

    // MARK: Actions

    /// Brings the window forward on the display of the Dock that was used.
    private func select(_ info: WindowInfo) {
        guard let screen = target?.screen else { return }
        hideNow()
        WindowActions.focus(info, onto: screen)
    }

    private func close(_ info: WindowInfo) {
        guard let screen = target?.screen else { return }
        guard WindowActions.close(info) else { NSSound.beep(); return }
        let size = panel.content.remove(info)
        if panel.content.isEmpty { hideNow() } else { place(size) }
        // The app may ask to save first: if the window is still there, bring it forward
        // (on the same display) so its dialog can be seen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard WindowList.contains(info) else { return }
            self?.hideNow()
            WindowActions.focus(info, onto: screen)
        }
    }
}
