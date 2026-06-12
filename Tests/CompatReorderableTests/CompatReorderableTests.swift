//
//  CompatReorderableTests.swift
//  CompatReorderable
//

import CoreGraphics
import Foundation
import Testing
@testable import CompatReorderable

private struct Item: Identifiable, Equatable {
    let id: String
}

private func items(_ ids: String...) -> [Item] {
    ids.map(Item.init)
}

private func ids(_ items: [Item]) -> [String] {
    items.map(\.id)
}

// MARK: - CompatReorderDifference.apply

struct DifferenceApplyTests {
    @Test func movesSourceBeforeDestination() {
        var list = items("a", "b", "c", "d")
        let difference = CompatReorderDifference(
            sources: ["a"],
            destination: .init(position: .before("d"))
        )
        difference.apply(to: &list)
        #expect(ids(list) == ["b", "c", "a", "d"])
    }

    @Test func movesSourceToEnd() {
        var list = items("a", "b", "c", "d")
        let difference = CompatReorderDifference(
            sources: ["b"],
            destination: .init(position: .end)
        )
        difference.apply(to: &list)
        #expect(ids(list) == ["a", "c", "d", "b"])
    }

    @Test func movesMultipleSourcesKeepingTheirOrder() {
        var list = items("a", "b", "c", "d", "e")
        let difference = CompatReorderDifference(
            sources: ["d", "a"],
            destination: .init(position: .before("c"))
        )
        difference.apply(to: &list)
        #expect(ids(list) == ["b", "d", "a", "c", "e"])
    }

    @Test func missingDestinationAppendsToEnd() {
        var list = items("a", "b", "c")
        let difference = CompatReorderDifference(
            sources: ["a"],
            destination: .init(position: .before("nope"))
        )
        difference.apply(to: &list)
        #expect(ids(list) == ["b", "c", "a"])
    }

    @Test func unknownSourcesLeaveArrayUntouched() {
        var list = items("a", "b", "c")
        let difference = CompatReorderDifference(
            sources: ["nope"],
            destination: .init(position: .end)
        )
        difference.apply(to: &list)
        #expect(ids(list) == ["a", "b", "c"])
    }

    @Test func duplicateSourcesAreDeduplicated() {
        var list = items("a", "b", "c")
        let difference = CompatReorderDifference(
            sources: ["a", "a"],
            destination: .init(position: .end)
        )
        difference.apply(to: &list)
        #expect(ids(list) == ["b", "c", "a"])
    }

    @Test func noOpMoveKeepsIdentity() {
        var list = items("a", "b", "c")
        let difference = CompatReorderDifference(
            sources: ["a"],
            destination: .init(position: .before("b"))
        )
        difference.apply(to: &list)
        #expect(ids(list) == ["a", "b", "c"])
    }
}

// MARK: - Coordinator drag lifecycle and retargeting

/// A single column of four 100pt-tall cells at x = 0, width 100:
/// "a" at y 0–100, "b" 100–200, "c" 200–300, "d" 300–400.
private func makeSingleColumnCoordinator() -> CompatReorderCoordinator<String> {
    let coordinator = CompatReorderCoordinator<String>()
    coordinator.sourceIDs = ["a", "b", "c", "d"]
    for (index, id) in ["a", "b", "c", "d"].enumerated() {
        coordinator.frames[id] = CGRect(x: 0, y: CGFloat(index) * 100, width: 100, height: 100)
    }
    return coordinator
}

/// Two 100×100 cells side by side: "a" at x 0–100, "b" at x 110–210.
private func makeTwoColumnCoordinator() -> CompatReorderCoordinator<String> {
    let coordinator = CompatReorderCoordinator<String>()
    coordinator.sourceIDs = ["a", "b"]
    coordinator.frames["a"] = CGRect(x: 0, y: 0, width: 100, height: 100)
    coordinator.frames["b"] = CGRect(x: 110, y: 0, width: 100, height: 100)
    return coordinator
}

struct CoordinatorTests {
    @Test func beginDragSeedsDisplayOrder() {
        let coordinator = makeSingleColumnCoordinator()
        coordinator.beginDrag(id: "a")
        #expect(coordinator.draggedID == "a")
        #expect(coordinator.displayIDs == ["a", "b", "c", "d"])
    }

    @Test func secondBeginDragIsIgnored() {
        let coordinator = makeSingleColumnCoordinator()
        coordinator.beginDrag(id: "a")
        coordinator.beginDrag(id: "b")
        #expect(coordinator.draggedID == "a")
    }

    @Test func pointInsideOwnFrameIsADeadZone() {
        let coordinator = makeSingleColumnCoordinator()
        coordinator.beginDrag(id: "a")
        coordinator.dragMoved(at: CGPoint(x: 50, y: 50))
        #expect(coordinator.displayIDs == ["a", "b", "c", "d"])
        #expect(coordinator.moveCount == 0)
    }

