import AppKit

/// A permission the assistant explains, in the order shown: permissions that need DockEcho
/// to be quit and reopened come last.
enum AssistantPermission: CaseIterable {
    case accessibility
    case screenRecording

    /// macOS only applies Screen Recording to a process started after it was granted.
    var needsRelaunch: Bool { self == .screenRecording }

    var isGranted: Bool {
        switch self {
        case .accessibility: return Permissions.accessibility
        case .screenRecording: return Permissions.screenRecording
        }
    }

    /// Name of the list in System Settings › Privacy & Security.
    var sectionName: String {
        switch self {
        case .accessibility: return Permissions.accessibilityName
        case .screenRecording: return Permissions.screenRecordingName
        }
    }

    var title: String { "Allow \(sectionName)" }

    var symbols: [String] {
        switch self {
        case .accessibility: return ["accessibility", "hand.point.up.left.fill", "lock.shield"]
        case .screenRecording: return ["rectangle.dashed.badge.record", "macwindow", "lock.shield"]
        }
    }

    var color: NSColor { self == .accessibility ? .systemBlue : .systemPink }

    var explanation: String {
        switch self {
        case .accessibility:
            return "DockEcho uses it to list the windows of each app, bring the one you pick to the front "
                + "on the display you are using, close windows from the previews, and follow the real Dock "
                + "from one display to another."
        case .screenRecording:
            return "DockEcho uses it only to draw the window thumbnails in the previews. Nothing is recorded, "
                + "saved or sent anywhere. Without it, the previews show app icons and titles instead."
        }
    }

    var steps: [String] {
        switch self {
        case .accessibility:
            return [
                "Click Open System Settings. macOS adds DockEcho to the list (and may show its own alert: you can close it).",
                "In Privacy & Security › \(sectionName), turn DockEcho on. Your password may be asked.",
                "DockEcho is not in the list? Click + and choose DockEcho.app. It is on but not detected? "
                    + "Remove it with −, then add it again.",
            ]
        case .screenRecording:
            return [
                "Click Open System Settings. macOS adds DockEcho to the list.",
                "In Privacy & Security › \(sectionName), turn DockEcho on.",
                "macOS then offers to quit DockEcho: choose Later, and click Quit & Reopen below.",
            ]
        }
    }

    func requestAndOpenSettings() {
        switch self {
        case .accessibility:
            Permissions.requestAccessibility()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Permissions.openAccessibilitySettings() }
        case .screenRecording:
            Permissions.requestScreenRecording()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Permissions.openScreenRecordingSettings() }
        }
    }
}

/// First-launch window: a welcome page, then one page per missing permission.
final class PermissionsAssistant: NSObject, NSWindowDelegate {
    private static let hideKey = "hidePermissionsAssistant"
    private static let size = NSSize(width: 600, height: 570)

    static var missingPermissions: [AssistantPermission] {
        AssistantPermission.allCases.filter { !$0.isGranted }
    }

    /// Shown at launch while a permission is missing, unless the user opted out.
    static var shouldShowAtLaunch: Bool {
        !UserDefaults.standard.bool(forKey: hideKey) && !missingPermissions.isEmpty
    }

    private enum Page {
        case welcome
        case permission(AssistantPermission)
    }

    var onClose: (() -> Void)?

    private let permissions: [AssistantPermission]
    private let pages: [Page]
    private var index = 0
    private var timer: Timer?

    private let window: NSWindow

