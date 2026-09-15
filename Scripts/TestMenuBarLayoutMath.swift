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
        expect(MenuBarLayoutMath.startUnit(screenWidths: [1800]) == 884, "startUnit([1800]) == 884")
        expect(MenuBarLayoutMath.startUnit(screenWidths: [1800, 3008, 1080]) == 524, "startUnit([1800, 3008, 1080]) == 524")
        expect(MenuBarLayoutMath.startUnit(screenWidths: [60]) == 40, "startUnit([60]) == 40")
        expect(MenuBarLayoutMath.startUnit(screenWidths: []) == 200, "startUnit([]) == 200")
        expect(MenuBarLayoutMath.startUnit(screenWidths: [1800], userOverride: 700) == 700, "startUnit([1800], userOverride: 700) == 700")
        expect(MenuBarLayoutMath.startUnit(screenWidths: [1080], userOverride: 5000) == 524, "startUnit([1080], userOverride: 5000) == 524")

        expect(MenuBarLayoutMath.nextProbe(honored: 40, dropped: 524) == 280, "nextProbe(honored: 40, dropped: 524) == 280")
        expect(MenuBarLayoutMath.nextProbe(honored: 280, dropped: 524) == 392, "nextProbe(honored: 280, dropped: 524) == 392")
        expect(MenuBarLayoutMath.nextProbe(honored: 40, dropped: 80) == 56, "nextProbe(honored: 40, dropped: 80) == 56")
        expect(MenuBarLayoutMath.nextProbe(honored: 40, dropped: 72) == nil, "nextProbe(honored: 40, dropped: 72) == nil")

        expect(MenuBarLayoutMath.spacerCount(widestWidth: 1800, unit: 884) == 2, "spacerCount(widestWidth: 1800, unit: 884) == 2")
        expect(MenuBarLayoutMath.spacerCount(widestWidth: 3008, unit: 524) == 5, "spacerCount(widestWidth: 3008, unit: 524) == 5")
        expect(MenuBarLayoutMath.spacerCount(widestWidth: 3008, unit: 216) == 6, "spacerCount(widestWidth: 3008, unit: 216) == 6")
        expect(MenuBarLayoutMath.spacerCount(widestWidth: 0, unit: 216) == 0, "spacerCount(widestWidth: 0, unit: 216) == 0")

        expect(MenuBarLayoutMath.coversWidest(widestWidth: 3008, unit: 524, spacers: 5) == true, "coversWidest(widestWidth: 3008, unit: 524, spacers: 5) == true")
        expect(MenuBarLayoutMath.coversWidest(widestWidth: 3008, unit: 216, spacers: 6) == false, "coversWidest(widestWidth: 3008, unit: 216, spacers: 6) == false")

        typealias Obs = MenuBarLayoutMath.DisplayObservation
        let before1 = ["A": Obs(0, 0), "B": Obs(1, 0)]
        let after1 = ["A": Obs(1, 0), "B": Obs(2, 0)]
        expect(MenuBarLayoutMath.isHonored(before: before1, after: after1, expectedIncrease: 1) == true, "isHonored 1 == true")

        var after2 = after1
        after2["A"] = Obs(1, 1)
        expect(MenuBarLayoutMath.isHonored(before: before1, after: after2, expectedIncrease: 1) == false, "after[A]=(1,1) -> false")

        var after3 = after1
        after3["B"] = Obs(1, 0)
        expect(MenuBarLayoutMath.isHonored(before: before1, after: after3, expectedIncrease: 1) == false, "after[B]=(1,0) -> false")

        let afterEmpty: [String: Obs] = [:]
        expect(MenuBarLayoutMath.isHonored(before: before1, after: afterEmpty, expectedIncrease: 1) == false, "after=[:] -> false")

        let beforeEmpty: [String: Obs] = [:]
        let after4 = ["A": Obs(2, 0)]
        expect(MenuBarLayoutMath.isHonored(before: beforeEmpty, after: after4, expectedIncrease: 2) == true, "before empty after [A:(2,0)] -> true")

        if failures == 0 {
            print("PASS")
        } else {
            exit(1)
        }
    }
}
