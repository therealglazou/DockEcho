import AppKit

final class DockWindow: NSPanel {
    private let root = DockRootView()
    private var items: [DockItem] = []
    private var settings = DockSettings()
    private var metrics = DockMetrics(settings: DockSettings())
    private var screenFrame = NSRect.zero
    private var shownFrame = NSRect.zero
    private(set) var displayID: CGDirectDisplayID = 0

    private var isRevealed = true
    private var edgeSince: Date?
    private var leaveSince: Date?

    var onHover: ((DockHover) -> Void)?
    var onIconClick: (() -> Void)?

    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        contentView = root
        root.icons.onHoverItem = { [weak self] item, rect in self?.reportHover(item, rect) }
        root.icons.onPress = { [weak self] in self?.onIconClick?() }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    func update(items newItems: [DockItem], settings newSettings: DockSettings, on screen: NSScreen) {
        items = newItems
        screenFrame = screen.frame
        displayID = ScreenGeometry.displayID(screen)

        let vertical = newSettings.orientation != .bottom
        let available = vertical ? screen.frame.height : screen.frame.width
        let fitted = DockMetrics.fitted(newSettings, items: newItems, available: available)

        let wasAutohide = settings.autohide
        settings = fitted
        metrics = DockMetrics(settings: fitted)
        root.configure(items: newItems, settings: fitted)

        let length = min(metrics.windowLength(newItems), available)
        let thickness = min(metrics.thickness, vertical ? screen.frame.width : screen.frame.height)
        let margin: CGFloat = 4

        switch fitted.orientation {
        case .bottom:
            shownFrame = NSRect(x: screen.frame.midX - length / 2, y: screen.frame.minY + margin,
                                width: length, height: thickness)
        case .left:
            shownFrame = NSRect(x: screen.frame.minX + margin, y: screen.frame.midY - length / 2,
                                width: thickness, height: length)
        case .right:
            shownFrame = NSRect(x: screen.frame.maxX - margin - thickness, y: screen.frame.midY - length / 2,
                                width: thickness, height: length)
        }
        setFrame(shownFrame, display: true)

        if fitted.autohide {
            if !wasAutohide { setRevealed(false, animated: false) }
        } else {
            setRevealed(true, animated: false)
        }
    }

    var diagnostics: String {
        "Copy on display \(displayID): frame \(frame), on screen \(screen.map { ScreenGeometry.displayID($0) } ?? 0), "
            + "visible \(isVisible), alpha \(alphaValue), \(items.count) items"
    }

    // MARK: Window previews

    private func reportHover(_ item: DockItem?, _ rectInView: NSRect) {
        guard let item else { onHover?(.away); return }
        guard item.kind == .app, item.isRunning,
              let screen = ScreenGeometry.screen(withID: displayID) else {
            onHover?(.other)
            return
        }
        let icon = convertToScreen(root.icons.convert(rectInView, to: nil))
        // The previews sit beyond the magnified icons, not over them.
        let reach = 4 + metrics.shelfThickness + metrics.overhang
        let f = screen.frame
        let anchor: NSRect
        switch metrics.orientation {
        case .bottom: anchor = NSRect(x: icon.minX, y: f.minY, width: icon.width, height: reach)
        case .left:   anchor = NSRect(x: f.minX, y: icon.minY, width: reach, height: icon.height)
        case .right:  anchor = NSRect(x: f.maxX - reach, y: icon.minY, width: reach, height: icon.height)
        }
        onHover?(.app(HoverTarget(bundleID: item.id, anchor: anchor, screen: screen, orientation: metrics.orientation)))
    }

    // MARK: Auto-hide

    private func zone(depth: CGFloat, extra: CGFloat) -> NSRect {
        let total = metrics.baseLayout(items).total + extra * 2
        switch metrics.orientation {
        case .bottom:
            return NSRect(x: shownFrame.midX - total / 2, y: screenFrame.minY, width: total, height: depth)
        case .left:
            return NSRect(x: screenFrame.minX, y: shownFrame.midY - total / 2, width: depth, height: total)
        case .right:
            return NSRect(x: screenFrame.maxX - depth, y: shownFrame.midY - total / 2, width: depth, height: total)
        }
    }

    private func setRevealed(_ revealed: Bool, animated: Bool) {
        isRevealed = revealed
        edgeSince = nil
        leaveSince = nil
        ignoresMouseEvents = !revealed
        if !revealed { root.icons.resetHover() }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = max(0.05, 0.25 * settings.autohideTimeModifier)
                self.animator().alphaValue = revealed ? 1 : 0
            }
        } else {
            alphaValue = revealed ? 1 : 0
        }
    }

    /// Called about 20 times per second while auto-hide is active.
    func autohideTick(mouse: NSPoint) {
        guard settings.autohide else { return }
        let now = Date()
        if isRevealed {
            let active = zone(depth: 4 + metrics.shelfThickness + metrics.overhang + 12, extra: metrics.base)
            if active.contains(mouse) {
                leaveSince = nil
            } else {
                if leaveSince == nil { leaveSince = now }
                if now.timeIntervalSince(leaveSince!) > 0.15 { setRevealed(false, animated: true) }
            }
        } else {
            let hot = zone(depth: 3, extra: metrics.base * 2)
            if hot.contains(mouse) {
                if edgeSince == nil { edgeSince = now }
                if now.timeIntervalSince(edgeSince!) >= settings.autohideDelay { setRevealed(true, animated: true) }
            } else {
                edgeSince = nil
            }
        }
    }
}

