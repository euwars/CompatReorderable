//
//  CompatReorderFallbackGesture.swift
//  CompatReorderable
//
//  SwiftUI gesture backend for platforms without drag-and-drop interactions:
//  watchOS (the native watchOS 27 `reorderable()` also reorders without
//  them) and macOS before 27. The drag is a gesture on each cell; the
//  dragged item renders as a container-level overlay so it always draws
//  above every cell (zIndex on cells is unreliable in lazy containers),
//  while its hidden cell is the gap.
//
//  Activation is platform-tuned: watchOS uses a long press first (touch
//  scrolling must win until then); macOS starts straight from a small drag,
//  matching AppKit's reorder feel — Mac scrolling doesn't claim click-drags,
//  so there's nothing to arbitrate against.
//

#if os(watchOS) || os(macOS)

import SwiftUI

struct CompatReorderFallbackCellModifier<ItemID: Hashable>: ViewModifier {
    let coordinator: CompatReorderCoordinator<ItemID>?
    let itemID: ItemID

    @State private var liftFrame: CGRect = .zero

    func body(content: Content) -> some View {
        let isDragged = coordinator?.draggedID == itemID
        let base = content
            // The overlay preview represents the dragged item; its hidden
            // cell is the gap.
            .opacity(isDragged ? 0 : 1)
            // SwiftUI CANCELS (not ends) the gesture when its view leaves
            // the hierarchy — a lazy container deinstantiating the cell
            // after a crown/wheel scroll, or the app removing the item
            // mid-drag. onEnded never fires then; without this, the drag
            // state stays stranded (frozen preview, all future drags
            // blocked).
            .onDisappear {
                guard let coordinator, coordinator.draggedID == itemID else { return }
                coordinator.revertDrag()
                coordinator.finishDrag()
            }

        #if os(watchOS)
        base.simultaneousGesture(watchReorderGesture)
        #else
        base.simultaneousGesture(macReorderGesture)
        #endif
    }

    private func lift() {
        guard let coordinator,
              coordinator.isReorderEnabled,
              let content = coordinator.previewContentProvider?(itemID)
        else { return }
        liftFrame = coordinator.frames[itemID] ?? .zero
        coordinator.gapAnimation = .spring(response: 0.5, dampingFraction: 0.8)
        withAnimation(.snappy(duration: 0.3)) {
            coordinator.beginDrag(id: itemID)
            coordinator.fallbackPreview = .init(content: content, frame: liftFrame)
        }
    }

    private func follow(_ drag: DragGesture.Value) {
        coordinator?.fallbackPreview?.frame = liftFrame.offsetBy(
            dx: drag.translation.width,
            dy: drag.translation.height
        )
        coordinator?.dragMoved(at: drag.location)
    }

    private func end() {
        guard let coordinator, coordinator.draggedID == itemID else { return }
        coordinator.commitDrop()

        // Settle: glide the preview into the item's slot, then unhide.
        let slotFrame = coordinator.frames[itemID] ?? liftFrame
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
            coordinator.fallbackPreview?.frame = slotFrame
            coordinator.fallbackPreview?.isSettling = true
        } completion: {
            coordinator.finishDrag()  // Also clears fallbackPreview.
        }
    }

    #if os(watchOS)
    private var watchReorderGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.4)
            .sequenced(
                before: DragGesture(
                    minimumDistance: 0,
                    coordinateSpace: .named(CompatReorder.coordinateSpaceName)
                )
            )
            .onChanged { value in
                guard case .second(true, let drag) = value, let coordinator else { return }
                if coordinator.draggedID == nil {
                    lift()
                }
                guard coordinator.draggedID == itemID, let drag else { return }
                follow(drag)
            }
            .onEnded { _ in end() }
    }
    #else
    private var macReorderGesture: some Gesture {
        DragGesture(
            minimumDistance: 6,
            coordinateSpace: .named(CompatReorder.coordinateSpaceName)
        )
        .onChanged { drag in
            guard let coordinator else { return }
            if coordinator.draggedID == nil {
                lift()
            }
            guard coordinator.draggedID == itemID else { return }
            follow(drag)
        }
        .onEnded { _ in end() }
    }
    #endif
}

/// Container-level overlay rendering the dragged item above all cells.
/// Reads the per-frame preview state in its own body, so high-frequency
/// updates invalidate only this small view, never the cell tree.
struct CompatReorderFallbackPreviewHost<ItemID: Hashable>: View {
    let coordinator: CompatReorderCoordinator<ItemID>

    var body: some View {
        if let preview = coordinator.fallbackPreview {
            preview.content
                .frame(width: preview.frame.width, height: preview.frame.height)
                .scaleEffect(preview.isSettling ? 1 : 1.05)
                .shadow(
                    color: .black.opacity(preview.isSettling ? 0 : 0.3),
                    radius: 8,
                    y: 4
                )
                .offset(x: preview.frame.minX, y: preview.frame.minY)
                .allowsHitTesting(false)
        }
    }
}

#endif