    // Welcome page
    private let welcomeView = FlippedView()
    private let logoView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "DockEcho")
    private let creditsLabel = NSTextField(labelWithString: "Imagined by Daniel Glazman, created by Anthropic Claude")
    private let versionLabel = NSTextField(labelWithString: "")

    // Permission pages
    private let permissionView = FlippedView()
    private let iconBox = NSView()
    private let iconView = NSImageView()
    private let counterLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let explanationLabel = NSTextField(wrappingLabelWithString: "")
    private let mock = SettingsMockView()
    private let stepsLabel = NSTextField(wrappingLabelWithString: "")
    private let statusIcon = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let openButton = NSButton(title: "Open System Settings", target: nil, action: nil)

    // Footer
    private let hideCheckbox = NSButton(checkboxWithTitle: "Don't show at launch", target: nil, action: nil)
    private let backButton = NSButton(title: "Back", target: nil, action: nil)
    private let nextButton = NSButton(title: "Next", target: nil, action: nil)

    /// Missing permissions only; all of them when opened from the menu with nothing missing.
    override init() {
        let missing = Self.missingPermissions
        permissions = missing.isEmpty ? AssistantPermission.allCases : missing
        pages = [.welcome] + permissions.map { .permission($0) }
        window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.level = .floating            // stays visible next to System Settings
        window.delegate = self
        buildContent()
        render()
    }

    func show() {
        if !window.isVisible { centerOnScreen() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if timer == nil {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refreshStatus() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    /// Exactly centered on the screen with the menu bar (NSWindow.center() sits higher).
    private func centerOnScreen() {
        guard let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: (visible.midX - size.width / 2).rounded(),
                                      y: (visible.midY - size.height / 2).rounded()))
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        onClose?()
    }

    // MARK: Layout (top-down coordinates)

    private func buildContent() {
        let width = Self.size.width
        let content = FlippedView(frame: NSRect(origin: .zero, size: Self.size))
        window.contentView = content

        let pageFrame = NSRect(x: 0, y: 0, width: width, height: 512)
        welcomeView.frame = pageFrame
        permissionView.frame = pageFrame
        content.addSubview(welcomeView)
        content.addSubview(permissionView)
        buildWelcome(width: width)
        buildPermission(width: width)

        let separator = NSBox(frame: NSRect(x: 0, y: 512, width: width, height: 1))
        separator.boxType = .separator
        content.addSubview(separator)

        hideCheckbox.frame = NSRect(x: 32, y: 530, width: 240, height: 20)
        hideCheckbox.state = UserDefaults.standard.bool(forKey: Self.hideKey) ? .on : .off
        hideCheckbox.target = self
        hideCheckbox.action = #selector(toggleHide)
        content.addSubview(hideCheckbox)

        backButton.frame = NSRect(x: width - 32 - 140 - 8 - 90, y: 524, width: 90, height: 30)
        backButton.bezelStyle = .rounded
        backButton.target = self
        backButton.action = #selector(back)
        content.addSubview(backButton)

        nextButton.frame = NSRect(x: width - 32 - 140, y: 524, width: 140, height: 30)
        nextButton.bezelStyle = .rounded
        nextButton.keyEquivalent = "\r"
        nextButton.target = self
        nextButton.action = #selector(next)
        content.addSubview(nextButton)
    }

    private func buildWelcome(width: CGFloat) {
        // The icon, magnified, with a soft shadow.
        let logoSize: CGFloat = 220
        logoView.frame = NSRect(x: (width - logoSize) / 2, y: 52, width: logoSize, height: logoSize)
        logoView.image = Logo.image(size: 512)
        logoView.imageScaling = .scaleProportionallyUpOrDown
        logoView.wantsLayer = true
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 24
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        logoView.shadow = shadow
        welcomeView.addSubview(logoView)

        func centered(_ label: NSTextField, y: CGFloat, height: CGFloat, font: NSFont, color: NSColor) {
            label.frame = NSRect(x: 32, y: y, width: width - 64, height: height)
            label.font = font
            label.textColor = color
            label.alignment = .center
            welcomeView.addSubview(label)
        }
        centered(nameLabel, y: 300, height: 48, font: .systemFont(ofSize: 40, weight: .bold), color: .labelColor)
        centered(creditsLabel, y: 358, height: 20, font: .systemFont(ofSize: 14), color: .secondaryLabelColor)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.2"
        versionLabel.stringValue = "Version \(version)"
        centered(versionLabel, y: 386, height: 18, font: .systemFont(ofSize: 12), color: .tertiaryLabelColor)
    }

    private func buildPermission(width: CGFloat) {
        let view = permissionView

        iconBox.frame = NSRect(x: 32, y: 26, width: 56, height: 56)
        iconBox.wantsLayer = true
        iconBox.layer?.cornerRadius = 13
        iconView.frame = iconBox.bounds.insetBy(dx: 10, dy: 10)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
        iconView.contentTintColor = .white
        iconBox.addSubview(iconView)
        view.addSubview(iconBox)

        counterLabel.frame = NSRect(x: 104, y: 30, width: 460, height: 16)
        counterLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        counterLabel.textColor = .secondaryLabelColor
        view.addSubview(counterLabel)

        titleLabel.frame = NSRect(x: 104, y: 48, width: 470, height: 30)
        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.lineBreakMode = .byTruncatingTail
        view.addSubview(titleLabel)

        explanationLabel.frame = NSRect(x: 32, y: 94, width: 536, height: 58)
        explanationLabel.font = .systemFont(ofSize: 13)
        explanationLabel.textColor = .secondaryLabelColor
        view.addSubview(explanationLabel)

        mock.frame = NSRect(x: 32, y: 158, width: 536, height: 196)
        view.addSubview(mock)

        stepsLabel.frame = NSRect(x: 32, y: 366, width: 536, height: 96)
        view.addSubview(stepsLabel)

        statusIcon.frame = NSRect(x: 32, y: 476, width: 18, height: 18)
        statusIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        view.addSubview(statusIcon)
        statusLabel.frame = NSRect(x: 56, y: 477, width: 310, height: 18)
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        view.addSubview(statusLabel)

        openButton.frame = NSRect(x: width - 32 - 200, y: 470, width: 200, height: 30)
        openButton.bezelStyle = .rounded
        openButton.target = self
        openButton.action = #selector(openSettings)
        view.addSubview(openButton)
    }

    // MARK: Pages

    private var currentPermission: AssistantPermission? {
        if case .permission(let p) = pages[index] { return p }
        return nil
    }

    private func render() {
        backButton.isHidden = index == 0
        guard let page = currentPermission else {
            window.title = "Welcome to DockEcho"
            welcomeView.isHidden = false
            permissionView.isHidden = true
            nextButton.title = "Next"
            return
        }
        window.title = "DockEcho Permissions"
        welcomeView.isHidden = true
        permissionView.isHidden = false

        iconBox.layer?.backgroundColor = page.color.cgColor
        iconView.image = page.symbols.lazy.compactMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: page.sectionName)
        }.first
        let number = (permissions.firstIndex(of: page) ?? 0) + 1
        counterLabel.stringValue = permissions.count > 1
            ? "PERMISSION \(number) OF \(permissions.count)" : "PERMISSION"
        titleLabel.stringValue = page.title
        explanationLabel.stringValue = page.explanation
        mock.sectionTitle = page.sectionName
        stepsLabel.attributedStringValue = numbered(page.steps)
        refreshStatus()
    }

    private func numbered(_ steps: [String]) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: 22, options: [:])]
        style.headIndent = 22
        style.paragraphSpacing = 6
        let text = steps.enumerated().map { "\($0.offset + 1).\t\($0.element)" }.joined(separator: "\n")
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ])
    }

    /// Live status of the current permission, and the label of the main button.
    private func refreshStatus() {
        guard let page = currentPermission else { return }
        let granted = page.isGranted
        if granted {
            setStatus("checkmark.circle.fill", .systemGreen, "Access granted")
        } else if page.needsRelaunch {
            setStatus("arrow.clockwise.circle.fill", .systemOrange, "Turn it on, then quit and reopen DockEcho")
        } else {
            setStatus("clock.fill", .systemOrange, "Waiting for access…")
        }
        mock.isGranted = granted

        if index < pages.count - 1 {
            nextButton.title = "Next"
        } else {
            nextButton.title = page.needsRelaunch && !granted ? "Quit & Reopen" : "Done"
        }
    }

    private func setStatus(_ symbol: String, _ color: NSColor, _ text: String) {
        statusIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        statusIcon.contentTintColor = color
        statusLabel.stringValue = text
    }

    // MARK: Actions

    @objc private func openSettings() { currentPermission?.requestAndOpenSettings() }

    @objc private func toggleHide() {
        UserDefaults.standard.set(hideCheckbox.state == .on, forKey: Self.hideKey)
    }

    @objc private func back() {
        guard index > 0 else { return }
        index -= 1
        render()
    }

    @objc private func next() {
        if index < pages.count - 1 {
            index += 1
            render()
            return
        }
        if let page = currentPermission, page.needsRelaunch, !page.isGranted {
            Relauncher.quitAndReopen()
        } else {
            window.close()
        }
    }
}

