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

        // Task 6.2 tests: applyMoves
        typealias Move = MenuBarLayoutMath.Move

        let baseTable: [String: Double] = [
            "other:x": 42.0,
            "module:Clock": 10.0,
            "status:a::1": 50.0,
            "status:b::1": 100.0,
            "status:c::1": 200.0,
        ]

        // 1. Moving status:a::1 left of status:b::1 yields distance greater than b's
        let moves1 = [Move.leftOf(key: "status:a::1", target: "status:b::1")]
        let res1 = MenuBarLayoutMath.applyMoves(moves1, to: baseTable)
        expect(res1 != nil, "applyMoves returns non-nil for valid move")
        if let res1 {
            expect(res1["other:x"] == 42.0, "unknown key other:x survives unchanged")
            expect(res1["module:Clock"] == 10.0, "module:Clock unchanged")
            let aDist = res1["status:a::1"] ?? 0
            let bDist = res1["status:b::1"] ?? 0
            expect(aDist > bDist, "moving status:a::1 left of status:b::1 yields a distance greater than b's")
            expect(res1.count == baseTable.count, "the key count is unchanged")
        }

        // 2. A missing target returns nil
        let missingTargetMoves = [Move.leftOf(key: "status:a::1", target: "missing:target")]
        expect(MenuBarLayoutMath.applyMoves(missingTargetMoves, to: baseTable) == nil, "a missing target returns nil")

        // 3. A missing key returns nil
        let missingKeyMoves = [Move.leftOf(key: "missing:key", target: "status:b::1")]
        expect(MenuBarLayoutMath.applyMoves(missingKeyMoves, to: baseTable) == nil, "a missing key returns nil")

        // 4. Three consecutive moves into the same gap stay strictly ordered
        let threeMovesTable: [String: Double] = [
            "status:target::1": 100.0,
            "status:item1::1": 10.0,
            "status:item2::1": 20.0,
            "status:item3::1": 30.0,
        ]
        let threeMoves = [
            Move.leftOf(key: "status:item1::1", target: "status:target::1"),
            Move.leftOf(key: "status:item2::1", target: "status:target::1"),
            Move.leftOf(key: "status:item3::1", target: "status:target::1"),
        ]
        let threeRes = MenuBarLayoutMath.applyMoves(threeMoves, to: threeMovesTable)
        expect(threeRes != nil, "three consecutive moves returns non-nil")
        if let threeRes {
            let tDist = threeRes["status:target::1"] ?? 0
            let i1Dist = threeRes["status:item1::1"] ?? 0
            let i2Dist = threeRes["status:item2::1"] ?? 0
            let i3Dist = threeRes["status:item3::1"] ?? 0
            expect(
                tDist < i3Dist && i3Dist < i2Dist && i2Dist < i1Dist,
                "three consecutive moves into the same gap stay strictly ordered"
            )
        }

        // 5. rightOf moves stay ordered
        let rightOfMoves = [Move.rightOf(key: "status:c::1", target: "status:b::1")]
        let rightOfRes = MenuBarLayoutMath.applyMoves(rightOfMoves, to: baseTable)
        expect(rightOfRes != nil, "rightOf move returns non-nil")
        if let rightOfRes {
            let cDist = rightOfRes["status:c::1"] ?? 0
            let bDist = rightOfRes["status:b::1"] ?? 0
            expect(cDist < bDist, "rightOf yields distance smaller than target's")
        }

        // 6. Renumbering when gap < 0.01: leftOf
        let tightTableLeft: [String: Double] = [
            "other:unknown": 500.0,
            "module:Clock": 200.0,
            "status:target::1": 100.0,
            "status:neighbor::1": 100.008,
            "status:toMove::1": 50.0,
        ]
        let tightMoveLeft = [Move.leftOf(key: "status:toMove::1", target: "status:target::1")]
        let tightResLeft = MenuBarLayoutMath.applyMoves(tightMoveLeft, to: tightTableLeft)
        expect(tightResLeft != nil, "tight gap leftOf returns non-nil")
        if let tightResLeft {
            expect(tightResLeft["other:unknown"] == 500.0, "renumbering leaves unknown key untouched")
            expect(tightResLeft["module:Clock"] == 200.0, "renumbering leaves module key untouched")
            let tDist = tightResLeft["status:target::1"] ?? 0
            let mDist = tightResLeft["status:toMove::1"] ?? 0
            let nDist = tightResLeft["status:neighbor::1"] ?? 0
            expect(mDist == tDist + 1.0, "status key spaced 1.0 outward from target")
            expect(nDist == tDist + 2.0, "neighbor status key spaced 2.0 outward from target")
        }

        // 7. Renumbering when gap < 0.01: rightOf
        let tightTableRight: [String: Double] = [
            "other:unknown": 500.0,
            "module:Clock": 50.0,
            "status:target::1": 100.0,
            "status:neighbor::1": 99.992,
            "status:toMove::1": 150.0,
        ]
        let tightMoveRight = [Move.rightOf(key: "status:toMove::1", target: "status:target::1")]
        let tightResRight = MenuBarLayoutMath.applyMoves(tightMoveRight, to: tightTableRight)
        expect(tightResRight != nil, "tight gap rightOf returns non-nil")
        if let tightResRight {
            expect(tightResRight["other:unknown"] == 500.0, "rightOf renumbering leaves unknown key untouched")
            expect(tightResRight["module:Clock"] == 50.0, "rightOf renumbering leaves module key untouched")
            let tDist = tightResRight["status:target::1"] ?? 0
            let mDist = tightResRight["status:toMove::1"] ?? 0
            let nDist = tightResRight["status:neighbor::1"] ?? 0
            expect(mDist == tDist - 1.0, "status key spaced 1.0 outward (down) from target")
            expect(nDist == tDist - 2.0, "neighbor status key spaced 2.0 outward (down) from target")
        }

        if failures == 0 {
            print("PASS")
        } else {
            exit(1)
        }
    }
}
