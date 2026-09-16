//
//  MenuBarStripCapture.swift
//  Skein
//

import Cocoa
import CoreGraphics
import ScreenCaptureKit

/// Captures the menu bar strip and crops individual item images on macOS 27 and later.
@MainActor
enum MenuBarStripCapture {
    /// Captures the menu bar strip for the given screen.
    ///
    /// - Parameter screen: The screen whose menu bar strip to capture.
    /// - Returns: A tuple containing the captured image, its origin X coordinate in global CoreGraphics
    ///   coordinates, and the backing scale factor, or `nil` if capture failed or permissions are denied.
    static func capture(screen: NSScreen) async -> (image: CGImage, originX: CGFloat, scale: CGFloat)? {
        guard CGPreflightScreenCaptureAccess() else {
            return nil
        }

        let mainHeight = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height ?? screen.frame.height
        let rect = CGRect(
            x: screen.frame.minX,
            y: mainHeight - screen.frame.maxY,
            width: screen.frame.width,
            height: screen.getMenuBarHeight() ?? 24
        )

        guard
            rect.width > 0,
            rect.height > 0
        else {
            return nil
        }

        guard #available(macOS 15.2, *) else {
            return nil
        }

        do {
            let image = try await SCScreenshotManager.captureImage(in: rect)
            let scale = CGFloat(image.width) / rect.width
            return (image: image, originX: rect.minX, scale: scale)
        } catch {
            Logger.stripCapture.error("strip capture error \((error as NSError).code)")
            return nil
        }
    }

    /// Crops an individual item image from a captured menu bar strip.
    ///
    /// - Parameters:
    ///   - capture: The strip capture tuple containing the strip image, origin X, and scale factor.
    ///   - itemFrame: The item frame in global CoreGraphics coordinates.
    /// - Returns: The cropped item image, or `nil` if cropping failed.
    static func crop(_ capture: (image: CGImage, originX: CGFloat, scale: CGFloat), itemFrame: CGRect) -> CGImage? {
        let cropRect = CGRect(
            x: (itemFrame.minX - capture.originX) * capture.scale,
            y: 0,
            width: itemFrame.width * capture.scale,
            height: CGFloat(capture.image.height)
        )
        return capture.image.cropping(to: cropRect)
    }
}

// MARK: - Logger

private extension Logger {
    static let stripCapture = Logger(category: "StripCapture")
}
