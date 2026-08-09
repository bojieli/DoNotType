import CoreGraphics
import DoNotTypeCore
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import os

/// Captures the focused window when the accessibility tree comes back thin.
///
/// Focused window only, never the whole display: fewer tokens, less to leak, and no notification
/// from another Space landing in the context. Downscaled to a 1024 px long edge, which is enough
/// to read UI type and roughly 1,300 tokens.
enum ScreenCapturer {
    private static let log = Logger(subsystem: "ai.19pine.donottype", category: "capture")
    private static let longEdge = 1024.0

    static var hasPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestPermission() {
        _ = CGRequestScreenCaptureAccess()
    }

    /// PNG of the frontmost window belonging to `bundleID`, or nil if it cannot be found.
    static func captureFocusedWindow(ofBundleID bundleID: String?) async -> Data? {
        guard hasPermission else {
            log.info("screen recording permission not granted; skipping capture")
            return nil
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)

            // On-screen windows come back front-to-back, so the first match is the focused one.
            guard
                let window = content.windows.first(where: { window in
                    guard window.isOnScreen, window.frame.width > 200, window.frame.height > 120
                    else { return false }
                    guard let bundleID else { return true }
                    return window.owningApplication?.bundleIdentifier == bundleID
                })
            else {
                log.info("no on-screen window found for \(bundleID ?? "frontmost")")
                return nil
            }

            let scale = min(1.0, longEdge / max(window.frame.width, window.frame.height))
            let configuration = SCStreamConfiguration()
            configuration.width = Int(window.frame.width * scale)
            configuration.height = Int(window.frame.height * scale)
            configuration.showsCursor = false
            configuration.captureResolution = .best

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window),
                configuration: configuration)
            return png(from: image)
        } catch {
            log.error("window capture failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func png(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
