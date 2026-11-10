import AppKit
import QuartzCore

/// All dimensions derived from the Dock settings.
struct DockMetrics {
    let settings: DockSettings

    var orientation: DockOrientation { settings.orientation }
    var base: CGFloat { settings.tileSize }
    var maxScale: CGFloat { settings.maxScale }
    var spacing: CGFloat { max(2, base * 0.12) }
    var hPad: CGFloat { base * 0.27 }
    var shelfThickness: CGFloat { base * 1.42 }
    var iconEdge: CGFloat { base * 0.27 }
    var dotEdge: CGFloat { base * 0.08 }
    var overhang: CGFloat { base * (maxScale - 1) }
    var bounceRoom: CGFloat { base * 0.5 }
    var labelRoom: CGFloat { orientation == .bottom ? 40 : 230 }
    var headroom: CGFloat { base * (maxScale > 1 ? 2 : 0.5) }
    var thickness: CGFloat { shelfThickness + overhang + bounceRoom + labelRoom }
    var cornerRadius: CGFloat { min(24, max(8, base * 0.35)) }

    func width(of item: DockItem) -> CGFloat {
        switch item.kind {
        case .separator: return max(8, base * 0.2)
        case .spacer: return base * 0.5
        default: return base
        }
    }

    func baseLayout(_ items: [DockItem]) -> (centers: [CGFloat], total: CGFloat) {
        var x = hPad
        var centers: [CGFloat] = []
        for item in items {
            let w = width(of: item)
            centers.append(x + w / 2)
            x += w + spacing
        }
        return (centers, items.isEmpty ? hPad * 2 : x - spacing + hPad)
    }

    func windowLength(_ items: [DockItem]) -> CGFloat {
        baseLayout(items).total + headroom * 2
    }

    /// Shrinks the icons when the Dock does not fit on the screen (like the real Dock).
    static func fitted(_ settings: DockSettings, items: [DockItem], available: CGFloat) -> DockSettings {
        var s = settings
        while s.tileSize > 24 {
            if DockMetrics(settings: s).baseLayout(items).total + 40 <= available { break }
            s.tileSize -= 2
        }
        return s
    }
}

/// Transparent view that shows the icons. Every icon is a Core Animation layer: moving
/// or scaling it only updates its frame (composited on the GPU), so the magnification
/// stays smooth. Works for the three orientations (bottom, left, right).
final class IconsView: NSView {
    private(set) var metrics = DockMetrics(settings: DockSettings())
    private(set) var items: [DockItem] = []

    // Layers
    private var tileLayers: [CALayer?] = []     // icon (or separator line) per item
    private var dotLayers: [CALayer?] = []      // "running" indicator per item
    private let tipBox = CALayer()
    private let tipText = CATextLayer()
    private var tipIndex: Int?
    private var tipSize = CGSize.zero

    // State
    private var scales: [CGFloat] = []
    private var rects: [NSRect] = []
    private var hovering = false
    private var hoverAmount: CGFloat = 0        // 0...1, eased on enter/exit
    private var lastMain: CGFloat = 0           // cursor position along the dock axis
    private var anchor: Int?
    private var pressed: Int?
    private var bounceStart: [String: Date] = [:]
    private var bounceObserver: NSObjectProtocol?
    private let driver = FrameDriver()

    /// Reports for the window previews: the icon under the pointer (nil when none) and presses.
    var onHoverItem: ((DockItem?, NSRect) -> Void)?
    var onPress: (() -> Void)?
    private var reportedIndex: Int?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        tipBox.backgroundColor = NSColor(white: 0.12, alpha: 0.85).cgColor
        tipBox.cornerRadius = 8
        tipBox.zPosition = 100
        tipBox.opacity = 0
        tipText.font = NSFont.systemFont(ofSize: 13)
        tipText.fontSize = 13
        tipText.foregroundColor = NSColor.white.cgColor
        tipText.alignmentMode = .center
        tipBox.addSublayer(tipText)
        layer?.addSublayer(tipBox)

        driver.view = self
        driver.onFrame = { [weak self] dt in self?.step(dt: dt) ?? false }

        bounceObserver = NotificationCenter.default.addObserver(forName: .dockBounce, object: nil, queue: .main) { [weak self] note in
            guard let self, let id = note.object as? String,
                  self.metrics.settings.launchAnimation,
                  self.items.contains(where: { $0.id == id }) else { return }
            self.bounceStart[id] = Date()
            self.driver.start()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let o = bounceObserver { NotificationCenter.default.removeObserver(o) }
        driver.stop()
    }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Configuration

