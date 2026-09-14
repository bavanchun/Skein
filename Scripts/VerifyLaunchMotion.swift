//
//  VerifyLaunchMotion.swift
//  Skein
//

// Verify composited pixels from the installed app, not just player readiness.
// xcrun swiftc -parse-as-library Scripts/VerifyLaunchMotion.swift -o .ci-output/verify-launch-motion
// .ci-output/verify-launch-motion '/Applications/Skein Dev.app' .ci-output/dev/visible-motion
// Requires a desktop session and Screen Recording permission for the terminal.

import Cocoa

@main
struct VerifyLaunchMotion {
    static func main() {
        do {
            try verify()
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func fail(_ message: String) -> NSError {
        NSError(domain: "VerifyLaunchMotion", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func run(_ executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw fail("\(executable) exited with \(process.terminationStatus)")
        }
    }

    static func verify() throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            throw fail("Reduce Motion is enabled; a still poster is expected instead of animation")
        }
        guard CommandLine.arguments.count == 3 else {
            throw fail("Pass the Skein Dev.app path and a capture output directory")
        }
        let appURL = URL(fileURLWithPath: CommandLine.arguments[1])
        guard Bundle(url: appURL)?.bundleIdentifier == "com.ariadnev.Skein.dev" else {
            throw fail("This check reopens Skein Dev; pass the development app")
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try run("/usr/bin/open", arguments: [appURL.path])

        var windowID: Int?
        let deadline = Date().addingTimeInterval(2)
        while windowID == nil, Date() < deadline {
            let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.ariadnev.Skein.dev").map { Int($0.processIdentifier) })
            let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            for row in rows {
                guard
                    let pid = row[kCGWindowOwnerPID as String] as? Int, pids.contains(pid),
                    let bounds = row[kCGWindowBounds as String] as? [String: Double],
                    bounds["Width"] == 360, bounds["Height"] == 360
                else {
                    continue
                }
                windowID = row[kCGWindowNumber as String] as? Int
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard let windowID else {
            throw fail("No visible launch panel appeared")
        }

        let appeared = Date()
        var frames = [NSBitmapImageRep]()
        for (index, delay) in [0.20, 0.85, 1.50].enumerated() {
            while Date().timeIntervalSince(appeared) < delay {
                Thread.sleep(forTimeInterval: 0.01)
            }
            let path = output.appendingPathComponent("frame-\(index).png")
            try run("/usr/sbin/screencapture", arguments: ["-x", "-o", "-l", String(windowID), path.path])
            guard let frame = NSBitmapImageRep(data: try Data(contentsOf: path)) else {
                throw fail("Could not decode captured window")
            }
            frames.append(frame)
        }
        for index in 1..<frames.count {
            let fraction = try changedFraction(frames[index - 1], frames[index])
            guard fraction > 0.03 else {
                throw fail("The visible intro is static: only \(Int(fraction * 100))% changed between captures \(index - 1) and \(index)")
            }
            print("PASS: Visible frame \(index - 1) → \(index): \(Int(fraction * 100))% of sampled pixels changed")
        }
    }

    static func changedFraction(_ first: NSBitmapImageRep, _ second: NSBitmapImageRep) throws -> Double {
        guard first.pixelsWide == second.pixelsWide, first.pixelsHigh == second.pixelsHigh else {
            throw fail("The window changed size before motion could be verified")
        }
        var changed = 0
        var samples = 0
        // Exclude transparent corners and window edges; measure the actual artwork.
        for y in stride(from: first.pixelsHigh / 10, to: first.pixelsHigh * 9 / 10, by: 8) {
            for x in stride(from: first.pixelsWide / 10, to: first.pixelsWide * 9 / 10, by: 8) {
                guard
                    let a = first.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                    let b = second.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                else {
                    throw fail("Could not compare captured pixels")
                }
                let difference = max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent), abs(a.blueComponent - b.blueComponent))
                changed += difference > 0.08 ? 1 : 0
                samples += 1
            }
        }
        return Double(changed) / Double(samples)
    }
}
