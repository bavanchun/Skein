//
//  PendingLayout.swift
//  Skein
//

import Combine
import Foundation

/// Manages pending menu bar item moves and generates an overlay for the item cache on macOS 27.
@MainActor
final class PendingLayout: ObservableObject {
    /// Recorded relative layout moves.
    @Published private(set) var moves: [MenuBarLayoutMath.Move] = []

    /// Indicates whether unapplied layout changes are pending.
    var hasChanges: Bool {
        !moves.isEmpty
    }

    /// Records a layout move.
    ///
    /// - Parameter move: The relative move operation to record.
    func record(_ move: MenuBarLayoutMath.Move) {
        moves.append(move)
    }

    /// Clears all recorded moves without applying them.
    func discard() {
        moves.removeAll()
    }

    /// Replays recorded moves on the given item cache.
    ///
    /// - Parameter cache: The base item cache to overlay.
    /// - Returns: A new item cache with the pending moves applied.
    func overlay(on cache: MenuBarItemManager.ItemCache) -> MenuBarItemManager.ItemCache {
        var result = cache
        let hKey = "status:\(Constants.bundleIdentifier)::\(ControlItem.Identifier.hidden.rawValue)"
        let ahKey = "status:\(Constants.bundleIdentifier)::\(ControlItem.Identifier.alwaysHidden.rawValue)"

        for move in moves {
            let key: String
            let targetKey: String
            let isLeft: Bool
            switch move {
            case .leftOf(let k, let t):
                key = k
                targetKey = t
                isLeft = true
            case .rightOf(let k, let t):
                key = k
                targetKey = t
                isLeft = false
            }

            var sourceItem: MenuBarItem?
            var sourceSection: MenuBarSection.Name?
            var sourceIndex: Int?

            for section in MenuBarSection.Name.allCases {
                if let index = result[section].firstIndex(where: { item in
                    if case .accessibility(let ax) = item.backing {
                        return ax.tableKey == key
                    }
                    return false
                }) {
                    sourceItem = result[section][index]
                    sourceSection = section
                    sourceIndex = index
                    break
                }
            }

            guard
                let item = sourceItem,
                let fromSection = sourceSection,
                let fromIndex = sourceIndex
            else {
                continue
            }

            var targetSection: MenuBarSection.Name?
            var targetIndex: Int?

            for section in MenuBarSection.Name.allCases {
                if let index = result[section].firstIndex(where: { other in
                    if case .accessibility(let ax) = other.backing {
                        return ax.tableKey == targetKey
                    }
                    return false
                }) {
                    targetSection = section
                    targetIndex = index
                    break
                }
            }

            if
                let toSection = targetSection,
                let toIndex = targetIndex
            {
                result[fromSection].remove(at: fromIndex)
                let insertionIndex: Int
                if
                    fromSection == toSection,
                    fromIndex < toIndex
                {
                    let adjustedTargetIndex = toIndex - 1
                    insertionIndex = isLeft ? adjustedTargetIndex : adjustedTargetIndex + 1
                } else {
                    insertionIndex = isLeft ? toIndex : toIndex + 1
                }
                let clampedIndex = max(0, min(insertionIndex, result[toSection].count))
                result[toSection].insert(item, at: clampedIndex)
            } else if targetKey == hKey {
                result[fromSection].remove(at: fromIndex)
                if isLeft {
                    result[.hidden].append(item)
                } else {
                    result[.visible].insert(item, at: 0)
                }
            } else if targetKey == ahKey {
                result[fromSection].remove(at: fromIndex)
                if isLeft {
                    result[.alwaysHidden].append(item)
                } else {
                    result[.hidden].insert(item, at: 0)
                }
            }
        }

        return result
    }

    /// Applies pending layout moves to the layout table.
    ///
    /// - Returns: The outcome of the apply operation.
    func apply() async -> LayoutTableWriter.ApplyResult {
        let result = await LayoutTableWriter.apply(moves)
        if
            result == .applied ||
            result == .noChange
        {
            discard()
        }
        return result
    }
}
