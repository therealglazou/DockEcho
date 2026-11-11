import AppKit
import ApplicationServices

/// The two privacy permissions DockEcho can use.
/// - Accessibility ("Device Control and Data Access" since macOS 27): window lists, closing /
///   raising / moving windows, watching the real Dock.
/// - Screen Recording: window thumbnails.
///
/// What the system *reports* (AXIsProcessTrusted, CGPreflightScreenCaptureAccess) can disagree
/// with what actually works: on macOS 27, and when a rebuilt ad-hoc-signed app is still listed
/// under its previous signature. DockEcho therefore checks the effective access with a real call.
enum Permissions {
    private static var isMacOS27OrLater: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
    }

    /// Name of the privacy section in System Settings.
    static var accessibilityName: String {
        isMacOS27OrLater ? "Device Control and Data Access" : "Accessibility"
    }

    // MARK: Accessibility

    private static var cachedAccessibility: (value: Bool, date: Date)?

    /// Effective Accessibility access (cached for 2 seconds).
    static var accessibility: Bool {
        if let cached = cachedAccessibility, Date().timeIntervalSince(cached.date) < 2 { return cached.value }
        let value = probeAccessibility() ?? AXIsProcessTrusted()
        cachedAccessibility = (value, Date())
        return value
    }

    /// What AXIsProcessTrusted reports (for diagnostics).
    static var accessibilityReported: Bool { AXIsProcessTrusted() }

    /// Reads the Dock's accessibility tree: true or false when the answer is conclusive,
    /// nil otherwise (no Dock process, or an inconclusive error such as a timeout).
    static func probeAccessibility() -> Bool? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &value) {
        case .success: return true
        case .apiDisabled: return false          // the documented "not trusted" error
        default: return nil
        }
    }

    /// Shows the system prompt (only while access is not granted).
    static func requestAccessibility() {
        cachedAccessibility = nil
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    // MARK: Screen Recording

    /// Name of the privacy section in System Settings.
    static var screenRecordingName: String {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
            ? "Screen & System Audio Recording" : "Screen Recording"
    }

    /// Set once a window capture has actually succeeded.
    static var screenCaptureWorked = false

    private static var cachedScreenRecording: (value: Bool, date: Date)?

    /// Effective Screen Recording access (the window-name check is cached for 2 seconds).
    static var screenRecording: Bool {
        if CGPreflightScreenCaptureAccess() || screenCaptureWorked { return true }
        if let cached = cachedScreenRecording, Date().timeIntervalSince(cached.date) < 2 { return cached.value }
        let value = probeScreenRecording()
        cachedScreenRecording = (value, Date())
        return value
    }

    /// Without Screen Recording access, the window server hides the titles of other apps'
    /// windows: seeing one proves access, with no prompt. (No titled window: false.)
    static func probeScreenRecording() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        return list.contains { info in
            let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            let owner = info[kCGWindowOwnerName as String] as? String
            guard pid != me, owner != "Dock", owner != "Window Server",
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { return false }
            return !((info[kCGWindowName as String] as? String) ?? "").isEmpty
        }
    }

    /// What CGPreflightScreenCaptureAccess reports (for diagnostics).
    static var screenRecordingReported: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; returns whether access is granted.
    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    // MARK: System Settings

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }

    // MARK: Diagnostics

    static var diagnostics: [String] {
        let probe = probeAccessibility().map { "\($0)" } ?? "inconclusive"
        return [
            "\(accessibilityName): effective \(accessibility), AXIsProcessTrusted \(accessibilityReported), probe \(probe)",
            "Screen Recording: effective \(screenRecording), CGPreflightScreenCaptureAccess \(screenRecordingReported), "
                + "window titles visible \(probeScreenRecording()), capture succeeded \(screenCaptureWorked)"
        ]
    }
}
