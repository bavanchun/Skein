//
//  VerifyMenuBar27.swift
//  Skein
//

// Inspect macOS 27's menu bar through Accessibility and ScreenCaptureKit.
// xcrun swiftc -parse-as-library Scripts/VerifyMenuBar27.swift -o .ci-output/verify-menubar27
// .ci-output/verify-menubar27 ax-dump [--show-bundles] [--expect-contains <text>]
// .ci-output/verify-menubar27 strip-capture <output.png> [--expect-contains <text>]
// .ci-output/verify-menubar27 cliff-probe <length> [--expect-contains <text>]
// Requires Accessibility (and Screen Recording for strip-capture) for the terminal.
// There is deliberately no layout table subcommand: an unbundled process is
// denied Apple's group container on macOS 27, so table checks run in Skein Dev.

import ApplicationServices
import Cocoa
import ScreenCaptureKit
import UniformTypeIdentifiers

@main
struct VerifyMenuBar27 {
    nonisolated(unsafe) static var output: [String] = []

    static func emit(_ line: String) {
        output.append(line)
        print(line)
    }

    static func main() async {
        do {
            try await verify()
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func fail(_ message: String) -> NSError {
        NSError(domain: "VerifyMenuBar27", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func verify() async throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        var expected: String?
        if let index = arguments.firstIndex(of: "--expect-contains") {
            guard index + 1 < arguments.count else {
                throw fail("--expect-contains needs a value")
            }
            expected = arguments[index + 1]
            arguments.removeSubrange(index...(index + 1))
        }
        var rect: CGRect?
        if let index = arguments.firstIndex(of: "--rect") {
            guard index + 1 < arguments.count else {
                throw fail("--rect needs a value x,y,w,h")
            }
            let parts = arguments[index + 1].split(separator: ",").compactMap {
                Double($0.trimmingCharacters(in: .whitespaces))
            }
            guard parts.count == 4 else {
                throw fail("--rect format must be x,y,w,h")
            }
            rect = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
            arguments.removeSubrange(index...(index + 1))
        }
        let showBundles = arguments.contains("--show-bundles")
        arguments.removeAll { $0 == "--show-bundles" }

        switch arguments.first {
        case "ax-dump":
            axDump(showBundles: showBundles)
        case "strip-capture":
            guard arguments.count == 2 else {
                throw fail("strip-capture needs an output path")
            }
            try await stripCapture(to: URL(fileURLWithPath: arguments[1]), rect: rect)
        case "cliff-probe":
            guard arguments.count == 2, let length = Double(arguments[1]) else {
                throw fail("cliff-probe needs a numeric length")
            }
            await cliffProbe(length: CGFloat(length))
        default:
            throw fail("Usage: verify-menubar27 ax-dump|strip-capture <png> [--rect x,y,w,h]|cliff-probe <length> [--expect-contains <text>]")
        }

        if let expected, !output.contains(where: { $0.contains(expected) }) {
            throw fail("output does not contain \"\(expected)\"")
        }
    }

    // MARK: ax-dump

    static func axDump(showBundles: Bool) {
        var count = 0
        for app in NSWorkspace.shared.runningApplications {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            if app.bundleIdentifier == "com.apple.MenuBarAgent" {
                let identified = countIdentifiedItems(in: element, depth: 4)
                emit("{\"pid\":\(app.processIdentifier),\"menuBarAgentIdentifiedItems\":\(identified)}")
            }
            guard let bar = attribute(kAXExtrasMenuBarAttribute, of: element) else {
                continue
            }
            // swiftlint:disable:next force_cast
            for item in children(of: (bar as! AXUIElement)) {
                guard let frame = frame(of: item) else {
                    continue
                }
                let hasIdentifier = attribute(kAXIdentifierAttribute, of: item) is String
                var fields = ["\"pid\":\(app.processIdentifier)", "\"x\":\(Int(frame.minX))", "\"width\":\(Int(frame.width))", "\"hasIdentifier\":\(hasIdentifier)"]
                if showBundles {
                    fields.append("\"bundle\":\"\(app.bundleIdentifier ?? "")\"")
                }
                emit("{\(fields.joined(separator: ","))}")
                count += 1
            }
        }
        emit("ax-dump items=\(count)")
    }

    // MARK: strip-capture

    static func stripCapture(to url: URL, rect: CGRect? = nil) async throws {
        let captureRect: CGRect
        if let rect {
            captureRect = rect
        } else {
            let bounds = CGDisplayBounds(CGMainDisplayID())
            captureRect = CGRect(x: bounds.minX, y: 0, width: bounds.width, height: 40)
        }
        let image = try await SCScreenshotManager.captureImage(in: captureRect)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw fail("cannot create \(url.path)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw fail("cannot write \(url.path)")
        }
        emit("strip-capture: \(image.width)x\(image.height)")
    }

    // MARK: cliff-probe

    /// MenuBarAgent composites each honored item into a slot this much wider than its length.
    static let slotPadding: CGFloat = 16

    /// Returns a unique key for an agent window based on its frame coordinates.
    static func windowKey(for window: AXUIElement) -> String {
        guard let f = frame(of: window) else {
            return ""
        }
        return "\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width))"
    }

    /// Probes whether each display's MenuBarAgent window honors an item of the given length.
    ///
    /// Honored on a display means that display's window gained a slot of width
    /// `length + 16`. The chevron and the parked item window are reported separately.
    @MainActor
    static func cliffProbe(length: CGFloat) async {
        // Without finishing launch, a script has no Accessibility server of its own.
        NSApplication.shared.finishLaunching()
        let slotWidth = length + slotPadding
        var before = [String: Int]()
        for window in agentWindows() {
            let key = windowKey(for: window)
            if !key.isEmpty {
                before[key] = matchingSlots(in: window, width: slotWidth)
            }
        }
        let item = NSStatusBar.system.statusItem(withLength: length)
        item.button?.title = "ZZ"
        try? await Task.sleep(for: .seconds(2))
        let pid = ProcessInfo.processInfo.processIdentifier
        let axWidth = children(of: extrasBar(pid: pid)).compactMap { frame(of: $0)?.width }.max() ?? 0
        let parked = (item.button?.window?.frame.minY ?? 0) < 0
        for window in agentWindows() {
            let key = windowKey(for: window)
            guard !key.isEmpty else {
                continue
            }
            let displayWidth = Int(frame(of: window)?.width ?? 0)
            let beforeCount = before[key] ?? 0
            let honored = matchingSlots(in: window, width: slotWidth) > beforeCount
            let chevrons = children(of: window).filter {
                (attribute(kAXDescriptionAttribute, of: $0) as? String) == "Show Hidden Menu Bar Items"
            }.count
            emit("cliff-probe length=\(Int(length)) display=\(displayWidth) honored=\(honored) chevron=\(chevrons) parked=\(parked) axWidth=\(Int(axWidth))")
        }
        NSStatusBar.system.removeStatusItem(item)
    }

    /// MenuBarAgent's per-display windows, in Accessibility order.
    static func agentWindows() -> [AXUIElement] {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent")
            .flatMap { children(of: AXUIElementCreateApplication($0.processIdentifier)) }
            .filter { (attribute(kAXRoleAttribute, of: $0) as? String) == kAXWindowRole }
    }

    static func matchingSlots(in window: AXUIElement, width: CGFloat) -> Int {
        children(of: window).filter { abs((frame(of: $0)?.width ?? 0) - width) < 1 }.count
    }

    // MARK: Accessibility

    static func extrasBar(pid: pid_t) -> AXUIElement? {
        // swiftlint:disable:next force_cast
        attribute(kAXExtrasMenuBarAttribute, of: AXUIElementCreateApplication(pid)).map { $0 as! AXUIElement }
    }

    static func children(of element: AXUIElement?) -> [AXUIElement] {
        guard let element else {
            return []
        }
        return attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? []
    }

    static func countIdentifiedItems(in element: AXUIElement, depth: Int) -> Int {
        let own = (attribute(kAXRoleAttribute, of: element) as? String) == kAXMenuBarItemRole
            && attribute(kAXIdentifierAttribute, of: element) is String ? 1 : 0
        guard depth > 0 else {
            return own
        }
        return own + children(of: element).map { countIdentifiedItems(in: $0, depth: depth - 1) }.reduce(0, +)
    }

    static func attribute(_ name: String, of element: AXUIElement) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard
            let positionValue = attribute(kAXPositionAttribute, of: element),
            let sizeValue = attribute(kAXSizeAttribute, of: element)
        else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        // swiftlint:disable force_cast
        guard
            AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else {
            return nil
        }
        // swiftlint:enable force_cast
        return CGRect(origin: position, size: size)
    }
}
