//
//  CompatReorderWatchGesture.swift
//  CompatReorderable
//
//  watchOS backend. watchOS has no drag-and-drop interactions (the native
//  watchOS 27 `reorderable()` also reorders without them there), so the drag is
//  a SwiftUI long-press + drag gesture on each cell, and the dragged cell
//  itself becomes the floating preview: it stays in the layout, offset to
//  follow the finger and compensated against its own slot as the gap moves
//  beneath it.
//

#if os(watchOS)

import SwiftUI

struct CompatReorderWatchCellModifier<ItemID: Hashable>: ViewModifier {
    let coordinator: CompatReorderCoordinator<ItemID>?
    let itemID: ItemID

    @State private var liftFrame: CGRect = .zero
    @State private var translation: CGSize = .zero

    func body(content: Content) -> some View {
        let isDragged = coordinator?.draggedID == itemID
        content
            .scaleEffect(isDragged ? 1.05 : 1)
            .offset(isDragged ? dragOffset : .zero)
            .shadow(color: .black.opacity(isDragged ? 0.3 : 0), radius: 8, y: 4)
            .zIndex(isDragged ? 1 : 0)
            .simultaneousGesture(reorderGesture)
    }

    /// The cell follows the finger relative to where it was lifted; when a
    /// retarget moves its slot in the layout, the slot delta is compensated
    /// so the cell stays glued to the finger.
    private var dragOffset: CGSize {
        guard let currentFrame = coordinator?.frames[itemID] else { return translation }
        return CGSize(
            width: liftFrame.minX + translation.width - currentFrame.minX,
            height: liftFrame.minY + translation.height - currentFrame.minY
        )
    }

    private var reorderGesture: some Gesture {
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
                    liftFrame = coordinator.frames[itemID] ?? .zero
                    translation = .zero
                    withAnimation(.snappy(duration: 0.2)) {
                        coordinator.beginDrag(id: itemID)
                    }
                }
                if let drag {
                    translation = drag.translation
                    coordinator.dragMoved(at: drag.location)
                }
            }
            .onEnded { _ in
                guard let coordinator, coordinator.draggedID == itemID else { return }
                coordinator.commitDrop()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    coordinator.finishDrag()
                    translation = .zero
                }
            }
    }
}

#endif
