//
//  VerifyLaunchAnimation.swift
//  Skein
//

// Native playback/lifecycle checks, without starting the menu-bar app or touching permissions.
// xcrun swiftc Skein/Main/LaunchAnimationController.swift Scripts/VerifyLaunchAnimation.swift \
//   -o .ci-output/verify-launch-animation
// .ci-output/verify-launch-animation Skein/Resources

import Cocoa

@main
@MainActor
struct VerifyLaunchAnimation {
    static var failures = 0

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task {
            do {
                try await runChecks()
            } catch {
                print("FAIL: \(error)")
                failures += 1
            }
            print("Launch animation checks: \(failures) failures")
            exit(failures == 0 ? 0 : 1)
        }
        app.run()
    }

    static var visiblePanelCount: Int {
        autoreleasepool {
            NSApp.windows.filter {
                $0.identifier?.rawValue == "SkeinLaunchAnimation" && $0.isVisible
            }.count
        }
    }

    static func show(
        _ controller: LaunchAnimationController,
        login: Bool = false,
        preview: Bool = false,
        reduced: Bool = false,
        replay: Bool = false,
        destination: (() -> NSRect?)? = nil
    ) {
        // AppKit's event pool normally drains between interactions. Give the async
        // harness the same lifetime boundary instead of retaining temporary windows.
        autoreleasepool {
            controller.showIfNeeded(isLoginLaunch: login, isPreview: preview, reduceMotion: reduced, allowReplay: replay, menuBarDestination: destination)
        }
    }

    static func check(_ condition: Bool, _ description: String) {
        print("\(condition ? "PASS" : "FAIL"): \(description)")
        if !condition {
            failures += 1
        }
    }

    static func waitUntil(_ predicate: () -> Bool, seconds: Double) async throws -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !predicate(), Date() < end {
            try await Task.sleep(for: .milliseconds(25))
        }
        return predicate()
    }

    static func runChecks() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "Pass the launch Resources directory", code: 1)
        }
        let files = FileManager.default
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let temp = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: temp) }

        func fixture(_ name: String, movie: Bool, poster: Bool, corrupt: Bool = false) throws -> Bundle {
            let root = temp.appendingPathComponent("\(name).bundle")
            let contents = root.appendingPathComponent("Contents")
            let dest = contents.appendingPathComponent("Resources")
            try files.createDirectory(at: dest, withIntermediateDirectories: true)
            let plist = ["CFBundleIdentifier": "test.skein.\(name)", "CFBundlePackageType": "BNDL"]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
            if poster {
                try files.copyItem(at: resources.appendingPathComponent("skein-launch-poster.png"), to: dest.appendingPathComponent("skein-launch-poster.png"))
                try files.copyItem(at: resources.appendingPathComponent("skein-launch-mark.png"), to: dest.appendingPathComponent("skein-launch-mark.png"))
            }
            if movie {
                let target = dest.appendingPathComponent("skein-launch.mp4")
                if corrupt {
                    try Data("Invalid video for decoder failure verification".utf8).write(to: target)
                } else {
                    try files.copyItem(at: resources.appendingPathComponent("skein-launch.mp4"), to: target)
                }
            }
            guard let bundle = Bundle(url: root) else {
                throw NSError(domain: "Could not load test bundle", code: 2)
            }
            return bundle
        }

        let full = try fixture("full", movie: true, poster: true)
        let normal = LaunchAnimationController(bundle: full)
        show(normal)
        let appeared = try await waitUntil({ visiblePanelCount > 0 }, seconds: 1.5)
        check(appeared, "Real bundled video reaches a visible decoded frame")
        check(!NSApp.isActive && NSApp.keyWindow == nil, "Intro does not activate the app or take keyboard focus")
        check(autoreleasepool {
            NSApp.windows.first { $0.identifier?.rawValue == "SkeinLaunchAnimation" && $0.isVisible }?.ignoresMouseEvents == true
        }, "Intro leaves pointer interaction available")
        let dismissed = try await waitUntil({ visiblePanelCount == 0 }, seconds: 4)
        check(dismissed, "Playback automatically dismisses the panel")
        show(normal)
        try await Task.sleep(for: .milliseconds(150))
        check(visiblePanelCount == 0, "Same controller never replays within the process")

        show(normal, replay: true)
        let replayed = try await waitUntil({ visiblePanelCount > 0 }, seconds: 1.5)
        check(replayed, "Explicit development reopen replays a completed intro")
        show(normal, replay: true)
        check(visiblePanelCount == 1, "Repeated opens never stack intro panels")
        normal.dismiss()
        _ = try await waitUntil({ visiblePanelCount == 0 }, seconds: 1)

        let reduced = LaunchAnimationController(bundle: full)
        var reducedDestinationCalls = 0
        show(reduced, reduced: true, destination: {
            reducedDestinationCalls += 1
            return .zero
        })
        check(visiblePanelCount == 1, "Reduce Motion immediately shows the static poster")
        try await Task.sleep(for: .milliseconds(800))
        check(visiblePanelCount == 0, "Reduce Motion dismisses without an animated wait")
        check(reducedDestinationCalls == 0, "Reduce Motion never starts a menu-bar flight")

        let early = LaunchAnimationController(bundle: full)
        show(early)
        _ = try await waitUntil({ visiblePanelCount > 0 }, seconds: 1.5)
        early.dismiss()
        early.dismiss()
        try await Task.sleep(for: .milliseconds(350))
        check(visiblePanelCount == 0, "Opening Settings can dismiss early; repeated dismissal is safe")

        guard let screen = NSScreen.main else {
            throw NSError(domain: "Native playback checks require a display", code: 3)
        }
        let target = NSRect(x: screen.frame.maxX - 150, y: screen.frame.maxY - 25, width: 24, height: 22)
        let guided = LaunchAnimationController(bundle: full)
        var destinationCalls = 0
        show(guided, destination: {
            destinationCalls += 1
            return target
        })
        let arrived = try await waitUntil({
            autoreleasepool {
                NSApp.windows.contains {
                    $0.identifier?.rawValue == "SkeinLaunchAnimation" && $0.isVisible &&
                    $0.frame.width < 50 && abs($0.frame.midX - target.midX) < 3
                }
            }
        }, seconds: 4)
        check(arrived && destinationCalls == 1, "Completed playback shrinks toward the resolved menu-bar control")
        let guidedDismissed = try await waitUntil({ visiblePanelCount == 0 }, seconds: 1)
        check(guidedDismissed, "Menu-bar handoff releases its presentation")
        check(!NSApp.isActive && NSApp.keyWindow == nil, "Menu-bar handoff does not take focus")

        let login = LaunchAnimationController(bundle: full)
        show(login, login: true)
        let preview = LaunchAnimationController(bundle: full)
        show(preview, preview: true)
        try await Task.sleep(for: .milliseconds(150))
        check(visiblePanelCount == 0, "Login launches and SwiftUI previews stay quiet")

        let still = LaunchAnimationController(bundle: try fixture("still", movie: false, poster: true))
        show(still)
        check(visiblePanelCount == 1, "Missing movie uses the bundled poster")
        try await Task.sleep(for: .milliseconds(1000))
        check(visiblePanelCount == 0, "Poster fallback dismisses")

        let empty = LaunchAnimationController(bundle: try fixture("empty", movie: false, poster: false))
        show(empty)
        check(visiblePanelCount == 0, "Missing assets do not create a visible panel")

        let corrupt = LaunchAnimationController(bundle: try fixture("corrupt", movie: true, poster: true, corrupt: true))
        show(corrupt)
        try await Task.sleep(for: .seconds(4))
        check(visiblePanelCount == 0, "Decoder failure never strands a launch panel")
        // Drain AppKit's outer event pool as a real app interaction would. A pure
        // async harness otherwise retains the last animated NSWindow temporarily.
        if let event = NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0
        ) {
            NSApp.postEvent(event, atStart: false)
        }
        try await Task.sleep(for: .milliseconds(150))
        check(autoreleasepool {
            !NSApp.windows.contains { $0.identifier?.rawValue == "SkeinLaunchAnimation" }
        }, "Dismissal releases all launch windows")
    }
}