    @Test func sameColumnMoveWaitsForEntryDepth() {
        let coordinator = makeSingleColumnCoordinator()
        coordinator.beginDrag(id: "a")

        // 10pt into "b" (entry depth is 20% of 100 = 20pt): no retarget yet.
        coordinator.dragMoved(at: CGPoint(x: 50, y: 110))
        #expect(coordinator.displayIDs == ["a", "b", "c", "d"])

        // 25pt in: retarget fires, "a" takes "b"'s slot.
        coordinator.dragMoved(at: CGPoint(x: 50, y: 125))
        #expect(coordinator.displayIDs == ["b", "a", "c", "d"])
        #expect(coordinator.moveCount == 1)
    }

    @Test func crossColumnMoveTriggersOnContainment() {
        let coordinator = makeTwoColumnCoordinator()
        coordinator.beginDrag(id: "a")
        coordinator.dragMoved(at: CGPoint(x: 160, y: 50))
        #expect(coordinator.displayIDs == ["b", "a"])
    }

    @Test func pointBelowAllCellsAppendsToEnd() {
        let coordinator = makeSingleColumnCoordinator()
        coordinator.beginDrag(id: "a")
        coordinator.dragMoved(at: CGPoint(x: 50, y: 600))
        #expect(coordinator.displayIDs == ["b", "c", "d", "a"])
    }

    @Test func cooldownBlocksImmediateSecondMove() {
        let coordinator = makeSingleColumnCoordinator()
        coordinator.beginDrag(id: "a")

        coordinator.dragMoved(at: CGPoint(x: 50, y: 130))
        #expect(coordinator.displayIDs == ["b", "a", "c", "d"])

        // Immediately retarget again (frames are static in tests, so "c"'s
        // frame still contains this point): blocked by the cooldown.
        coordinator.dragMoved(at: CGPoint(x: 50, y: 230))
        #expect(coordinator.displayIDs == ["b", "a", "c", "d"])

        // After the cooldown elapses the same point retargets.
        Thread.sleep(forTimeInterval: 0.2)
        coordinator.dragMoved(at: CGPoint(x: 50, y: 230))
        #expect(coordinator.displayIDs == ["b", "c", "a", "d"])
        #expect(coordinator.moveCount == 2)
    }

    @Test func commitReportsMoveBeforeSuccessor() {
        let coordinator = makeSingleColumnCoordinator()
        var reported: (sources: [String], before: String?)?
        coordinator.commitMove = { reported = ($0, $1) }

        coordinator.beginDrag(id: "a")
        coordinator.dragMoved(at: CGPoint(x: 50, y: 130))  // -> [b, a, c, d]
        coordinator.commitDrop()

        #expect(reported?.sources == ["a"])
        #expect(reported?.before == "c")
    }

    @Test func commitAtEndReportsNilSuccessor() {
        let coordinator = makeSingleColumnCoordinator()
        var reported: (sources: [String], before: String?)?
        coordinator.commitMove = { reported = ($0, $1) }

        coordinator.beginDrag(id: "a")
        coordinator.dragMoved(at: CGPoint(x: 50, y: 600))  // -> [b, c, d, a]
        coordinator.commitDrop()

        #expect(reported?.sources == ["a"])
        #expect(reported?.before == nil)
    }

    @Test func commitWithoutOrderChangeReportsNothing() {
        let coordinator = makeSingleColumnCoordinator()
        var reportCount = 0
        coordinator.commitMove = { _, _ in reportCount += 1 }

        coordinator.beginDrag(id: "a")
        coordinator.commitDrop()

        #expect(reportCount == 0)
    }

    @Test func revertRestoresSourceOrderAndFinishClearsState() {
        let coordinator = makeSingleColumnCoordinator()
        coordinator.beginDrag(id: "a")
        coordinator.dragMoved(at: CGPoint(x: 50, y: 130))
        #expect(coordinator.displayIDs == ["b", "a", "c", "d"])

        coordinator.revertDrag()
        #expect(coordinator.displayIDs == ["a", "b", "c", "d"])

        coordinator.finishDrag()
        #expect(coordinator.draggedID == nil)
        #expect(coordinator.displayIDs == nil)
    }

    @Test func itemLookupByPoint() {
        let coordinator = makeSingleColumnCoordinator()
        #expect(coordinator.itemID(at: CGPoint(x: 50, y: 250)) == "c")
        #expect(coordinator.itemID(at: CGPoint(x: 500, y: 50)) == nil)
    }
}

// MARK: - The type-erased UIKit boundary

struct DragDrivingBoundaryTests {
    @Test func tokenRoundTrip() {
        let coordinator = makeSingleColumnCoordinator()
        let driving: any CompatReorderDragDriving = coordinator

        let token = driving.dragToken(at: CGPoint(x: 50, y: 150))
        #expect(token == AnyHashable("b"))

        #expect(driving.liftFrame(for: token!) == CGRect(x: 0, y: 100, width: 100, height: 100))

        driving.beginDrag(token: token!)
        #expect(coordinator.draggedID == "b")
        #expect(driving.hasActiveDrag)
    }

    @Test func foreignTokenIsIgnored() {
        let coordinator = makeSingleColumnCoordinator()
        let driving: any CompatReorderDragDriving = coordinator

        driving.beginDrag(token: AnyHashable(42))
        #expect(coordinator.draggedID == nil)
        #expect(driving.liftFrame(for: AnyHashable(42)) == nil)
    }
}