    func configure(items newItems: [DockItem], settings: DockSettings) {
        metrics = DockMetrics(settings: settings)
        items = newItems
        scales = Array(repeating: 1, count: newItems.count)
        anchor = nil
        tipIndex = nil
        reportedIndex = nil
        bounceStart = bounceStart.filter { id, _ in newItems.contains { $0.id == id && !$0.isRunning } }
        rebuildLayers()
        relayout()
        if hovering || !bounceStart.isEmpty { driver.start() }
    }

    func resetHover() {
        reportHover(at: nil)
        hovering = false
        hoverAmount = 0
        anchor = nil
        driver.stop()
        relayout()
    }

    private func rebuildLayers() {
        tileLayers.forEach { $0?.removeFromSuperlayer() }
        dotLayers.forEach { $0?.removeFromSuperlayer() }
        tileLayers = []
        dotLayers = []

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let maxPoints = metrics.base * metrics.maxScale

        for item in items {
            switch item.kind {
            case .separator:
                let line = CALayer()
                line.backgroundColor = NSColor.white.withAlphaComponent(0.35).cgColor
                layer?.insertSublayer(line, below: tipBox)
                tileLayers.append(line)
                dotLayers.append(nil)
            case .spacer:
                tileLayers.append(nil)
                dotLayers.append(nil)
            case .app, .folder, .trash:
                let icon = CALayer()
                icon.contents = IconCache.raster(for: item, points: maxPoints, scale: scale)
                icon.contentsGravity = .resize
                icon.minificationFilter = .trilinear
                icon.magnificationFilter = .linear
                icon.contentsScale = scale
                layer?.insertSublayer(icon, below: tipBox)
                tileLayers.append(icon)

                let dot = CALayer()
                dot.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
                dot.isHidden = !(item.isRunning && metrics.settings.showIndicators)
                layer?.insertSublayer(dot, below: tipBox)
                dotLayers.append(dot)
            }
        }
        tipText.contentsScale = scale
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard !items.isEmpty else { return }
        rebuildLayers()
        relayout()
    }