final class DockController {
    private static let includePrimaryKey = "includePrimaryScreen"

    /// One copy per display, keyed by display id (stable when displays are added, removed or reordered).
    private var windows: [CGDirectDisplayID: DockWindow] = [:]
    private var items: [DockItem] = []
    private var settings = DockSettings()
    private var lastRaw: NSDictionary = [:]
    private var prefsTimer: Timer?
    private var autohideTimer: Timer?
    private var screenWork: [DispatchWorkItem] = []

    var onHover: ((DockHover) -> Void)?
    var onIconClick: (() -> Void)?
    /// The display currently showing the real Dock (nil: unknown, the primary display is assumed).
    var realDockDisplay: (() -> CGDirectDisplayID?)?

    /// By default the display showing the real Dock gets no copy.
    var includePrimaryScreen: Bool {
        get { UserDefaults.standard.bool(forKey: Self.includePrimaryKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.includePrimaryKey)
            reconcileWindows()
        }
    }

    private var targetScreens: [NSScreen] {
        let all = NSScreen.screens
        if includePrimaryScreen { return all }
        guard let primary = all.first else { return [] }
        let primaryID = ScreenGeometry.displayID(primary)
        let real = realDockDisplay?() ?? primaryID
        // A stale id (display just unplugged) falls back to the primary display.
        let skip = all.contains { ScreenGeometry.displayID($0) == real } ? real : primaryID
        return all.filter { ScreenGeometry.displayID($0) != skip }
    }

    func start() {
        TrashState.refresh()
        lastRaw = DockSettings.rawSnapshot()
        reconcileWindows()

        // Apps launched / quit
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            ws.addObserver(self, selector: #selector(refreshItems), name: name, object: nil)
        }
        // Displays plugged / unplugged / reconfigured
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
        // Changes to the main Dock: preferences notification + periodic check
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(checkPreferences),
                                                            name: NSNotification.Name("com.apple.dock.prefchanged"),
                                                            object: nil)
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.checkPreferences() }
        RunLoop.main.add(t, forMode: .common)
        prefsTimer = t
    }

    /// macOS posts several notifications while displays are reconfigured, sometimes with a
    /// transient list of screens: reconcile once things settle, then once more a bit later.
    @objc private func screensChanged() {
        screenWork.forEach { $0.cancel() }
        screenWork = [0.3, 1.5].map { delay in
            let work = DispatchWorkItem { [weak self] in self?.reconcileWindows() }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return work
        }
    }

    /// Re-reads the Dock preferences; only recomputes if something actually changed.
    @objc func checkPreferences() {
        if TrashState.refresh() { refreshItems() }   // empty <-> full Trash icon
        let raw = DockSettings.rawSnapshot()
        guard !raw.isEqual(lastRaw) else { return }
        lastRaw = raw
        reload()
    }

    /// Reloads settings and content, then updates every copy.
    private func reload() {
        settings = DockSettings.load()
        items = DockModel.items(settings: settings)
        layoutWindows()
        updateAutohideTimer()
    }

    @objc func refreshItems() {
        items = DockModel.items(settings: settings)
        layoutWindows()
    }

    /// Recreates every copy from scratch (menu: Refresh Dock).
    func rebuildWindows() {
        windows.values.forEach { $0.orderOut(nil); $0.close() }
        windows.removeAll()
        reconcileWindows()
    }

    /// One copy per target display: copies of displays that are still there are kept,
    /// new displays get one, displays that are gone (or now show the real Dock) lose theirs.
    func reconcileWindows() {
        let wanted = Set(targetScreens.map(ScreenGeometry.displayID))
        for (id, window) in windows where !wanted.contains(id) {
            window.orderOut(nil)
            window.close()
            windows[id] = nil
        }
        for id in wanted where windows[id] == nil {
            let window = DockWindow()
            window.onHover = { [weak self] target in self?.onHover?(target) }
            window.onIconClick = { [weak self] in self?.onIconClick?() }
            windows[id] = window
        }
        reload()
        windows.values.forEach { $0.orderFrontRegardless() }
    }

    private func layoutWindows() {
        for (id, window) in windows {
            guard let screen = ScreenGeometry.screen(withID: id) else { continue }
            window.update(items: items, settings: settings, on: screen)
        }
    }

    func diagnostics() -> [String] {
        windows.keys.sorted().compactMap { windows[$0]?.diagnostics }
    }

    private func updateAutohideTimer() {
        if settings.autohide {
            guard autohideTimer == nil else { return }
            let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                let mouse = NSEvent.mouseLocation
                self?.windows.values.forEach { $0.autohideTick(mouse: mouse) }
            }
            RunLoop.main.add(t, forMode: .common)
            autohideTimer = t
        } else {
            autohideTimer?.invalidate()
            autohideTimer = nil
        }
    }
}
