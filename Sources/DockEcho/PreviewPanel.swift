import AppKit

/// Floating panel holding the window thumbnails of one app.
final class PreviewPanel: NSPanel {
    let content = PreviewContentView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // Above the real Dock (dock level) and above the copies (dock level + 1).
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 2)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class PreviewContentView: NSVisualEffectView {
    private let header = NSTextField(labelWithString: "")
    private var tiles: [PreviewTileView] = []
    private var maxWidth: CGFloat = 800

    var onSelect: ((WindowInfo) -> Void)?
    var onClose: ((WindowInfo) -> Void)?

    var isEmpty: Bool { tiles.isEmpty }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor

        header.font = .systemFont(ofSize: 12, weight: .semibold)
        header.textColor = .secondaryLabelColor
        header.lineBreakMode = .byTruncatingTail
        addSubview(header)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Replaces the tiles; returns the size the panel needs.
    func show(appName: String, windows: [WindowInfo], placeholder: NSImage, maxWidth: CGFloat) -> NSSize {
        self.maxWidth = maxWidth
        header.stringValue = appName
        tiles.forEach { $0.removeFromSuperview() }
        tiles = windows.map { info in
            let tile = PreviewTileView(info: info, placeholder: placeholder)
            tile.onSelect = { [weak self] in self?.onSelect?(info) }
            tile.onClose = { [weak self] in self?.onClose?(info) }
            addSubview(tile)
            return tile
        }
        return layoutTiles()
    }

    /// Removes the tile of a closed window; returns the new size.
    func remove(_ info: WindowInfo) -> NSSize {
        for tile in tiles where tile.info.isSame(as: info) { tile.removeFromSuperview() }
        tiles.removeAll { $0.info.isSame(as: info) }
        return layoutTiles()
    }

    func setThumbnail(_ image: CGImage, for id: CGWindowID) {
        for tile in tiles where tile.info.windowID == id { tile.setThumbnail(image) }
    }

    /// Lays the tiles out in rows; tiles shrink before they wrap onto more rows.
    @discardableResult
    func layoutTiles() -> NSSize {
        let pad: CGFloat = 12, gap: CGFloat = 10, headerHeight: CGFloat = 20
        let count = max(tiles.count, 1)
        var tileWidth: CGFloat = 220
        var columns = count
        func width(_ c: Int) -> CGFloat { pad * 2 + CGFloat(c) * tileWidth + CGFloat(c - 1) * gap }
        while columns > 1 && width(columns) > maxWidth {
            if tileWidth > 150 { tileWidth -= 10 } else { columns -= 1 }
        }
        let rows = (count + columns - 1) / columns
        let tileHeight = PreviewTileView.height(forWidth: tileWidth)
        let size = NSSize(width: max(width(columns), 180),
                          height: pad * 2 + headerHeight + CGFloat(rows) * tileHeight + CGFloat(rows - 1) * gap)

        header.frame = NSRect(x: pad + 4, y: size.height - pad - headerHeight + 2,
                              width: size.width - pad * 2 - 8, height: 16)
        for (i, tile) in tiles.enumerated() {
            let row = i / columns, column = i % columns
            let y = size.height - pad - headerHeight - CGFloat(row + 1) * tileHeight - CGFloat(row) * gap
            tile.frame = NSRect(x: pad + CGFloat(column) * (tileWidth + gap), y: y,
                                width: tileWidth, height: tileHeight)
        }
        return size
    }
}

/// One window: thumbnail (or the app icon until it arrives), title, close button on hover.
final class PreviewTileView: NSView {
    static let titleHeight: CGFloat = 20

    static func height(forWidth width: CGFloat) -> CGFloat {
        ((width - 16) * 0.62).rounded() + titleHeight + 18
    }

    let info: WindowInfo
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let thumb = CALayer()
    private let title = NSTextField(labelWithString: "")
    private let closeButton = FirstMouseButton()
    private var hasThumbnail = false
    private var hovering = false { didSet { updateHover() } }

    init(info: WindowInfo, placeholder: NSImage) {
        self.info = info
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10

        thumb.contents = placeholder
        thumb.contentsGravity = .resizeAspect
        thumb.opacity = info.isMinimized ? 0.55 : 1
        layer?.addSublayer(thumb)

        let name = info.title.isEmpty ? "Untitled" : info.title
        title.stringValue = info.isMinimized ? "\(name) (minimized)" : name
        title.font = .systemFont(ofSize: 12)
        title.textColor = .labelColor
        title.alignment = .center
        title.lineBreakMode = .byTruncatingMiddle
        title.maximumNumberOfLines = 1
        addSubview(title)

        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close window")
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .white
        closeButton.toolTip = "Close Window"
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = true
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setThumbnail(_ image: CGImage) {
        thumb.contents = image
        hasThumbnail = true
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        thumb.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func layout() {
        super.layout()
        let area = NSRect(x: 8, y: Self.titleHeight + 10,
                          width: bounds.width - 16, height: bounds.height - Self.titleHeight - 18)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if hasThumbnail {
            thumb.frame = area
        } else {
            let s = min(64, area.height * 0.7)
            thumb.frame = NSRect(x: area.midX - s / 2, y: area.midY - s / 2, width: s, height: s)
        }
        CATransaction.commit()
        title.frame = NSRect(x: 6, y: 6, width: bounds.width - 12, height: 16)
        closeButton.frame = NSRect(x: 2, y: bounds.height - 24, width: 22, height: 22)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onSelect?() }
    }

    @objc private func closeClicked() { onClose?() }

    private func updateHover() {
        layer?.backgroundColor = hovering ? NSColor.white.withAlphaComponent(0.14).cgColor : nil
        closeButton.isHidden = !hovering
    }
}

/// A button that reacts to the first click even though its panel never becomes key.
final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