    override func layout() {
        super.layout()
        relayout()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    // MARK: Geometry (main axis = direction of the dock)

    private var vertical: Bool { metrics.orientation != .bottom }
    private var mainLength: CGFloat { vertical ? bounds.height : bounds.width }

    private func mainCoord(_ p: NSPoint) -> CGFloat { vertical ? bounds.height - p.y : p.x }
    private func mainCenter(of r: NSRect) -> CGFloat { vertical ? bounds.height - r.midY : r.midX }

    /// `cross` is the distance from the screen edge the Dock is attached to.
    private func makeRect(mainCenter: CGFloat, mainSize: CGFloat, cross: CGFloat, crossSize: CGFloat) -> NSRect {
        switch metrics.orientation {
        case .bottom:
            return NSRect(x: mainCenter - mainSize / 2, y: cross, width: mainSize, height: crossSize)
        case .left:
            return NSRect(x: cross, y: bounds.height - mainCenter - mainSize / 2, width: crossSize, height: mainSize)
        case .right:
            return NSRect(x: bounds.width - cross - crossSize, y: bounds.height - mainCenter - mainSize / 2,
                          width: crossSize, height: mainSize)
        }
    }

    /// Gaussian magnification around the cursor, eased in and out with `hoverAmount`.
    private func computeScales() {
        let m = metrics
        let (centers, total) = m.baseLayout(items)
        let originMain = (mainLength - total) / 2
        let sigma = m.base * 1.1
        var best: (idx: Int, dist: CGFloat)?
        for (i, item) in items.enumerated() {
            guard item.isTile else { scales[i] = 1; continue }
            let d = abs(lastMain - (originMain + centers[i]))
            let g = 1 + (m.maxScale - 1) * exp(-(d * d) / (2 * sigma * sigma))
            scales[i] = 1 + (g - 1) * hoverAmount
            if best == nil || d < best!.dist { best = (i, d) }
        }
        anchor = best?.idx
    }

    private func currentRects() -> [NSRect] {
        let m = metrics
        let (centers, total) = m.baseLayout(items)
        let originMain = (mainLength - total) / 2

        // Scaled sizes and start positions (unshifted: first item starts at 0)
        var sizes: [CGFloat] = []
        var starts: [CGFloat] = []
        var x: CGFloat = 0
        for (i, item) in items.enumerated() {
            let size = m.width(of: item) * (item.isTile ? scales[i] : 1)
            sizes.append(size)
            starts.append(x)
            x += size + m.spacing
        }

        // Continuous anchoring: the point of the dock under the cursor stays under the cursor,
        // so icons never jump when the cursor crosses from one icon to the next.
        let u = min(max(lastMain, originMain), originMain + total)
        var k = items.count - 1
        for i in items.indices {
            if u < originMain + centers[i] + m.width(of: items[i]) / 2 + m.spacing / 2 { k = i; break }
        }
        let w = m.width(of: items[k])
        let cellStart = originMain + centers[k] - w / 2 - m.spacing / 2
        let f = min(max((u - cellStart) / (w + m.spacing), 0), 1)
        let mapped = (starts[k] - m.spacing / 2) + f * (sizes[k] + m.spacing)
        let shift = u - mapped

        let now = Date()
        return items.enumerated().map { i, item in
            let c = starts[i] + sizes[i] / 2 + shift
            switch item.kind {
            case .separator:
                return makeRect(mainCenter: c, mainSize: sizes[i], cross: m.iconEdge + m.base * 0.1, crossSize: m.base * 0.8)
            case .spacer:
                return makeRect(mainCenter: c, mainSize: sizes[i], cross: m.iconEdge, crossSize: 1)
            default:
                var cross = m.iconEdge
                if let t = bounceStart[item.id] {
                    let dt = now.timeIntervalSince(t)
                    cross += CGFloat(abs(sin(dt * .pi / 0.8))) * m.base * 0.45
                }
                return makeRect(mainCenter: c, mainSize: sizes[i], cross: cross, crossSize: sizes[i])
            }
        }
    }

    /// Recomputes the geometry and moves the layers (no implicit animations).
    private func relayout() {
        guard !items.isEmpty, scales.count == items.count, tileLayers.count == items.count else { return }
        computeScales()
        rects = currentRects()
        let m = metrics

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, item) in items.enumerated() {
            let r = rects[i]
            switch item.kind {
            case .separator:
                tileLayers[i]?.frame = makeRect(mainCenter: mainCenter(of: r), mainSize: 1,
                                                cross: m.iconEdge + m.base * 0.1, crossSize: m.base * 0.8)
            case .spacer:
                break
            default:
                tileLayers[i]?.frame = r
                if let dot = dotLayers[i] {
                    let d = max(3, m.base * 0.085)
                    dot.cornerRadius = d / 2
                    dot.frame = makeRect(mainCenter: mainCenter(of: r), mainSize: d, cross: m.dotEdge, crossSize: d)
                }
            }
        }
        updateTip()
        CATransaction.commit()
    }

    private func updateTip() {
        guard hoverAmount > 0.01, let k = anchor, k < items.count,
              items[k].isTile, !items[k].name.isEmpty else {
            tipBox.opacity = 0
            return
        }
        if tipIndex != k {
            tipIndex = k
            let size = NSAttributedString(string: items[k].name,
                                          attributes: [.font: NSFont.systemFont(ofSize: 13)]).size()
            tipSize = CGSize(width: ceil(size.width) + 20, height: ceil(size.height) + 8)
            tipText.string = items[k].name
            tipText.frame = CGRect(x: 0, y: 4, width: tipSize.width, height: ceil(size.height))
        }
        let r = rects[k]
        var origin: CGPoint
        switch metrics.orientation {
        case .bottom:
            origin = CGPoint(x: min(max(r.midX - tipSize.width / 2, 4), bounds.width - tipSize.width - 4),
                             y: r.maxY + 8)
        case .left:
            origin = CGPoint(x: r.maxX + 10, y: r.midY - tipSize.height / 2)
        case .right:
            origin = CGPoint(x: r.minX - 10 - tipSize.width, y: r.midY - tipSize.height / 2)
        }
        tipBox.frame = CGRect(origin: origin, size: tipSize)
        tipBox.opacity = Float(hoverAmount)
    }

    private func index(at p: NSPoint) -> Int? {
        let half = metrics.spacing / 2
        for (i, r) in rects.enumerated() where i < items.count && items[i].isTile {
            let hit: NSRect
            switch metrics.orientation {
            case .bottom: hit = NSRect(x: r.minX - half, y: 0, width: r.width + 2 * half, height: r.maxY)
            case .left:   hit = NSRect(x: 0, y: r.minY - half, width: r.maxX, height: r.height + 2 * half)
            case .right:  hit = NSRect(x: r.minX, y: r.minY - half, width: bounds.width - r.minX, height: r.height + 2 * half)
            }
            if hit.contains(p) { return i }
        }
        return nil
    }

