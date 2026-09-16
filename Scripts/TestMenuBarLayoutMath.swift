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

        let (div1, sp1) = MenuBarLayoutMath.ladderLengths(caps: [280, 588, 1496])
        expect(div1 == 264 && sp1 == [1200], "ladderLengths(caps: [280, 588, 1496]) == (264, [1200])")

        let (_, spNarrowGap) = MenuBarLayoutMath.ladderLengths(caps: [280, 900, 1000])
        expect(spNarrowGap.isEmpty, "ladderLengths(caps: [280, 900, 1000]) has no spacer shorter than the second cap")

        let (div2, sp2) = MenuBarLayoutMath.ladderLengths(caps: [280])
        expect(div2 == 264 && sp2.isEmpty, "ladderLengths(caps: [280]) == (264, [])")

        let (div3, sp3) = MenuBarLayoutMath.ladderLengths(caps: [280, 300])
        expect(div3 == 264 && sp3.isEmpty, "ladderLengths(caps: [280, 300]) == (264, [])")

        let (div4, _) = MenuBarLayoutMath.ladderLengths(caps: [40])
        expect(div4 == 40, "ladderLengths(caps: [40]).divider == 40")

        let bounds1 = MenuBarLayoutMath.fillBounds(caps: [280, 588, 1496], ladder: (div1, sp1))
        expect(bounds1?.lower == 589 && bounds1?.upper == 1496, "fillBounds(caps: [280, 588, 1496]) == (589, 1496)")

        let bounds2 = MenuBarLayoutMath.fillBounds(caps: [1496], ladder: (div1, sp1))
        expect(bounds2?.lower == 40 && bounds2?.upper == 1496, "fillBounds(caps: [1496]) == (40, 1496)")

        expect(MenuBarLayoutMath.summary([.collapsed, .itemsVisible]) == .itemsVisible, "summary([collapsed, itemsVisible]) == itemsVisible")
        expect(MenuBarLayoutMath.summary([.collapsed, .dividerDropped, .itemsVisible]) == .dividerDropped, "summary([collapsed, dividerDropped, itemsVisible]) == dividerDropped")
        expect(MenuBarLayoutMath.summary([]) == nil, "summary([]) == nil")

        typealias Slot = MenuBarLayoutMath.Slot
        typealias Obs = MenuBarLayoutMath.DisplayObservation
        let bar = CGRect(x: 0, y: 0, width: 2000, height: 24)
        let dividerID = "HItem"
        let dividerWidth: CGFloat = 264
        let ownIDs: Set<String> = ["HItem", "AHItem", "SItem", "HItemSpacer0"]
        let ownWidths: Set<CGFloat> = [264, 17, 30]

        let obs1 = Obs(bar: bar, slots: [
            Slot(frame: CGRect(x: 1000, y: 0, width: 264, height: 24), isChevron: false, identifier: dividerID)
        ])
        expect(
            MenuBarLayoutMath.state(
                of: obs1,
                dividerIdentifier: dividerID,
                dividerSlotWidth: dividerWidth,
                ownIdentifiers: ownIDs,
                ownSlotWidths: ownWidths
            ) == .collapsed,
            "block with nothing left of it gives collapsed"
        )

        let obs2 = Obs(bar: bar, slots: [
            Slot(frame: CGRect(x: 1000, y: 0, width: 50, height: 24), isChevron: false, identifier: "OtherApp")
        ])
        expect(
            MenuBarLayoutMath.state(
                of: obs2,
                dividerIdentifier: dividerID,
                dividerSlotWidth: dividerWidth,
                ownIdentifiers: ownIDs,
                ownSlotWidths: ownWidths
            ) == .dividerDropped,
            "missing divider gives dividerDropped"
        )

        let obs3 = Obs(bar: bar, slots: [
            Slot(frame: CGRect(x: 800, y: 0, width: 42, height: 24), isChevron: false, identifier: nil),
            Slot(frame: CGRect(x: 1000, y: 0, width: 264, height: 24), isChevron: false, identifier: dividerID)
        ])
        expect(
            MenuBarLayoutMath.state(
                of: obs3,
                dividerIdentifier: dividerID,
                dividerSlotWidth: dividerWidth,
                ownIdentifiers: ownIDs,
                ownSlotWidths: ownWidths
            ) == .itemsVisible,
            "42pt non-ours slot left of the block gives itemsVisible"
        )

        let obs4 = Obs(bar: bar, slots: [
            Slot(frame: CGRect(x: 500, y: 0, width: 30, height: 24), isChevron: true, identifier: nil),
            Slot(frame: CGRect(x: 1000, y: 0, width: 264, height: 24), isChevron: false, identifier: dividerID)
        ])
        expect(
            MenuBarLayoutMath.state(
                of: obs4,
                dividerIdentifier: dividerID,
                dividerSlotWidth: dividerWidth,
                ownIdentifiers: ownIDs,
                ownSlotWidths: ownWidths
            ) == .collapsed,
            "chevron left of the block is ignored (collapsed)"
        )

        let obs5 = Obs(bar: bar, slots: [
            Slot(frame: CGRect(x: 100, y: 0, width: 264, height: 24), isChevron: false, identifier: dividerID),
            Slot(frame: CGRect(x: 120, y: 0, width: 50, height: 24), isChevron: false, identifier: "AppA")
        ])
        expect(
            MenuBarLayoutMath.state(
                of: obs5,
                dividerIdentifier: dividerID,
                dividerSlotWidth: dividerWidth,
                ownIdentifiers: ownIDs,
                ownSlotWidths: ownWidths
            ) == .collapsed,
            "divider inside an overlapping pile gives collapsed"
        )

        let obs6 = Obs(bar: bar, slots: [
            Slot(frame: CGRect(x: 200, y: 0, width: 40, height: 24), isChevron: false, identifier: "AppA"),
            Slot(frame: CGRect(x: 210, y: 0, width: 40, height: 24), isChevron: false, identifier: "AppB"),
            Slot(frame: CGRect(x: 1000, y: 0, width: 264, height: 24), isChevron: false, identifier: dividerID)
        ])
        expect(
            MenuBarLayoutMath.state(
                of: obs6,
                dividerIdentifier: dividerID,
                dividerSlotWidth: dividerWidth,
                ownIdentifiers: ownIDs,
                ownSlotWidths: ownWidths
            ) == .collapsed,
            "non-ours slot inside the pile left of the block is ignored (collapsed)"
        )

        let obs7 = Obs(bar: bar, slots: [
            Slot(frame: CGRect(x: 1000, y: 0, width: 264, height: 24), isChevron: false, identifier: dividerID),
            Slot(frame: CGRect(x: 1300, y: 0, width: 42, height: 24), isChevron: false, identifier: "RightApp")
        ])
        expect(
            MenuBarLayoutMath.state(
                of: obs7,
                dividerIdentifier: dividerID,
                dividerSlotWidth: dividerWidth,
                ownIdentifiers: ownIDs,
                ownSlotWidths: ownWidths
            ) == .collapsed,
            "non-ours slot right of the block gives collapsed"
        )

        let obs8 = Obs(bar: bar, slots: [
            Slot(frame: CGRect(x: 700, y: 0, width: 264, height: 24), isChevron: false, identifier: "OtherApp"),
            Slot(frame: CGRect(x: 1000, y: 0, width: 264, height: 24), isChevron: false, identifier: dividerID)
        ])
        expect(
            MenuBarLayoutMath.state(
                of: obs8,
                dividerIdentifier: dividerID,
                dividerSlotWidth: dividerWidth,
                ownIdentifiers: ownIDs,
                ownSlotWidths: ownWidths
            ) == .itemsVisible,
            "identifier matching wins over a width clash"
        )

        let obs9 = Obs(bar: bar, slots: [
            Slot(frame: CGRect(x: 1000, y: 0, width: 264, height: 24), isChevron: false, identifier: dividerID)
        ])
        expect(
            MenuBarLayoutMath.state(
                of: obs9,
                dividerIdentifier: dividerID,
                dividerSlotWidth: 4208,
                ownIdentifiers: ownIDs,
                ownSlotWidths: ownWidths
            ) == .dividerDropped,
            "divider slot at a previous width reads as dropped"
        )

        let hiddenPIDs: Set<pid_t> = [42]
        let obsLeakedRight = Obs(bar: bar, slots: [
            Slot(frame: CGRect(x: 1000, y: 0, width: 264, height: 24), isChevron: false, identifier: dividerID),
            Slot(frame: CGRect(x: 1300, y: 0, width: 40, height: 24), isChevron: false, identifier: "LeakedApp", pid: 42)
        ])
        let leakedRight = MenuBarLayoutMath.leakedProcessIdentifiers(
            in: obsLeakedRight,
            dividerIdentifier: dividerID,
            dividerSlotWidth: dividerWidth,
            ownIdentifiers: ownIDs,
            ownSlotWidths: ownWidths,
            hiddenPIDs: hiddenPIDs
        )
        expect(leakedRight == [42], "slot with a leaked pid right of the block is reported")

        let obsLeakedLeft = Obs(bar: bar, slots: [
            Slot(frame: CGRect(x: 800, y: 0, width: 40, height: 24), isChevron: false, identifier: "LeftApp", pid: 42),
            Slot(frame: CGRect(x: 1000, y: 0, width: 264, height: 24), isChevron: false, identifier: dividerID)
        ])
        let leakedLeft = MenuBarLayoutMath.leakedProcessIdentifiers(
            in: obsLeakedLeft,
            dividerIdentifier: dividerID,
            dividerSlotWidth: dividerWidth,
            ownIdentifiers: ownIDs,
            ownSlotWidths: ownWidths,
            hiddenPIDs: hiddenPIDs
        )
        expect(leakedLeft.isEmpty, "same pid left of the block is not reported")

        let obsLeakedPile = Obs(bar: bar, slots: [
            Slot(frame: CGRect(x: 1000, y: 0, width: 264, height: 24), isChevron: false, identifier: dividerID),
            Slot(frame: CGRect(x: 1300, y: 0, width: 40, height: 24), isChevron: false, identifier: "AppA", pid: 42),
            Slot(frame: CGRect(x: 1305, y: 0, width: 40, height: 24), isChevron: false, identifier: "AppB", pid: 42)
        ])
        let leakedPile = MenuBarLayoutMath.leakedProcessIdentifiers(
            in: obsLeakedPile,
            dividerIdentifier: dividerID,
            dividerSlotWidth: dividerWidth,
            ownIdentifiers: ownIDs,
            ownSlotWidths: ownWidths,
            hiddenPIDs: hiddenPIDs
        )
        expect(leakedPile.isEmpty, "leaked pid in an overflow pile is not reported")

        if failures == 0 {
            print("PASS")
        } else {
            exit(1)
        }
    }
}
