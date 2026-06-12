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
//  iOS/iPadOS/Catalyst/visionOS only — watchOS and macOS have no drag
//  interactions and use the SwiftUI gesture backend in
//  CompatReorderFallbackGesture.swift.
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
        private var dropHandled = false
        private var sessionGeneration = 0

        /// Snapshots are drawn from and drop targets anchor to this view:
        /// the scroll view when there is one, else the interaction host.
        private var previewContainer: UIView? { scrollView ?? interactionHostView }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, dragInteraction == nil else { return }

            // The enclosing scroll view powers auto-scroll, but is optional:
            // plain, non-scrolling containers reorder fine without one.
            var ancestor = superview
            while ancestor != nil, !(ancestor is UIScrollView) {
                ancestor = ancestor?.superview
            }
            scrollView = ancestor as? UIScrollView

            // Install on the view that carries SwiftUI's context-menu
            // interaction (the hosting view above the scroll view): UIKit
            // only links menu and drag when both interactions share a view.
            // Fall back to the hosting view by class, then the scroll view,
            // then the topmost ancestor.
            var menuHost: UIView?
            var hostingFallback: UIView?
            var topmost: UIView = self
            var candidate = (scrollView ?? self).superview
            while let view = candidate {
                if menuHost == nil,
                   view.interactions.contains(where: { $0 is UIContextMenuInteraction }) {
                    menuHost = view
                }
                if hostingFallback == nil, String(describing: type(of: view)).contains("HostingView") {
                    hostingFallback = view
                }
                topmost = view
                candidate = view.superview
            }
            let target = menuHost ?? hostingFallback ?? scrollView ?? topmost

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

        private func reorderToken(of item: UIDragItem) -> CompatReorderDragToken? {
            item.localObject as? CompatReorderDragToken
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

            // An empty provider with a local token — the reorder never
            // leaves the app, mirroring the native implementation's empty
            // transfer representation. The token is tagged with its owning
            // coordinator so foreign sessions are never confused with ours.
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
            // Native reorder feel: lift scales up in place, then the item
            // shrinks to the system's carrying size while dragging, and
            // grows back into the slot on drop.
            false
        }

        func dragInteraction(
            _ interaction: UIDragInteraction,
            previewForLifting item: UIDragItem,
            session: UIDragSession
        ) -> UITargetedDragPreview? {
            guard let container = previewContainer,
                  let token = reorderToken(of: item),
                  let frame = reorderCoordinator?.liftFrame(for: token)
            else { return nil }
            let frameInContainer = convert(frame, to: container)

            if let preview = renderedPreview(
                for: token,
                frameInContainer: frameInContainer,
                container: container,
                includeHoverShadow: true
            ) {
                return preview
            }
            return snapshotPreview(for: item)
        }

        func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: UIDragSession) {
            guard let token = session.items.first.flatMap(reorderToken(of:)),
                  reorderCoordinator?.owns(token) == true
            else { return }
            sessionGeneration += 1
            dropHandled = false
            reorderCoordinator?.beginDrag(token: token)
            startDisplayLink()
        }

        func dragInteraction(
            _ interaction: UIDragInteraction,
            session: UIDragSession,
            willEndWith operation: UIDropOperation
        ) {
            stopDisplayLink()

            // Safety net: if a foreign drop target claims the session, no
            // local performDrop or cancel animation will ever run and the
            // drag state would be stranded (hidden cell, all future drags
            // blocked). Give the legitimate paths time to win, then clean
            // up; a newer session bumps the generation and voids this timer.
            let generation = sessionGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self,
                      generation == self.sessionGeneration,
                      !self.dropHandled,
                      let coordinator = self.reorderCoordinator,
                      coordinator.hasActiveDrag
                else { return }
                coordinator.revertDrag()
                coordinator.finishDrag()
            }
        }

        func dragInteraction(
            _ interaction: UIDragInteraction,
            item: UIDragItem,
            willAnimateCancelWith animator: UIDragAnimating
        ) {
            // Cancelled (released outside a drop area): revert the gap so the
            // system's cancel animation returns the preview to the original
            // slot, then unhide the cell.
            dropHandled = true
            reorderCoordinator?.revertDrag()
            animator.addCompletion { [weak self] _ in
                self?.reorderCoordinator?.finishDrag()
            }
        }

        // MARK: - UIDropInteractionDelegate

        func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
            guard let token = session.localDragSession?.items.first.flatMap(reorderToken(of:)) else {
                return false
            }
            return reorderCoordinator?.owns(token) == true
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
            // No prefersFullSizePreview: the carried item stays at the
            // system's reduced size until it lands.
            return UIDropProposal(operation: .move)
        }

        func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
            dropHandled = true
            reorderCoordinator?.commitDrop()
        }

        func dropInteraction(
            _ interaction: UIDropInteraction,
            previewForDropping item: UIDragItem,
            withDefault defaultPreview: UITargetedDragPreview
        ) -> UITargetedDragPreview? {
            guard let container = previewContainer,
                  let token = reorderToken(of: item),
                  let frame = reorderCoordinator?.liftFrame(for: token)
            else { return defaultPreview }

            let frameInContainer = convert(frame, to: container)
            let target = UIDragPreviewTarget(
                container: container,
                center: CGPoint(x: frameInContainer.midX, y: frameInContainer.midY)
            )

            // The item LANDS, native-style: a freshly rendered copy with the
            // COMMITTED content (ImageRenderer draws our own view tree from
            // current model values — unlike on-screen snapshots, it can't be
            // stale) and without the hover shadow, so the glide reads as the
            // card lowering into place. The cell underneath stays hidden
            // until the animation completes; since the landed copy matches
            // the cell pixel-for-pixel, the final swap is invisible — one
            // item visible at all times.
            if let landed = renderedPreview(
                for: token,
                frameInContainer: frameInContainer,
                container: container,
                includeHoverShadow: false
            ) {
                return landed
            }
            return defaultPreview.retargetedPreview(with: target)
        }

        /// The cell's SwiftUI content rendered synchronously to an image via
        /// ImageRenderer — no window dependence, so it works on the
        /// menu-linked drag path too (UIKit snapshots that preview before
        /// any window exists; hosted views come out empty there). No
        /// visiblePath or system shadow plate (those are rectangular and
        /// mismatch rounded cells); the hover elevation is a SwiftUI shadow
        /// hugging the cell's actual rendered shape, with transparent
        /// padding so it isn't clipped at the canvas bounds.
        private func renderedPreview(
            for token: CompatReorderDragToken,
            frameInContainer: CGRect,
            container: UIView,
            includeHoverShadow: Bool
        ) -> UITargetedDragPreview? {
            guard let reorderCoordinator,
                  let content = reorderCoordinator.previewContent(for: token)
            else { return nil }

            let renderer = ImageRenderer(
                content: content
                    .frame(
                        width: frameInContainer.width,
                        height: frameInContainer.height
                    )
                    .environment(
                        \.colorScheme,
                        traitCollection.userInterfaceStyle == .dark ? .dark : .light
                    )
            )
            renderer.proposedSize = ProposedViewSize(frameInContainer.size)
            renderer.scale = window?.screen.scale ?? 3
            guard let image = renderer.uiImage else { return nil }

            let imageView = UIImageView(image: image)
            imageView.frame = CGRect(origin: .zero, size: frameInContainer.size)

            // The hover shadow is the SYSTEM's, via shadowPath — it fades it
            // immediately when a lift is released without dragging (a baked
            // image shadow would linger through the whole cancel animation).
            // visiblePath must be set to the same shape: without it, UIKit
            // applies its own default clipping/rounding to the preview. The
            // corner radius is detected from the rendered cell's own shape
            // unless explicitly configured. The landed drop copy gets no
            // shadow, matching the resting cell.
            let radius = reorderCoordinator.previewCornerRadius
                ?? Self.detectedCornerRadius(of: image)
            let shape = UIBezierPath(
                roundedRect: imageView.bounds,
                cornerRadius: radius
            )
            let parameters = UIDragPreviewParameters()
            parameters.backgroundColor = .clear
            parameters.visiblePath = shape
            parameters.shadowPath = includeHoverShadow ? shape : UIBezierPath()

            let target = UIDragPreviewTarget(
                container: container,
                center: CGPoint(x: frameInContainer.midX, y: frameInContainer.midY)
            )
            return UITargetedDragPreview(view: imageView, parameters: parameters, target: target)
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

        // MARK: - Snapshot previews

        private func snapshotPreview(for item: UIDragItem) -> UITargetedDragPreview? {
            guard let container = previewContainer,
                  let token = reorderToken(of: item),
                  let frame = reorderCoordinator?.liftFrame(for: token)
            else { return nil }

            let frameInContainer = convert(frame, to: container)
            guard frameInContainer.width > 0, frameInContainer.height > 0 else { return nil }

            // Render via drawHierarchy: resizableSnapshotView silently
            // returns an empty (black) view for SwiftUI-hosted content.
            let renderer = UIGraphicsImageRenderer(size: frameInContainer.size)
            let image = renderer.image { _ in
                // Shift the visible viewport so the cell region lands at the
                // image origin.
                let drawOrigin = CGPoint(
                    x: container.bounds.minX - frameInContainer.minX,
                    y: container.bounds.minY - frameInContainer.minY
                )
                container.drawHierarchy(
                    in: CGRect(origin: drawOrigin, size: container.bounds.size),
                    afterScreenUpdates: false
                )
            }

            let imageView = UIImageView(image: image)
            imageView.frame = CGRect(origin: .zero, size: frameInContainer.size)

            let parameters = UIDragPreviewParameters()
            parameters.backgroundColor = .clear
            parameters.visiblePath = UIBezierPath(roundedRect: imageView.bounds, cornerRadius: 12)

            let target = UIDragPreviewTarget(
                container: container,
                center: CGPoint(x: frameInContainer.midX, y: frameInContainer.midY)
            )
            return UITargetedDragPreview(view: imageView, parameters: parameters, target: target)
        }

        /// Detects the cell's corner radius from its rendered alpha channel:
        /// for a rounded rect, the first opaque pixel down the left edge
        /// sits at y == radius. Scans only the top-left corner region; the
        /// >50% alpha threshold skips any faint baked-in shadow pixels.
        /// Runs once per lift.
        private static func detectedCornerRadius(of image: UIImage) -> CGFloat {
            guard let cgImage = image.cgImage else { return 0 }

            let scanSize = min(cgImage.height, min(cgImage.width, Int(60 * image.scale)))
            guard scanSize > 0 else { return 0 }

            var alphas = [UInt8](repeating: 0, count: scanSize * scanSize)
            guard let context = CGContext(
                data: &alphas,
                width: scanSize,
                height: scanSize,
                bitsPerComponent: 8,
                bytesPerRow: scanSize,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            ) else { return 0 }

            // Align the IMAGE's top-left with the context's top-left
            // (CG contexts are bottom-left-origin).
            context.draw(
                cgImage,
                in: CGRect(
                    x: 0,
                    y: CGFloat(scanSize) - CGFloat(cgImage.height),
                    width: CGFloat(cgImage.width),
                    height: CGFloat(cgImage.height)
                )
            )

            // Bitmap memory is top-scanline-first and the image was drawn
            // top-aligned, so row 0 is the image's top edge: walk the
            // leftmost column downward. Antialiasing reaches >50% coverage
            // ~√r pixels before the geometric touch point, so compensate —
            // validated within ±0.2pt for radii 0–24 at 2x/3x.
            for row in 0..<scanSize {
                if alphas[row * scanSize] > 128 {
                    let pixels = CGFloat(row)
                    return (pixels + pixels.squareRoot() + 0.5) / image.scale
                }
            }
            return 0
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