enum Relauncher {
    /// Quits DockEcho and opens it again once this process has exited.
    static func quitAndReopen() {
        let path = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A miniature System Settings window: Privacy & Security selected, the permission's list,
/// and DockEcho's switch turning on and off under the pointer.
final class SettingsMockView: NSView {
    var sectionTitle = "" { didSet { needsDisplay = true } }
    /// Once access is granted, the switch stays on.
    var isGranted = false { didSet { if isGranted != oldValue { needsDisplay = true } } }

    private var blinkOn = false
    private var timer: Timer?

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        let t = Timer(timeInterval: 1.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.blinkOn.toggle()
            if !self.isGranted { self.needsDisplay = true }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds.insetBy(dx: 1, dy: 1)
        let frame = NSBezierPath(roundedRect: b, xRadius: 10, yRadius: 10)
        NSColor.windowBackgroundColor.setFill()
        frame.fill()

        // Sidebar
        NSGraphicsContext.saveGraphicsState()
        frame.addClip()
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        NSRect(x: b.minX, y: b.minY, width: 150, height: b.height).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        frame.lineWidth = 1
        frame.stroke()

        for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: b.minX + 12 + CGFloat(i) * 16, y: b.minY + 10, width: 10, height: 10)).fill()
        }

        let items: [(String, NSColor)] = [
            ("Wi-Fi", .systemBlue), ("Bluetooth", .systemBlue), ("Network", .systemBlue),
            ("Notifications", .systemRed), ("Desktop & Dock", .systemGray), ("Displays", .systemBlue),
            ("Privacy & Security", .systemBlue),
        ]
        for (i, item) in items.enumerated() {
            let r = NSRect(x: b.minX + 8, y: b.minY + 32 + CGFloat(i) * 21, width: 134, height: 19)
            let selected = i == items.count - 1
            if selected {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
            }
            (selected ? NSColor.white : item.1).setFill()
            NSBezierPath(roundedRect: NSRect(x: r.minX + 6, y: r.midY - 6, width: 12, height: 12), xRadius: 3, yRadius: 3).fill()
            text(item.0, NSPoint(x: r.minX + 24, y: r.minY + 2), size: 11,
                 color: selected ? .white : .labelColor, width: r.width - 26)
        }

