//
//  TestMenuBarLayoutMath.swift
//  Skein
//

// Unit tests for the AppKit-free macOS 27 layout logic.
// xcrun swiftc -parse-as-library Skein/MenuBar/MacOS27/MenuBarLayoutMath.swift Scripts/TestMenuBarLayoutMath.swift -o .ci-output/test-layout-math && .ci-output/test-layout-math

import CoreGraphics
import Foundation

@main
enum TestMenuBarLayoutMath {
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

        let (planDiv1, planSp1) = MenuBarLayoutMath.ladderPlan(caps: [280, 588, 1432], hiddenSlotMin: 40)
        expect(
            planDiv1 == 264 && planSp1 == [1264, 624, 304, 144, 64, 24],
            "ladderPlan([280, 588, 1432], hiddenSlotMin: 40) gives (264, [1264, 624, 304, 144, 64, 24])"
        )

        let (planDiv2, planSp2) = MenuBarLayoutMath.ladderPlan(caps: [280, 588, 1432], hiddenSlotMin: 32)
        expect(
            planDiv2 == 264 && planSp2 == [1008, 496, 240, 112, 48, 16],
            "ladderPlan([280, 588, 1432], hiddenSlotMin: 32) gives (264, [1008, 496, 240, 112, 48, 16])"
        )

        let (planDiv3, planSp3) = MenuBarLayoutMath.ladderPlan(caps: [280, 588], hiddenSlotMin: 40)
        expect(
            planDiv3 == 264 && planSp3 == [624, 304, 144, 64, 24],
            "caps: [280, 588] drops the 1264 term and leaves five spacers"
        )

        let (planDiv4, planSp4) = MenuBarLayoutMath.ladderPlan(caps: [280], hiddenSlotMin: 40)
        expect(
            planDiv4 == 264 && planSp4.isEmpty,
            "caps: [280] gives (264, [])"
        )

        let (planDiv5, planSp5) = MenuBarLayoutMath.ladderPlan(caps: [280, 588, 1432], hiddenSlotMin: 20)
        expect(
            planDiv5 == planDiv2 && planSp5 == planSp2,
            "hiddenSlotMin: 20 clamps to 32"
        )

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
            Slot(frame: CGRect(x: 1000, y: 0, width: 264, height: 24), isChevron: false, identifier: dividerID),
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
            Slot(frame: CGRect(x: 1000, y: 0, width: 50, height: 24), isChevron: false, identifier: "OtherApp"),
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
            Slot(frame: CGRect(x: 1000, y: 0, width: 264, height: 24), isChevron: false, identifier: dividerID),
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
            Slot(frame: CGRect(x: 1000, y: 0, width: 264, height: 24), isChevron: false, identifier: dividerID),
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
            Slot(frame: CGRect(x: 120, y: 0, width: 50, height: 24), isChevron: false, identifier: "AppA"),
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
            Slot(frame: CGRect(x: 1000, y: 0, width: 264, height: 24), isChevron: false, identifier: dividerID),
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
            Slot(frame: CGRect(x: 1300, y: 0, width: 42, height: 24), isChevron: false, identifier: "RightApp"),
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
            Slot(frame: CGRect(x: 1000, y: 0, width: 264, height: 24), isChevron: false, identifier: dividerID),
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
            Slot(frame: CGRect(x: 1000, y: 0, width: 264, height: 24), isChevron: false, identifier: dividerID),
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
            Slot(frame: CGRect(x: 1300, y: 0, width: 40, height: 24), isChevron: false, identifier: "LeakedApp", pid: 42),
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
            Slot(frame: CGRect(x: 1000, y: 0, width: 264, height: 24), isChevron: false, identifier: dividerID),
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
            Slot(frame: CGRect(x: 1305, y: 0, width: 40, height: 24), isChevron: false, identifier: "AppB", pid: 42),
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

