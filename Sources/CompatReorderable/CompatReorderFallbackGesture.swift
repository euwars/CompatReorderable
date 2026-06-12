//
//  CompatReorderFallbackGesture.swift
//  CompatReorderable
//
//  SwiftUI gesture backend for platforms without drag-and-drop interactions:
//  watchOS (the native watchOS 27 `reorderable()` also reorders without
//  them) and macOS before 27. The drag is a gesture on each cell, and the
//  dragged cell itself becomes the floating preview: it stays in the layout,
//  offset to follow the pointer/finger and compensated against its own slot
//  as the gap moves beneath it.
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
    @State private var translation: CGSize = .zero

    func body(content: Content) -> some View {
        let isDragged = coordinator?.draggedID == itemID
        let base = content
            .scaleEffect(isDragged ? 1.05 : 1)
            .offset(isDragged ? dragOffset : .zero)
            .shadow(color: .black.opacity(isDragged ? 0.3 : 0), radius: 8, y: 4)
            .zIndex(isDragged ? 1 : 0)

        #if os(watchOS)
        base.simultaneousGesture(watchReorderGesture)
        #else
        base.simultaneousGesture(macReorderGesture)
        #endif
    }

    /// The cell follows the pointer relative to where it was lifted; when a
    /// retarget moves its slot in the layout, the slot delta is compensated
    /// so the cell stays glued to the pointer.
    private var dragOffset: CGSize {
        guard let currentFrame = coordinator?.frames[itemID] else { return translation }
        return CGSize(
            width: liftFrame.minX + translation.width - currentFrame.minX,
            height: liftFrame.minY + translation.height - currentFrame.minY
        )
    }

    private func lift() {
        guard let coordinator else { return }
        liftFrame = coordinator.frames[itemID] ?? .zero
        translation = .zero
        withAnimation(.snappy(duration: 0.2)) {
            coordinator.beginDrag(id: itemID)
        }
    }

    private func follow(_ drag: DragGesture.Value) {
        translation = drag.translation
        coordinator?.dragMoved(at: drag.location)
    }

    private func end() {
        guard let coordinator, coordinator.draggedID == itemID else { return }
        coordinator.commitDrop()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            coordinator.finishDrag()
            translation = .zero
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
                if let drag {
                    follow(drag)
                }
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

#endif
