//
//  CompatReorderCoordinator.swift
//  CompatReorderable
//
//  Internal machinery for the compat reorder API. Nothing here is meant to
//  be used directly — see CompatReorderable.swift for the public surface.
//

import SwiftUI

enum CompatReorder {
    static let coordinateSpaceName = "compat-reorder-container"
}

/// Marker so the generic coordinator can travel through the environment;
/// `CompatReorderableForEach` downcasts to its concrete ID type.
protocol CompatReorderCoordinating: AnyObject {}

/// The non-generic face the UIKit gesture host drives. Only crossed a
/// handful of times per drag (lift, begin, drop preview) plus one CGPoint
/// call per movement — never with per-item boxing on hot paths.
protocol CompatReorderDragDriving: AnyObject {
    var hasActiveDrag: Bool { get }
    func dragToken(at point: CGPoint) -> AnyHashable?
    func liftFrame(for token: AnyHashable) -> CGRect?
    func beginDrag(token: AnyHashable)
    func dragMoved(at point: CGPoint)
    func commitDrop()
    func revertDrag()
    func finishDrag()
}

/// State hub for one reorder container, mirroring the structure of the
/// native implementation (`ReorderableItemContainerState`): the dragged item
/// is removed from layout (its cell hidden behind the system drag preview),
/// a same-size gap marks the insertion point, the data is never mutated
/// during the drag, and the move is reported once on drop.
///
/// Generic over the item identifier so the per-frame and per-cell work
/// (frame tracking, retarget scans, order diffing) runs on concrete IDs —
/// at hundreds of items, boxed `AnyHashable` hashing on these paths is an
/// order of magnitude slower.
///
/// Driven by `CompatReorderGestureHost`'s system drag-and-drop session.
/// Observed properties change rarely (drag begin/end, retarget) and may
/// invalidate the cell tree; per-frame session locations only run
/// `retarget`, which mutates state just when the gap actually moves.
@Observable
final class CompatReorderCoordinator<ItemID: Hashable>: CompatReorderCoordinating {
    // MARK: Observed by the cell tree (rare changes)

    private(set) var draggedID: ItemID?
    private(set) var displayIDs: [ItemID]?
    private(set) var moveCount = 0

    // MARK: Unobserved bookkeeping

    @ObservationIgnored var sourceIDs: [ItemID] = []
    @ObservationIgnored var frames: [ItemID: CGRect] = [:]
    @ObservationIgnored var commitMove: ((_ sources: [ItemID], _ before: ItemID?) -> Void)?

    @ObservationIgnored private var lastMoveTime = Date.distantPast

    // MARK: Drag lifecycle

    func itemID(at point: CGPoint) -> ItemID? {
        frames.first { $0.value.contains(point) }?.key
    }

    func beginDrag(id: ItemID) {
        guard draggedID == nil else { return }
        displayIDs = sourceIDs
        draggedID = id
    }

    /// Reports the move once, on drop, like the native `reorderContainer`.
    /// The display already shows the proposed order, so applying it doesn't
    /// move the cells; the system drop animation lands the preview in the
    /// slot.
    func commitDrop() {
        guard let draggedID,
              let displayIDs,
              displayIDs != sourceIDs,
              let fromIndex = displayIDs.firstIndex(of: draggedID)
        else { return }

        let successorIndex = displayIDs.index(after: fromIndex)
        commitMove?(
            [draggedID],
            successorIndex < displayIDs.endIndex ? displayIDs[successorIndex] : nil
        )
    }

    /// Cancelled drags put the gap back where the item came from, so the
    /// system's cancel animation returns the preview to the original slot.
    func revertDrag() {
        guard draggedID != nil else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            displayIDs = sourceIDs
        }
    }

    /// Called after the drop or cancel animation completes: unhides the cell
    /// and clears the drag state.
    func finishDrag() {
        guard draggedID != nil else { return }
        draggedID = nil
        displayIDs = nil
    }

    // MARK: Retargeting

    private func retarget(at point: CGPoint) {
        guard let draggedID,
              var order = displayIDs,
              let fromIndex = order.firstIndex(of: draggedID),
              let ownFrame = frames[draggedID]
        else { return }

        // The gap under the finger is a dead zone: after a move reflows the
        // layout, the finger lands on the dragged item's own slot and nothing
        // retriggers. This is what makes oscillation impossible.
        guard !ownFrame.contains(point) else { return }

        // Frames reported mid-reflow are interpolated; a brief cooldown stops
        // a passing card from stealing the target while the spring settles.
        guard Date.now.timeIntervalSince(lastMoveTime) > 0.15 else { return }

        guard let candidate = frames.first(where: { id, frame in
            id != draggedID && frame.contains(point)
        }) else {
            // Lazy: no per-call array allocation while hovering below the
            // cells (the common case during bottom-edge auto-scroll).
            let bottom = frames.values.lazy.map(\.maxY).max() ?? .zero
            if point.y > bottom, fromIndex != order.count - 1 {
                order.remove(at: fromIndex)
                order.append(draggedID)
                proposeOrder(order)
            }
            return
        }

        guard let candidateIndex = order.firstIndex(of: candidate.key),
              candidateIndex != fromIndex
        else { return }

        // Same-column moves trigger once the finger is ~20% (capped at 24pt)
        // into the candidate from the edge it approaches — matching how
        // eagerly the native reorder retargets — while still not firing the
        // moment an edge is grazed.
        let sameColumn = abs(candidate.value.minX - ownFrame.minX) < 1
        if sameColumn {
            let entryDepth = min(candidate.value.height * 0.2, 24)
            let crossed = fromIndex < candidateIndex
                ? point.y > candidate.value.minY + entryDepth
                : point.y < candidate.value.maxY - entryDepth
            guard crossed else { return }
        }

        order.remove(at: fromIndex)
        order.insert(draggedID, at: candidateIndex)
        proposeOrder(order)
    }

    private func proposeOrder(_ order: [ItemID]) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            displayIDs = order
        }
        moveCount += 1
        lastMoveTime = .now
    }
}

// MARK: - The UIKit-facing, type-erased boundary

extension CompatReorderCoordinator: CompatReorderDragDriving {
    var hasActiveDrag: Bool {
        draggedID != nil
    }

    func dragToken(at point: CGPoint) -> AnyHashable? {
        itemID(at: point).map(AnyHashable.init)
    }

    func liftFrame(for token: AnyHashable) -> CGRect? {
        (token.base as? ItemID).flatMap { frames[$0] }
    }

    func beginDrag(token: AnyHashable) {
        guard let id = token.base as? ItemID else { return }
        beginDrag(id: id)
    }

    func dragMoved(at point: CGPoint) {
        guard draggedID != nil else { return }
        retarget(at: point)
    }
}

// MARK: - Plumbing between the container and its cells

extension EnvironmentValues {
    @Entry var compatReorderCoordinator: (any CompatReorderCoordinating)?
}