        // Pane
        let x0 = b.minX + 164
        let right = b.maxX - 14
        text("‹   " + sectionTitle, NSPoint(x: x0, y: b.minY + 28), size: 13, weight: .bold,
             color: .labelColor, width: right - x0)
        text("Allow the applications below:", NSPoint(x: x0, y: b.minY + 52), size: 11,
             color: .secondaryLabelColor, width: right - x0)

        let list = NSRect(x: x0, y: b.minY + 74, width: right - x0, height: 94)
        let listPath = NSBezierPath(roundedRect: list, xRadius: 7, yRadius: 7)
        NSColor.labelColor.withAlphaComponent(0.03).setFill()
        listPath.fill()
        NSColor.separatorColor.setStroke()
        listPath.stroke()

        // Another app (off)
        let row1 = NSRect(x: list.minX, y: list.minY, width: list.width, height: 34)
        NSColor.systemGray.withAlphaComponent(0.5).setFill()
        NSBezierPath(roundedRect: NSRect(x: row1.minX + 10, y: row1.midY - 10, width: 20, height: 20),
                     xRadius: 5, yRadius: 5).fill()
        text("Another App", NSPoint(x: row1.minX + 38, y: row1.midY - 8), size: 12, color: .secondaryLabelColor, width: 200)
        drawSwitch(center: NSPoint(x: row1.maxX - 26, y: row1.midY), on: false)

        // DockEcho, highlighted
        let row2 = NSRect(x: list.minX, y: list.minY + 34, width: list.width, height: 34)
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: row2.insetBy(dx: 3, dy: 2), xRadius: 5, yRadius: 5).fill()
        Logo.image(size: 40).draw(in: NSRect(x: row2.minX + 10, y: row2.midY - 10, width: 20, height: 20),
                                  from: .zero, operation: .sourceOver, fraction: 1,
                                  respectFlipped: true, hints: nil)
        text("DockEcho", NSPoint(x: row2.minX + 38, y: row2.midY - 8), size: 12, weight: .semibold,
             color: .labelColor, width: 200)
        let switchCenter = NSPoint(x: row2.maxX - 26, y: row2.midY)
        drawSwitch(center: switchCenter, on: isGranted || blinkOn)

        // + − buttons
        NSColor.separatorColor.setFill()
        NSRect(x: list.minX, y: list.maxY - 24, width: list.width, height: 1).fill()
        text("+    −", NSPoint(x: list.minX + 10, y: list.maxY - 21), size: 13, color: .secondaryLabelColor, width: 60)

        // Pointer on the switch
        if !isGranted {
            let cursor = NSCursor.arrow.image
            cursor.draw(in: NSRect(x: switchCenter.x - 2, y: switchCenter.y - 2,
                                   width: cursor.size.width, height: cursor.size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    private func drawSwitch(center: NSPoint, on: Bool) {
        let r = NSRect(x: center.x - 13, y: center.y - 8, width: 26, height: 16)
        (on ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.18)).setFill()
        NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: on ? r.maxX - 15 : r.minX + 1, y: r.minY + 1, width: 14, height: 14)).fill()
    }

    private func text(_ string: String, _ origin: NSPoint, size: CGFloat, weight: NSFont.Weight = .regular,
                      color: NSColor, width: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        (string as NSString).draw(with: NSRect(x: origin.x, y: origin.y, width: width, height: size + 6),
                                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                  attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                               .foregroundColor: color, .paragraphStyle: style])
    }
}