        // Task 3.2 tests
        let statusKey = MenuBarLayoutMath.LayoutTableKey(rawKey: "status:com.example.app::Item-0")
        expect(statusKey?.bundleID == "com.example.app", "statusKey bundleID")
        expect(statusKey?.name == "Item-0", "statusKey name")
        expect(statusKey?.isModule == false, "statusKey isModule")
        expect(statusKey?.rawKey == "status:com.example.app::Item-0", "statusKey rawKey")

        let moduleKey = MenuBarLayoutMath.LayoutTableKey(rawKey: "module:BentoBox-0")
        expect(moduleKey?.bundleID == nil, "moduleKey bundleID")
        expect(moduleKey?.name == "BentoBox", "moduleKey name BentoBox")
        expect(moduleKey?.isModule == true, "moduleKey isModule")
        expect(moduleKey?.rawKey == "module:BentoBox-0", "moduleKey rawKey")

        let garbageKey = MenuBarLayoutMath.LayoutTableKey(rawKey: "garbage")
        expect(garbageKey == nil, "garbageKey == nil")

        let table: [String: Double] = [
            "status:com.example.app::Item-0": 100.0,
            "module:BentoBox-0": 300.0,
            "garbage": 200.0,
            "status:com.example.other::Item-1": 500.0,
        ]
        let ordered = MenuBarLayoutMath.orderedKeys(table)
        expect(ordered.count == 3, "orderedKeys count == 3 (garbage excluded)")
        expect(ordered[0].distance == 500.0 && ordered[0].key.name == "Item-1", "ordered[0] distance 500")
        expect(ordered[1].distance == 300.0 && ordered[1].key.name == "BentoBox", "ordered[1] distance 300")
        expect(ordered[2].distance == 100.0 && ordered[2].key.name == "Item-0", "ordered[2] distance 100")

        if
            let key1 = statusKey,
            let key2 = moduleKey,
            let key3 = MenuBarLayoutMath.LayoutTableKey(rawKey: "status:com.example.other::Item-1")
        {
            let zip2v3 = MenuBarLayoutMath.zip(items: ["A", "B"], keys: [key1, key2, key3], framesTrustworthy: true)
            expect(zip2v3.grouped == true, "zip 2 vs 3 -> grouped")
            expect(zip2v3.pairs.count == 2, "zip 2 vs 3 count == 2")

            let zip2v2Untrusted = MenuBarLayoutMath.zip(items: ["A", "B"], keys: [key1, key2], framesTrustworthy: false)
            expect(zip2v2Untrusted.grouped == true, "zip 2 vs 2 untrusted -> grouped")
            expect(zip2v2Untrusted.pairs.count == 2, "zip 2 vs 2 untrusted count == 2")

            let zip2v2Trusted = MenuBarLayoutMath.zip(items: ["A", "B"], keys: [key1, key2], framesTrustworthy: true)
            expect(zip2v2Trusted.grouped == false, "zip 2 vs 2 trusted -> not grouped")
            expect(zip2v2Trusted.pairs.count == 2, "zip 2 vs 2 trusted count == 2")
        } else {
            expect(false, "Keys failed to initialize for zip tests")
        }

        expect(
            MenuBarLayoutMath.section(forDistance: 545.5, hiddenDivider: 429.5, alwaysHiddenDivider: nil) == .hidden,
            "545.5 with HItem 429.5 -> hidden"
        )
        expect(
            MenuBarLayoutMath.section(forDistance: 385.5, hiddenDivider: 429.5, alwaysHiddenDivider: nil) == .visible,
            "385.5 with HItem 429.5 -> visible"
        )
        expect(
            MenuBarLayoutMath.section(forDistance: 600.0, hiddenDivider: 429.5, alwaysHiddenDivider: 580.0) == .alwaysHidden,
            "600 with AHItem 580, HItem 429.5 -> alwaysHidden"
        )

        if failures == 0 {
            print("PASS")
        } else {
            exit(1)
        }
    }
}
