//
//  TestMenuBarLayoutMath.swift
//  Skein
//

// Unit tests for the AppKit-free macOS 27 layout logic.
// xcrun swiftc -parse-as-library Skein/MenuBar/MacOS27/MenuBarLayoutMath.swift Scripts/TestMenuBarLayoutMath.swift -o .ci-output/test-layout-math && .ci-output/test-layout-math

import CoreGraphics
import Foundation

@main
struct TestMenuBarLayoutMath {
    nonisolated(unsafe) static var failures = 0

    static func expect(_ condition: Bool, _ message: String) {
        if !condition {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() {
        expect(MenuBarLayoutMath.collapseUnit(screenWidths: [1800]) == 836, "1800 → 836")
        expect(MenuBarLayoutMath.collapseUnit(screenWidths: [1800, 3008, 1080]) == 476, "narrowest 1080 → 476")
        expect(MenuBarLayoutMath.collapseUnit(screenWidths: [300]) == 200, "clamped to 200")
        expect(MenuBarLayoutMath.collapseUnit(screenWidths: [1800], userOverride: 700) == 700, "override lowers")
        expect(MenuBarLayoutMath.collapseUnit(screenWidths: [1080], userOverride: 1412) == 476, "override never raises above the cliff")
        expect(MenuBarLayoutMath.collapseUnit(screenWidths: [1800], learnedCap: 804) == 804, "learned cap lowers")
        expect(MenuBarLayoutMath.spacerCount(screenWidths: [1800], unit: 836) == 2, "1800/836 → 2")
        expect(MenuBarLayoutMath.spacerCount(screenWidths: [1800, 3008, 1080], unit: 476) == 6, "3008/476 → 6")
        expect(MenuBarLayoutMath.spacerCount(screenWidths: [], unit: 476) == 0, "no screens → 0")
        if failures == 0 {
            print("PASS")
        } else {
            exit(1)
        }
    }
}
