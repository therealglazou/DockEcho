import AppKit
import ScreenCaptureKit

/// Window thumbnails. Needs the Screen Recording permission.
enum Thumbnailer {
    /// One attempt per launch is made even when CGPreflightScreenCaptureAccess says no,
    /// because it can be wrong (see Permissions).
    private static var triedWithoutPermission = false

    /// Captures each window and reports the images on the main thread.
    /// `maxPoints` bounds the larger side; images are made at up to 2x for sharpness.
    static func capture(_ ids: [CGWindowID], maxPoints: CGFloat,
                        onImage: @escaping (CGWindowID, CGImage) -> Void) {
        let ids = ids.filter { $0 != 0 }
        guard !ids.isEmpty else { return }

        if #available(macOS 14.0, *) {
            if !Permissions.screenRecording {
                guard !triedWithoutPermission else { return }
                triedWithoutPermission = true
            }
            Task {
                guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                else { return }
                for id in ids {
                    guard let window = content.windows.first(where: { $0.windowID == id }) else { continue }
                    let size = window.frame.size
                    let scale = min(2, 2 * maxPoints / max(size.width, size.height, 1))
                    let config = SCStreamConfiguration()
                    config.width = max(1, Int(size.width * scale))
                    config.height = max(1, Int(size.height * scale))
                    config.showsCursor = false
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                                  configuration: config)
                    else { continue }
                    await MainActor.run {
                        Permissions.screenCaptureWorked = true
                        onImage(id, image)
                    }
                }
            }
        } else {
            guard Permissions.screenRecording else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                for id in ids {
                    guard let image = legacyCapture(id) else { continue }
                    DispatchQueue.main.async { onImage(id, image) }
                }
            }
        }
    }

    // MARK: macOS 12.3 – 13

    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// CGWindowListCreateImage cannot be called from code built with the macOS 15 SDK, but it
    /// still exists at run time on macOS 12–13, where ScreenCaptureKit cannot take screenshots.
    private static let createImage: CreateImage? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: CreateImage.self)
    }()

    private static func legacyCapture(_ id: CGWindowID) -> CGImage? {
        let includingWindow: UInt32 = 1 << 3          // kCGWindowListOptionIncludingWindow
        let options: UInt32 = (1 << 0) | (1 << 4)     // boundsIgnoreFraming | nominalResolution
        return createImage?(.null, includingWindow, id, options)?.takeRetainedValue()
    }
}