    // MARK: Animation

    /// One animation frame (time-based, so speed does not depend on the refresh rate).
    private func step(dt: CGFloat) -> Bool {
        let goal: CGFloat = hovering ? 1 : 0
        hoverAmount += (goal - hoverAmount) * (1 - exp(-dt * (hovering ? 24 : 14)))
        if abs(goal - hoverAmount) < 0.002 { hoverAmount = goal }

        let now = Date()
        bounceStart = bounceStart.filter { now.timeIntervalSince($0.value) < 12 }

        relayout()

        let done = hoverAmount == goal && bounceStart.isEmpty
        if done && !hovering { anchor = nil }
        return !done
    }

    // MARK: Mouse

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseMoved(with event: NSEvent) {
        lastMain = mainCoord(convert(event.locationInWindow, from: nil))
        hovering = true
        relayout()                       // magnification follows the cursor with no lag
        if hoverAmount < 1 { driver.start() }
        reportHover(at: convert(event.locationInWindow, from: nil))
    }

    /// Tells the previews which icon is under the pointer, only when it changes.
    private func reportHover(at point: NSPoint?) {
        let i = point.flatMap { index(at: $0) }
        guard i != reportedIndex else { return }
        reportedIndex = i
        if let i, i < rects.count { onHoverItem?(items[i], rects[i]) } else { onHoverItem?(nil, .zero) }
    }

    override func mouseExited(with event: NSEvent) {
        reportHover(at: nil)
        hovering = false
        driver.start()
    }

    override func mouseDown(with event: NSEvent) {
        onPress?()
        pressed = index(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let i = index(at: convert(event.locationInWindow, from: nil))
        defer { pressed = nil }
        guard let i, i == pressed else { return }
        DockActions.activate(items[i])
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onPress?()
        guard let i = index(at: convert(event.locationInWindow, from: nil)) else { return nil }
        let item = items[i]
        let menu = NSMenu()
        let title = NSMenuItem(title: item.name, action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        func add(_ t: String, _ sel: Selector) {
            let m = NSMenuItem(title: t, action: sel, keyEquivalent: "")
            m.target = self
            m.representedObject = item
            menu.addItem(m)
        }
        add(item.isRunning ? "Show" : "Open", #selector(menuOpen(_:)))
        if item.kind == .app || item.kind == .folder {
            add("Show in Finder", #selector(menuReveal(_:)))
        }
        if item.kind == .app && item.isRunning && item.id != "com.apple.finder" {
            add("Hide", #selector(menuHide(_:)))
            add("Quit", #selector(menuQuit(_:)))
        }
        return menu
    }

    @objc private func menuOpen(_ s: NSMenuItem) { (s.representedObject as? DockItem).map(DockActions.activate) }
    @objc private func menuReveal(_ s: NSMenuItem) {
        guard let item = s.representedObject as? DockItem else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }
    @objc private func menuHide(_ s: NSMenuItem) {
        guard let item = s.representedObject as? DockItem else { return }
        DockActions.runningApp(for: item)?.hide()
    }
    @objc private func menuQuit(_ s: NSMenuItem) {
        guard let item = s.representedObject as? DockItem else { return }
        DockActions.runningApp(for: item)?.terminate()
    }
}

/// Window content: blurred shelf with the icons on top.
final class DockRootView: NSView {
    private let shelf = NSVisualEffectView()
    let icons = IconsView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        shelf.material = .hudWindow
        shelf.blendingMode = .behindWindow
        shelf.state = .active
        shelf.wantsLayer = true
        shelf.layer?.masksToBounds = true
        shelf.layer?.borderWidth = 0.5
        shelf.layer?.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
        addSubview(shelf)
        addSubview(icons)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(items: [DockItem], settings: DockSettings) {
        icons.configure(items: items, settings: settings)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        icons.frame = bounds
        let m = icons.metrics
        let total = m.baseLayout(icons.items).total
        let t = m.shelfThickness
        switch m.orientation {
        case .bottom: shelf.frame = NSRect(x: (bounds.width - total) / 2, y: 0, width: total, height: t)
        case .left:   shelf.frame = NSRect(x: 0, y: (bounds.height - total) / 2, width: t, height: total)
        case .right:  shelf.frame = NSRect(x: bounds.width - t, y: (bounds.height - total) / 2, width: t, height: total)
        }
        shelf.layer?.cornerRadius = m.cornerRadius
    }
}
