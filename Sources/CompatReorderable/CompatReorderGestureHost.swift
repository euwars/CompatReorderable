//
//  CompatReorderGestureHost.swift
//  CompatReorderable
//
//  UIKit layer of the compat reorder API, built on the system drag-and-drop
//  interactions — the same machinery the native iOS 27 `reorderable()` uses
//  internally. A `UIDragInteraction` is installed on the same hosting view
//  that carries SwiftUI's `UIContextMenuInteraction`, so UIKit links the two
//  the way Apple's own apps do: holding still presents the menu, dragging
//  (including dragging out of a presented menu) dismisses it and starts the
//  reorder. A `UIDropInteraction` on the same view feeds the session
//  location to the coordinator, which moves the gap and commits on drop.
//
//  iOS/iPadOS/Catalyst/visionOS only — watchOS has no drag interactions and
//  uses the SwiftUI gesture backend in CompatReorderWatchGesture.swift.
//

#if os(iOS) || os(visionOS)

import SwiftUI
import UIKit

struct CompatReorderGestureHost: UIViewRepresentable {
    let isEnabled: Bool
    let coordinator: any CompatReorderDragDriving

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ uiView: HostView, context: Context) {
        uiView.isReorderEnabled = isEnabled
        uiView.reorderCoordinator = coordinator
    }

    static func dismantleUIView(_ uiView: HostView, coordinator: ()) {
        uiView.detach()
    }

    final class HostView: UIView, UIDragInteractionDelegate, UIDropInteractionDelegate {
        var reorderCoordinator: (any CompatReorderDragDriving)?

        var isReorderEnabled = true {
            didSet { dragInteraction?.isEnabled = isReorderEnabled }
        }

        private weak var scrollView: UIScrollView?
        private weak var interactionHostView: UIView?
        private var dragInteraction: UIDragInteraction?
        private var dropInteraction: UIDropInteraction?
        private weak var activeDropSession: UIDropSession?
        private var displayLink: CADisplayLink?
        private var lastTickTimestamp: CFTimeInterval = 0
        private var lastReportedPoint: CGPoint?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, dragInteraction == nil else { return }

            var ancestor = superview
            while ancestor != nil, !(ancestor is UIScrollView) {
                ancestor = ancestor?.superview
            }
            guard let scrollView = ancestor as? UIScrollView else { return }
            self.scrollView = scrollView

            // Install on the view that carries SwiftUI's context-menu
            // interaction (the hosting view above the scroll view): UIKit
            // only links menu and drag when both interactions share a view.
            // Fall back to the hosting view by class, then the scroll view.
            var menuHost: UIView?
            var hostingFallback: UIView?
            var candidate = scrollView.superview
            while let view = candidate {
                if view.interactions.contains(where: { $0 is UIContextMenuInteraction }) {
                    menuHost = view
                    break
                }
                if hostingFallback == nil, String(describing: type(of: view)).contains("HostingView") {
                    hostingFallback = view
                }
                candidate = view.superview
            }
            let target = menuHost ?? hostingFallback ?? scrollView

            let drag = UIDragInteraction(delegate: self)
            drag.isEnabled = isReorderEnabled
            let drop = UIDropInteraction(delegate: self)
            target.addInteraction(drag)
            target.addInteraction(drop)
            interactionHostView = target
            dragInteraction = drag
            dropInteraction = drop
        }

        func detach() {
            stopDisplayLink()
            if let dragInteraction {
                interactionHostView?.removeInteraction(dragInteraction)
            }
            if let dropInteraction {
                interactionHostView?.removeInteraction(dropInteraction)
            }
            dragInteraction = nil
            dropInteraction = nil
        }

        // MARK: - UIDragInteractionDelegate

        func dragInteraction(
            _ interaction: UIDragInteraction,
            itemsForBeginning session: UIDragSession
        ) -> [UIDragItem] {
            guard let reorderCoordinator,
                  !reorderCoordinator.hasActiveDrag,
                  let token = reorderCoordinator.dragToken(at: session.location(in: self))
            else { return [] }

            // An empty provider with a local object — the reorder never
            // leaves the app, mirroring the native implementation's empty
            // transfer representation.
            let item = UIDragItem(itemProvider: NSItemProvider())
            item.localObject = token
            return [item]
        }

        func dragInteraction(
            _ interaction: UIDragInteraction,
            sessionIsRestrictedToDraggingApplication session: UIDragSession
        ) -> Bool {
            true
        }

        func dragInteraction(
            _ interaction: UIDragInteraction,
            sessionAllowsMoveOperation session: UIDragSession
        ) -> Bool {
            true
        }

        func dragInteraction(
            _ interaction: UIDragInteraction,
            prefersFullSizePreviewsFor session: UIDragSession
        ) -> Bool {
            true
        }

        func dragInteraction(
            _ interaction: UIDragInteraction,
            previewForLifting item: UIDragItem,
            session: UIDragSession
        ) -> UITargetedDragPreview? {
            snapshotPreview(for: item)
        }

        func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: UIDragSession) {
            guard let token = session.items.first?.localObject as? AnyHashable else { return }
            reorderCoordinator?.beginDrag(token: token)
            startDisplayLink()
        }

        func dragInteraction(
            _ interaction: UIDragInteraction,
            session: UIDragSession,
            willEndWith operation: UIDropOperation
        ) {
            stopDisplayLink()
        }

        func dragInteraction(
            _ interaction: UIDragInteraction,
            item: UIDragItem,
            willAnimateCancelWith animator: UIDragAnimating
        ) {
            // Cancelled (released outside a drop area): revert the gap so the
            // system's cancel animation returns the preview to the original
            // slot, then unhide the cell.
            reorderCoordinator?.revertDrag()
            animator.addCompletion { [weak self] _ in
                self?.reorderCoordinator?.finishDrag()
            }
        }

        // MARK: - UIDropInteractionDelegate

        func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
            session.localDragSession?.items.first?.localObject is AnyHashable
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: UIDropSession) {
            activeDropSession = session
        }

        func dropInteraction(
            _ interaction: UIDropInteraction,
            sessionDidUpdate session: UIDropSession
        ) -> UIDropProposal {
            activeDropSession = session
            reportDragLocation(of: session)
            let proposal = UIDropProposal(operation: .move)
            proposal.prefersFullSizePreview = true
            return proposal
        }

        /// Deduplicates location reports: with a stationary finger and no
        /// scrolling, the per-frame tick would otherwise run the retarget
        /// scans at up to 120Hz for nothing.
        private func reportDragLocation(of session: UIDropSession) {
            let point = session.location(in: self)
            if let last = lastReportedPoint,
               abs(last.x - point.x) < 0.5, abs(last.y - point.y) < 0.5 {
                return
            }
            lastReportedPoint = point
            reorderCoordinator?.dragMoved(at: point)
        }

        func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
            reorderCoordinator?.commitDrop()
        }

        func dropInteraction(
            _ interaction: UIDropInteraction,
            previewForDropping item: UIDragItem,
            withDefault defaultPreview: UITargetedDragPreview
        ) -> UITargetedDragPreview? {
            // Land the preview exactly on the item's slot in the committed
            // order — the settle animation.
            guard let scrollView,
                  let token = item.localObject as? AnyHashable,
                  let frame = reorderCoordinator?.liftFrame(for: token)
            else { return defaultPreview }
            let frameInScroll = convert(frame, to: scrollView)
            let target = UIDragPreviewTarget(
                container: scrollView,
                center: CGPoint(x: frameInScroll.midX, y: frameInScroll.midY)
            )
            return defaultPreview.retargetedPreview(with: target)
        }

        func dropInteraction(
            _ interaction: UIDropInteraction,
            item: UIDragItem,
            willAnimateDropWith animator: UIDragAnimating
        ) {
            animator.addCompletion { [weak self] _ in
                self?.reorderCoordinator?.finishDrag()
            }
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) {
            activeDropSession = nil
            stopDisplayLink()
        }

        // MARK: - Lift preview

        private func snapshotPreview(for item: UIDragItem) -> UITargetedDragPreview? {
            guard let scrollView,
                  let token = item.localObject as? AnyHashable,
                  let frame = reorderCoordinator?.liftFrame(for: token)
            else { return nil }

            let frameInScroll = convert(frame, to: scrollView)
            guard frameInScroll.width > 0, frameInScroll.height > 0 else { return nil }

            // Render via drawHierarchy: resizableSnapshotView silently
            // returns an empty (black) view for SwiftUI-hosted content.
            let renderer = UIGraphicsImageRenderer(size: frameInScroll.size)
            let image = renderer.image { _ in
                // Shift the visible viewport so the cell region lands at the
                // image origin.
                let drawOrigin = CGPoint(
                    x: scrollView.bounds.minX - frameInScroll.minX,
                    y: scrollView.bounds.minY - frameInScroll.minY
                )
                scrollView.drawHierarchy(
                    in: CGRect(origin: drawOrigin, size: scrollView.bounds.size),
                    afterScreenUpdates: false
                )
            }

            let imageView = UIImageView(image: image)
            imageView.frame = CGRect(origin: .zero, size: frameInScroll.size)

            let parameters = UIDragPreviewParameters()
            parameters.backgroundColor = .clear
            parameters.visiblePath = UIBezierPath(roundedRect: imageView.bounds, cornerRadius: 12)

            let target = UIDragPreviewTarget(
                container: scrollView,
                center: CGPoint(x: frameInScroll.midX, y: frameInScroll.midY)
            )
            return UITargetedDragPreview(view: imageView, parameters: parameters, target: target)
        }

        // MARK: - Auto-scroll

        /// Plain scroll views don't auto-scroll during drag sessions (only
        /// table/collection views do), so this runs every frame during a
        /// drag: it scrolls near the edges and re-feeds the session location
        /// while content moves under a stationary finger.
        private func startDisplayLink() {
            lastTickTimestamp = 0
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        private func stopDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
            lastReportedPoint = nil
        }

        @objc private func tick(_ link: CADisplayLink) {
            let deltaTime = lastTickTimestamp == 0 ? 0 : link.timestamp - lastTickTimestamp
            lastTickTimestamp = link.timestamp
            guard let activeDropSession else { return }
            autoScrollIfNeeded(deltaTime: deltaTime, session: activeDropSession)
            reportDragLocation(of: activeDropSession)
        }

        private func autoScrollIfNeeded(deltaTime: CFTimeInterval, session: UIDropSession) {
            guard deltaTime > 0, let scrollView else { return }

            let hotZone: CGFloat = 60
            let maxSpeed: CGFloat = 800
            let point = session.location(in: scrollView)
            let visibleTop = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
            let visibleBottom = scrollView.contentOffset.y + scrollView.bounds.height
                - scrollView.adjustedContentInset.bottom

            var speed: CGFloat = 0
            let topDistance = point.y - visibleTop
            let bottomDistance = visibleBottom - point.y
            if topDistance < hotZone {
                speed = -maxSpeed * (1 - max(topDistance, 0) / hotZone)
            } else if bottomDistance < hotZone {
                speed = maxSpeed * (1 - max(bottomDistance, 0) / hotZone)
            }
            guard speed != 0 else { return }

            let minOffset = -scrollView.adjustedContentInset.top
            let maxOffset = max(
                minOffset,
                scrollView.contentSize.height + scrollView.adjustedContentInset.bottom
                    - scrollView.bounds.height
            )
            var offset = scrollView.contentOffset
            offset.y = min(max(offset.y + speed * deltaTime, minOffset), maxOffset)
            scrollView.contentOffset = offset
        }
    }
}

#endif
