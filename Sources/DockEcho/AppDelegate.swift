import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: DockController!
    private let previews = PreviewController()
    private var assistant: PermissionsAssistant?
    private let realDock = RealDockWatcher()
    private var statusItem: NSStatusItem!

    // Main menu
    private let mainMenu = NSMenu()
    private let primaryItem = NSMenuItem(title: "Also Show on the Display with the Real Dock", action: nil, keyEquivalent: "")
    private let previewsItem = NSMenuItem(title: "Show Window Previews", action: nil, keyEquivalent: "")
    private let displayItem = NSMenuItem(title: "Open Apps on DockEcho's Display", action: nil, keyEquivalent: "")
    private let accessItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let accessibilityItem = NSMenuItem(title: "Accessibility…", action: nil, keyEquivalent: "")
    private let screenRecordingItem = NSMenuItem(title: "Screen Recording…", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = Logo.image(size: 512)

        controller = DockController()
        controller.realDockDisplay = { [weak self] in self?.realDock.dockDisplay }
        controller.onHover = { [weak self] hover in self?.previews.hover(hover) }
        controller.onIconClick = { [weak self] in self?.previews.hideNow() }

        realDock.onHover = { [weak self] hover in self?.previews.hover(hover) }
        realDock.onDockDisplayChange = { [weak self] in self?.controller.reconcileWindows() }

        realDock.start()      // first, so the copies know which display already shows the real Dock
        controller.start()
        // Missing permissions are explained in a window rather than with bare system prompts.
        if PermissionsAssistant.shouldShowAtLaunch { showPermissionsAssistant() }

        buildMenu()
    }

    // MARK: Menu

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "DockEcho")

        mainMenu.delegate = self
        add(mainMenu, "About DockEcho…", #selector(showAbout))
        mainMenu.addItem(.separator())
        add(mainMenu, "Dock Settings…", #selector(openDockSettings), key: ",")
        add(mainMenu, "Refresh Dock", #selector(refresh), key: "r")
        configure(primaryItem, #selector(togglePrimary))
        mainMenu.addItem(primaryItem)
        configure(displayItem, #selector(toggleDisplay))
        displayItem.toolTip = "When an app has no window on the display you click, move its window there "
            + "(requires the \(Permissions.accessibilityName) permission)."
        mainMenu.addItem(displayItem)
        // Shown only when a feature that needs Accessibility is on but the permission is missing
        // (or was invalidated, e.g. by an ad-hoc re-signature).
        configure(accessItem, #selector(showPermissionsAssistant))
        accessItem.indentationLevel = 1
        accessItem.isHidden = true
        mainMenu.addItem(accessItem)
        mainMenu.addItem(.separator())

        configure(previewsItem, #selector(togglePreviews))
        mainMenu.addItem(previewsItem)

        let permissions = NSMenu(title: "Permissions")
        add(permissions, "Permissions Assistant…", #selector(showPermissionsAssistant))
        permissions.addItem(.separator())
        configure(accessibilityItem, #selector(openAccessibility))
        permissions.addItem(accessibilityItem)
        configure(screenRecordingItem, #selector(openScreenRecording))
        permissions.addItem(screenRecordingItem)
        let permissionsRoot = NSMenuItem(title: "Permissions", action: nil, keyEquivalent: "")
        permissionsRoot.submenu = permissions
        mainMenu.addItem(permissionsRoot)

        mainMenu.addItem(.separator())
        add(mainMenu, "Copy Diagnostics", #selector(copyDiagnostics))
        add(mainMenu, "Quit DockEcho", #selector(quit), key: "q")
        statusItem.menu = mainMenu
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func configure(_ item: NSMenuItem, _ action: Selector) {
        item.action = action
        item.target = self
    }

    /// Refreshes checkmarks every time the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === mainMenu else { return }
        primaryItem.state = controller.includePrimaryScreen ? .on : .off
        previewsItem.state = previews.isEnabled ? .on : .off
        displayItem.state = WindowMover.isEnabled ? .on : .off
        accessItem.title = "⚠️ Grant \(Permissions.accessibilityName) Access…"
        accessItem.isHidden = !((WindowMover.isEnabled || previews.isEnabled) && !Permissions.accessibility)
        accessibilityItem.title = "\(Permissions.accessibilityName)…"
        accessibilityItem.state = Permissions.accessibility ? .on : .off
        screenRecordingItem.state = Permissions.screenRecording ? .on : .off
    }

    // MARK: Actions

    @objc private func togglePrimary() { controller.includePrimaryScreen.toggle() }
    @objc private func togglePreviews() { previews.isEnabled.toggle() }
    @objc private func toggleDisplay() { WindowMover.isEnabled.toggle() }

    @objc private func showPermissionsAssistant() {
        if let assistant {
            assistant.show()
            return
        }
        let newAssistant = PermissionsAssistant()
        newAssistant.onClose = { [weak self] in self?.assistant = nil }
        assistant = newAssistant
        newAssistant.show()
    }

    @objc private func openAccessibility() {
        if !Permissions.accessibility { Permissions.requestAccessibility() }
        Permissions.openAccessibilitySettings()
    }

    @objc private func openScreenRecording() {
        // The system prompt only appears once; after that, the settings pane is the way.
        if !Permissions.requestScreenRecording() { Permissions.openScreenRecordingSettings() }
    }

    /// Copies a description of the displays and copies, to help diagnose display problems.
    @objc private func copyDiagnostics() {
        var lines = ["DockEcho \(appVersion) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"]
        for (i, s) in NSScreen.screens.enumerated() {
            lines.append("Display \(i): id \(ScreenGeometry.displayID(s)), \"\(s.localizedName)\", "
                         + "frame \(s.frame), scale \(s.backingScaleFactor)")
        }
        lines.append("Real Dock display: \(realDock.dockDisplay.map { "\($0)" } ?? "unknown")")
        lines.append("Also show on the real Dock's display: \(controller.includePrimaryScreen)")
        lines += controller.diagnostics()
        lines += Permissions.diagnostics
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.2"
    }

    @objc private func showAbout() {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let credits = NSAttributedString(
            string: "Imagined by Daniel Glazman, created by Anthropic Claude",
            attributes: [.font: NSFont.systemFont(ofSize: 12),
                         .foregroundColor: NSColor.secondaryLabelColor,
                         .paragraphStyle: style])

        // The app is an accessory (no Dock icon): bring it forward so the panel is visible.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "DockEcho",
            .applicationIcon: Logo.image(size: 256),
            .applicationVersion: appVersion,
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "Free and open source"
        ])
    }

    /// Opens System Settings > Desktop & Dock (System Preferences pane on macOS 12).
    @objc private func openDockSettings() {
        if #available(macOS 13.0, *),
           let url = URL(string: "x-apple.systempreferences:com.apple.Dock-Settings.extension"),
           NSWorkspace.shared.open(url) {
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/Dock.prefPane"))
    }

    @objc private func refresh() { controller.rebuildWindows() }
    @objc private func quit() { NSApp.terminate(nil) }
}
